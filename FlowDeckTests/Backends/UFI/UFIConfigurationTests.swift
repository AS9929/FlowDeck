import CryptoKit
import XCTest

@testable import FlowDeck

/// 加密方向隔离、格式保护和真机只读互通。写回原文需要单独的测试环境开关。
final class UFIConfigurationTests: XCTestCase {
    private let original = "mixed-port: 7890\nsecret: keep\ndns:\n  enable: true\nproxies: []\nrules:\n  - MATCH,DIRECT\n"

    func testConfigurationAllowsOnlyRoutingChanges() throws {
        try UFIConfigurationPolicy.validate(
            original: original, candidate: original.replacingOccurrences(of: "MATCH,DIRECT", with: "MATCH,REJECT"))
        for replacement in ["mixed-port: 8888", "secret: changed", "dns: {}"] {
            let candidate = original + replacement + "\n"
            XCTAssertThrowsError(try UFIConfigurationPolicy.validate(original: original, candidate: candidate))
        }
        XCTAssertThrowsError(
            try UFIConfigurationPolicy.validate(
                original: original, candidate: original.replacingOccurrences(of: "secret: keep", with: "secret: changed")))
        XCTAssertThrowsError(try UFIConfigurationPolicy.validate(original: original, candidate: "rules: []\n"))
    }

    func testUnusualYAMLDoesNotBypassProtectedFields() throws {
        for suffix in ["---\nrules: []", "proxies: &shared []", "{secret: changed}", "<<: *shared"] {
            XCTAssertThrowsError(try UFIConfigurationPolicy.validate(original: original, candidate: original + suffix))
        }
        // 原文还原不会因既有锚点失效。
        try UFIConfigurationPolicy.validate(original: "x: &a 1\n", candidate: "x: &a 1\n")
    }

    func testCipherRejectsWrongDirectionSessionAndTampering() throws {
        let key = SymmetricKey(size: .bits256)
        let data = Data(original.utf8)
        let packet = try UFISecureConfigChannel.encrypt(data, key: key, context: "read:session1")
        XCTAssertEqual(try UFISecureConfigChannel.decrypt(packet, key: key, context: "read:session1"), data)
        XCTAssertThrowsError(try UFISecureConfigChannel.decrypt(packet, key: key, context: "write:session1"))
        XCTAssertThrowsError(try UFISecureConfigChannel.decrypt(packet, key: key, context: "read:session2"))
        var changed = packet
        changed[changed.count - 1] ^= 1
        XCTAssertThrowsError(try UFISecureConfigChannel.decrypt(changed, key: key, context: "read:session1"))
        XCTAssertNotEqual(packet, try UFISecureConfigChannel.encrypt(data, key: key, context: "read:session1"))
    }

    func testTransferRejectsEmptyAndOversizedBeforeDeviceCalls() async {
        let channel = UFISecureConfigChannel { _ in
            XCTFail("Invalid content must not reach device")
            return ""
        }
        for content in ["", String(repeating: "x", count: UFISecureConfigChannel.maximumBytes + 1)] {
            do {
                _ = try await channel.transfer(saving: content)
                XCTFail("Invalid content accepted")
            } catch {}
        }
    }

    func testLiveEncryptedConfigurationAndSafeRejection() async throws {
        guard let path = ProcessInfo.processInfo.environment["FLOWDECK_F50_TEST_CREDENTIALS"] else {
            throw XCTSkip("No private F50 credential file supplied")
        }
        let credentials = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let base = try XCTUnwrap(URL(string: try XCTUnwrap(credentials["ufiURL"])))
        let password = try XCTUnwrap(credentials["password"])
        let probe = UFIClient(baseURL: base, password: password)
        let snapshot = try await probe.snapshot()
        let controller = try XCTUnwrap(URL(string: try XCTUnwrap(credentials["controller"])))
        let mihomo = MihomoClient(baseURL: controller, secret: try XCTUnwrap(credentials["secret"]))
        let client = UFIClient(baseURL: base, password: password, expectedFingerprint: snapshot.identityFingerprint, mihomo: mihomo)
        let coreState = try await client.coreUpdateState()
        XCTAssertTrue(coreState.version.contains("Mihomo"))
        let reachable = try await client.connectivity()
        XCTAssertTrue(reachable)
        let current = try await client.loadConfig()
        XCTAssertTrue(current.contains("proxy-groups:"))
        XCTAssertGreaterThan(current.utf8.count, 100)
        let baseline = DeviceIdentity.digest(Data(current.utf8))
        // 结构保护会在传输明文/提交之前拒绝，与真实设备文件摘要独立比较。
        do {
            try await client.saveConfig("rules: []\n")
            XCTFail("Missing management and transparent proxy settings accepted")
        } catch {}
        let readback = try await client.loadConfig()
        XCTAssertEqual(DeviceIdentity.digest(Data(readback.utf8)), baseline)
        if ProcessInfo.processInfo.environment["FLOWDECK_F50_CONFIG_WRITE_TEST"] == "same-content" {
            // 先触发真正的核心校验失败，验证原文件保持不变；不打印真实配置。
            if current.contains("rules:\n") {
                let invalid = current.replacingOccurrences(of: "rules:\n", with: "rules: [unterminated\n")
                do {
                    try await client.saveConfig(invalid)
                    XCTFail("Core accepted invalid YAML")
                } catch {
                    XCTAssertTrue(error is UFIConfigurationNotApplied)
                }
                let unchanged = try await client.loadConfig()
                XCTAssertEqual(DeviceIdentity.digest(Data(unchanged.utf8)), baseline)
            }
            // 只写回完全相同的字节，不重启、不切节点、不改变网络；仍必须通过设备校验。
            try await client.saveConfig(current)
            let saved = try await client.loadConfig()
            XCTAssertEqual(DeviceIdentity.digest(Data(saved.utf8)), baseline)
        }
    }
}
