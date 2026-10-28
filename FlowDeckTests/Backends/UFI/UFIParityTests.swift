import XCTest

@testable import FlowDeck

/// 更新包与转发边界；真机用例只读取状态及执行少量 UDP 查询，不安装 APK 或发送短信。
final class UFIParityTests: XCTestCase {
    func testReleaseCatalogExcludesPhoneClientAndUntrustedNames() throws {
        let valid = "UFI-TOOLS_WEB_V4.1.5_20260919_2127.apk"
        let rows: [[String: Any]] = [
            ["name": valid, "size": 100, "is_dir": false],
            ["name": "UFI-TOOLS_PE_9.9.9.apk", "size": 100, "is_dir": false],
            ["name": "../" + valid, "size": 100, "is_dir": false],
            ["name": "UFI-TOOLS_WEB_V8.1.5_20260919_2127.apk", "size": 100, "is_dir": true],
        ]
        XCTAssertEqual(try UFIServiceRelease.parse(rows).version, "4.1.5")
        XCTAssertThrowsError(try UFIServiceRelease.parse(Array(rows.dropFirst())))
    }

    func testAPKScriptRejectsInvalidPathsAndChecksLiveVersionBeforeBackup() throws {
        let digest = String(repeating: "a", count: 64)
        let package = UFIServicePackage(path: "ignored", checksum: digest, version: "4.1.6", code: 416, installedCode: 415)
        let helper = "/data/local/flowdeck-config/bridge-" + digest + ".dex"
        let script = try UFIServiceUpdateScript.make(package: package, helper: helper)
        XCTAssertTrue(script.contains("mkdir \"$operation\""))
        XCTAssertTrue(script.contains("test \"$candidate_code\" -gt \"$installed_code\""))
        XCTAssertLessThan(
            try XCTUnwrap(script.range(of: "status=verified")).lowerBound,
            try XCTUnwrap(script.range(of: "pm install")).lowerBound)
        XCTAssertFalse(script.contains("pm uninstall"))
        XCTAssertFalse(script.contains("pm clear"))
        XCTAssertThrowsError(try UFIServiceUpdateScript.make(package: package, helper: "/tmp/injected;id"))
        let rollback = try UFIServiceUpdateScript.make(package: nil, helper: helper)
        XCTAssertTrue(rollback.contains("sha256sum -c ufi.previous.sha256"))
        XCTAssertFalse(rollback.contains("cp \"$old\""))
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ServiceScriptFixtures")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try script.write(to: directory.appendingPathComponent("install.sh"), atomically: true, encoding: .utf8)
        try rollback.write(to: directory.appendingPathComponent("rollback.sh"), atomically: true, encoding: .utf8)
    }

    func testTransferRejectsBadDataWithoutContactingDevice() async throws {
        do {
            _ = try await UFIPackageTransfer.send(
                data: Data("test".utf8), checksum: String(repeating: "a", count: 64),
                command: { _ in
                    XCTFail("Invalid package sent")
                    return ""
                }, progress: { _ in })
            XCTFail("Bad checksum accepted")
        } catch {}
        XCTAssertThrowsError(try UFIPackageTransfer.path(checksum: "../test"))
    }

    func testTransferReusesOnlyMatchingCompleteDigest() async throws {
        let data = Data("verified package".utf8)
        let checksum = DeviceIdentity.digest(data)
        let result = try await UFIPackageTransfer.send(
            data: data, checksum: checksum,
            command: { command in
                XCTAssertTrue(command.contains("sha256sum"))
                return checksum + "  package"
            }, progress: { XCTAssertEqual($0, 1) })
        XCTAssertEqual(result, try UFIPackageTransfer.path(checksum: checksum))
    }

    func testForwardingValidationRejectsUnknownKeysAndTokenlessURL() throws {
        var smtp: [String: String] = [
            "smtp_host": "smtp.example.com", "smtp_port": "465",
            "smtp_to": "test@example.com", "smtp_username": "user", "smtp_password": "test",
            "smtp_from": "", "smtp_from_name": "", "forward_dev_info": "0",
        ]
        XCTAssertNoThrow(try UFIForwardingState.validate(smtp, method: .smtp))
        smtp["unexpected"] = "value"
        XCTAssertThrowsError(try UFIForwardingState.validate(smtp, method: .smtp))
        var robot = [
            "webhook_url": "https://oapi.dingtalk.com/robot/send?access_token=test",
            "secret": "", "forward_dev_info": "0",
        ]
        XCTAssertNoThrow(try UFIForwardingState.validate(robot, method: .dingtalk))
        robot["webhook_url"] = "https://oapi.dingtalk.com/robot/send"
        XCTAssertThrowsError(try UFIForwardingState.validate(robot, method: .dingtalk))
    }

