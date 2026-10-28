import XCTest

@testable import FlowDeck

/// 用 URLProtocol 验证原厂上传/恢复协议，所有请求都被本地替身拦截。
final class DeploymentTransportTests: XCTestCase {
    func testRestoreChecksUploadDigestAndIdentityBeforeSubmittingOnce() async throws {
        let (client, fixture, expected) = try makeClient(.success)
        try await client.restoreDeploymentBackup(fixture.package, expected: expected)
        XCTAssertEqual(fixture.restoreCount, 1)
        XCTAssertEqual(fixture.identityCount, 2)
        XCTAssertTrue(fixture.multipartValid)
    }

    func testWrongUploadDigestNeverRestores() async throws {
        let (client, fixture, expected) = try makeClient(.wrongDigest)
        do {
            try await client.restoreDeploymentBackup(fixture.package, expected: expected)
            XCTFail("摘要不匹配必须阻止恢复")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("上传摘要"))
        }
        XCTAssertEqual(fixture.restoreCount, 0)
    }

    func testChangedHardwareAfterUploadNeverRestores() async throws {
        let (client, fixture, expected) = try makeClient(.changedIdentity)
        do {
            try await client.restoreDeploymentBackup(fixture.package, expected: expected)
            XCTFail("上传后身份变化必须阻止恢复")
        } catch {
            XCTAssertTrue(error is ManagementError)
        }
        XCTAssertEqual(fixture.restoreCount, 0)
        XCTAssertEqual(fixture.identityCount, 2)
    }

    func testLostRestoreResponseDoesNotAutomaticallyResubmit() async throws {
        let (client, fixture, expected) = try makeClient(.lostResponse)
        do {
            try await client.restoreDeploymentBackup(fixture.package, expected: expected)
            XCTFail("响应丢失不得报告完成")
        } catch {}
        XCTAssertEqual(fixture.restoreCount, 1)
    }

    func testUnsupportedFirmwareDoesNotUploadOrRestore() async throws {
        let (client, fixture, expected) = try makeClient(.unsupportedFirmware)
        do {
            try await client.restoreDeploymentBackup(fixture.package, expected: expected)
            XCTFail("未知固件不得写入")
        } catch {}
        XCTAssertEqual(fixture.restoreCount, 0)
        XCTAssertFalse(fixture.multipartValid)
    }

    private func makeClient(_ scenario: DeploymentHTTPFixture.Scenario) throws -> (FactoryClient, DeploymentHTTPFixture, FactoryDeploymentIdentity) {
        let host = UUID().uuidString.lowercased() + ".test"
        let fixture = DeploymentHTTPFixture(scenario)
        DeploymentURLProtocol.register(fixture, host: host)
        addTeardownBlock { DeploymentURLProtocol.remove(host: host) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeploymentURLProtocol.self]
        let client = try FactoryClient(host: host, password: "fixture-password", configuration: configuration)
        let expected = FactoryDeploymentIdentity(
            imei: DeploymentHTTPFixture.imei, firmware: FactoryBootstrap.firmware,
            fingerprint: DeviceIdentity.fingerprint(model: "MU5250", imei: DeploymentHTTPFixture.imei)!)
        return (client, fixture, expected)
    }
}

/// 每个测试使用独立主机映射；锁保护 URLSession 回调线程和测试线程之间的计数。
private final class DeploymentHTTPFixture: @unchecked Sendable {
    enum Scenario { case success, wrongDigest, changedIdentity, lostResponse, unsupportedFirmware }
    static let imei = "868000001234567"
    let package = Data("Salted__".utf8) + Data(repeating: 1, count: 24)
    private let scenario: Scenario
    private let lock = NSLock()
    private var identities = 0
    private var restores = 0
    private var validUpload = false
    var identityCount: Int { lock.withLock { identities } }
    var restoreCount: Int { lock.withLock { restores } }
    var multipartValid: Bool { lock.withLock { validUpload } }

    init(_ scenario: Scenario) { self.scenario = scenario }

    func response(to request: URLRequest) throws -> Data {
        try lock.withLock {
            let body: Data
            if let data = request.httpBody {
                body = data
            } else if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bytes = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    bytes.append(contentsOf: buffer.prefix(count))
                }
                body = bytes
            } else {
                throw URLError(.badServerResponse)
            }
            if request.url?.absoluteString.contains("cgi-upload") == true {
                let text = String(decoding: body, as: UTF8.self)
                validUpload =
                    request.httpMethod == "POST" && text.contains("name=\"filename\"")
                    && text.contains("/tmp/back_parameter") && text.contains("name=\"filedata\"")
                    && body.range(of: package) != nil
                return try JSONSerialization.data(withJSONObject: ["sha256sum": scenario == .wrongDigest ? "wrong" : DeviceIdentity.digest(package)])
            }
            guard let calls = try JSONSerialization.jsonObject(with: body) as? [[String: Any]],
                let params = calls.first?["params"] as? [Any], let method = params[2] as? String
            else { throw URLError(.badServerResponse) }
            let result: [Any]
            switch method {
            case "web_login_info": result = [0, ["zte_web_sault": "fixture-salt"]]
            case "web_login": result = [0, ["ubus_rpc_session": "fixture-session"]]
            case "device_info":
                identities += 1
                result = [
                    0,
                    [
                        "imei": scenario == .changedIdentity && identities == 2 ? "868000001234568" : Self.imei,
                        "wa_inner_version": scenario == .unsupportedFirmware ? "unknown-B29" : FactoryBootstrap.firmware,
                    ],
                ]
            case "device_restore_proc":
                restores += 1
                guard params[1] as? String == "zwrt_mc.device.manager",
                    (params[3] as? [String: String])?["procType"] == "web"
                else { throw URLError(.badServerResponse) }
                if scenario == .lostResponse { throw URLError(.networkConnectionLost) }
                result = [0]
            default: throw URLError(.unsupportedURL)
            }
            return try JSONSerialization.data(withJSONObject: [["result": result]])
        }
    }
}

private final class DeploymentURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var fixtures: [String: DeploymentHTTPFixture] = [:]

    static func register(_ fixture: DeploymentHTTPFixture, host: String) {
        lock.withLock { fixtures[host] = fixture }
    }

    static func remove(host: String) {
        _ = lock.withLock { fixtures.removeValue(forKey: host) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let fixture = try XCTUnwrap(Self.lock.withLock { Self.fixtures[request.url?.host ?? ""] })
            let data = try fixture.response(to: request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