    func testLocalDraftIsDeviceScopedAndExplicitlyRemovable() throws {
        let id = "test-" + UUID().uuidString
        defer { try? UFISMSDraft.remove(deviceID: id) }
        let draft = UFISMSDraft(number: "10010", text: "草稿")
        try draft.save(deviceID: id)
        XCTAssertEqual(UFISMSDraft.load(deviceID: id), draft)
        XCTAssertNil(UFISMSDraft.load(deviceID: id + "-other"))
        try UFISMSDraft.remove(deviceID: id)
        XCTAssertNil(UFISMSDraft.load(deviceID: id))
    }

    func testLiveForwardingAndDNSReadOnly() async throws {
        guard let path = ProcessInfo.processInfo.environment["FLOWDECK_F50_TEST_CREDENTIALS"] else {
            throw XCTSkip("Private credentials not supplied")
        }
        let credentials = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let url = try XCTUnwrap(URL(string: try XCTUnwrap(credentials["ufiURL"])))
        let password = try XCTUnwrap(credentials["password"])
        let probe = UFIClient(baseURL: url, password: password)
        let snapshot = try await probe.snapshot()
        let client = UFIClient(baseURL: url, password: password, expectedFingerprint: snapshot.identityFingerprint)
        for method in UFIForwardingState.Method.allCases {
            let state = try await client.forwardingState(method: method)
            XCTAssertEqual(Set(state.values.keys), Set(method.keys))
        }
        let update = try await client.serviceUpdateState()
        XCTAssertFalse(update.version.isEmpty)
        for resolver in [false, true] {
            let result = try await client.dnsDiagnostic(publicResolver: resolver)
            XCTAssertEqual(result.outcome, .passed, result.detail)
        }
        // 签名助手读取原安装包副本，只传输公开 APK，不执行覆盖安装。
        let helper = try await UFISecureConfigChannel { try await client.shell($0, root: true) }.prepare()
        let metadata = try await client.shell(
            """
            umask 077
            mkdir -p /data/local/flowdeck-packages
            original=$(pm path com.minikano.f50_sms | sed -n 's/^package://p' | head -1)
            copy=/data/local/flowdeck-packages/test-installed.apk
            cp "$original" "$copy"
            CLASSPATH=\(helper) app_process /system/bin FlowDeckPackage "$copy"
            rm -f "$copy"
            """, root: true)
        XCTAssertTrue(metadata.contains("status=verified"))
        let data = Data(repeating: 42, count: 512 * 1024)
        let checksum = DeviceIdentity.digest(data)
        let packagePath = try UFIPackageTransfer.path(checksum: checksum)
        // 预置一个中断的公开测试包，验证实际续传与设备端最终摘要。
        _ = try await client.shell("printf '%s' '\(data.prefix(1024).base64EncodedString())' | base64 -d > \(packagePath).part", root: true)
        let uploaded = try await UFIPackageTransfer.send(
            data: data, checksum: checksum,
            command: { try await client.shell($0, root: true) }, progress: { _ in })
        XCTAssertEqual(uploaded, packagePath)
        let readback = try await client.shell("sha256sum \(packagePath); rm -f \(packagePath)", root: true)
        XCTAssertTrue(readback.hasPrefix(checksum))
    }
}

extension UFIParityTests {
    func testForwardingWritesOnceAndRejectsStaleOrUnconfirmedReadback() async throws {
        for mode in ["success", "stale", "unchanged"] {
            let identity = "model=F50\nserial=TESTF500001\nfirmware=F50_FLYMODEM_ZYV1.0.0B09"
            let values = [
                "smtp_host": "smtp.example.com", "smtp_port": "465", "smtp_to": "test@example.com",
                "smtp_username": "user", "smtp_password": "test", "smtp_from": "", "smtp_from_name": "", "forward_dev_info": "0",
            ]
            var target = values
            target["smtp_to"] = "next@example.com"
            var posts = 0
            ParityProtocol.handler = { request in
                switch request.url!.lastPathComponent {
                case "user_shell": return ["result": ["done": true, "content": identity]]
                case "sms_forward_enabled": return ["enabled": mode == "stale" ? "1" : "0"]
                case "sms_forward_method": return ["sms_forward_method": "SMTP"]
                case "sms_forward_blacklist": return ["phone": "", "keywords": ""]
                case "sms_forward_mail":
                    if request.httpMethod == "POST" {
                        posts += 1
                        return ["success": true]
                    }
                    return mode == "success" && posts > 0 ? target : values
                default: throw URLError(.badURL)
                }
            }
            defer { ParityProtocol.handler = nil }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [ParityProtocol.self]
            let client = UFIClient(
                baseURL: URL(string: "http://fixture:2333")!, password: "fixture",
                expectedFingerprint: try UFIClient.snapshot(from: identity).identityFingerprint,
                configuration: config)
            let original = UFIForwardingState(enabled: false, method: "SMTP", values: values, filter: ["phone": "", "keywords": ""])
            do {
                try await client.saveForwarding(target, method: .smtp, replacing: original)
                XCTAssertEqual(mode, "success")
            } catch {
                XCTAssertNotEqual(mode, "success")
            }
            XCTAssertEqual(posts, mode == "stale" ? 0 : 1)
        }
    }
}

private final class ParityProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> [String: Any])?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let object = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: object))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
