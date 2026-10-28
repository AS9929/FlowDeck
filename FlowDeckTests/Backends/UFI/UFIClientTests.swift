import XCTest

@testable import FlowDeck

/// 协议、旧设备兼容和错误边界均使用内存替身；真机检查必须显式提供本机私有凭据文件。
final class UFIClientTests: XCTestCase {
    private let snapshotText = """
        model=F50
        serial=TESTF500001
        firmware=F50_FLYMODEM_ZYV1.0.0B09
        uptime=123.45
        memoryTotal=1503044
        memoryAvailable=600000
        """

    override func tearDown() {
        UFIURLProtocol.handler = nil
        super.tearDown()
    }

    func testAuthorSignatureVector() {
        let headers = UFIClient.headers(
            password: "test-password", method: "POST",
            path: "/api/user_shell", timestamp: "1700000000000")
        XCTAssertEqual(
            headers["kano-sign"], "7124a4373d9aaf9d2c3a13dd6eea342ceef954cac19b9c75945bfe8b1e54f78d")
        XCTAssertEqual(headers["authorization"], DeviceIdentity.digest(Data("test-password".utf8)))
        XCTAssertEqual(headers["kano-t"], "1700000000000")
    }

    func testSnapshotHasDistinctIdentityAndNoInventedBattery() throws {
        let snapshot = try UFIClient.snapshot(from: snapshotText)
        XCTAssertEqual(snapshot.model, "MU300")
        XCTAssertEqual(snapshot.uptime, 123)
        XCTAssertEqual(snapshot.memAvailKB, 600000)
        XCTAssertNil(snapshot.battery)
        XCTAssertNil(snapshot.imei)
        XCTAssertNotNil(snapshot.identityFingerprint)
        let another = try UFIClient.snapshot(
            from: snapshotText.replacingOccurrences(of: "TESTF500001", with: "TESTF500002"))
        XCTAssertNotEqual(snapshot.identityFingerprint, another.identityFingerprint)
        XCTAssertThrowsError(try UFIClient.snapshot(from: "model=F50\nserial="))
        XCTAssertThrowsError(
            try UFIClient.snapshot(
                from: snapshotText.replacingOccurrences(of: "model=F50", with: "model=Unknown")))
    }

    func testOldProfileKeepsWebSSHAndOriginalCredentialKey() throws {
        let id = UUID()
        let data = Data("{\"id\":\"\(id)\",\"name\":\"U60\"}".utf8)
        let profile = try JSONDecoder().decode(DeviceProfile.self, from: data)
        XCTAssertEqual(profile.backend, .webSSH)
        XCTAssertEqual(profile.webPort, 8899)
        XCTAssertEqual(profile.webPasswordAccount, "webssh-password-\(id.uuidString)")
        var ufi = profile
        ufi.backend = .ufiTools
        XCTAssertNotEqual(ufi.webPasswordAccount, profile.webPasswordAccount)
        let roundtrip = try JSONDecoder().decode(DeviceProfile.self, from: JSONEncoder().encode(ufi))
        XCTAssertEqual(roundtrip.backend, .ufiTools)
    }

    func testUserShellEnvelopeAndChangedDeviceRejection() async throws {
        let text = snapshotText
        UFIURLProtocol.handler = { request in
            if request.url?.path == "/api/goform/goform_get_cmd_process" {
                XCTAssertEqual(request.httpMethod, "GET")
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(query?.first(where: { $0.name == "multi_data" })?.value, "1")
                XCTAssertTrue(query?.first(where: { $0.name == "cmd" })?.value?.contains("ppp_status") == true)
                let timestamp = request.value(forHTTPHeaderField: "kano-t") ?? ""
                let expected = UFIClient.headers(
                    password: "test-password", method: "GET", path: request.url!.path, timestamp: timestamp)
                XCTAssertEqual(request.value(forHTTPHeaderField: "kano-sign"), expected["kano-sign"])
                return (200, ["ppp_status": "ipv4_ipv6_connected", "network_type": "5G", "Z5g_rsrp": -95])
            }
            XCTAssertEqual(request.url?.path, "/api/user_shell")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "kano-sign"))
            return (200, ["result": ["done": true, "content": text]])
        }
        let snapshot = try await client().snapshot()
        XCTAssertEqual(snapshot.model, "MU300")
        XCTAssertEqual(snapshot.connected, true)
        XCTAssertEqual(snapshot.rsrp, -95)
        XCTAssertNil(snapshot.cellularStatusError)
        do {
            _ = try await client(fingerprint: "other-device").snapshot()
            XCTFail("Changed device must not be accepted")
        } catch {
            XCTAssertEqual(error as? ManagementError, .deviceChanged)
        }
    }

    func testCellularParsingSeparatesNRAndLTEAndUnknownStates() {
        let nr = UFIClient.applyingCellular(
            JSONObject([
                "network_provider": "中国联通", "network_type": "5G", "ppp_status": "ipv4_ipv6_connected",
                "signalbar": "5", "Z5g_rsrp": "-95", "lte_rsrp": -110,
            ]), to: DeviceSnapshot())
        XCTAssertEqual(nr.operatorName, "中国联通")
        XCTAssertTrue(nr.isNR)
        XCTAssertEqual(nr.connected, true)
        XCTAssertEqual(nr.signalBars, 5)
        XCTAssertEqual(nr.rsrp, -95)

        let lte = UFIClient.applyingCellular(
            JSONObject([
                "network_type": "LTE", "ppp_status": "ppp_disconnected", "Z5g_rsrp": -95,
                "lte_rsrp": "-108", "signalbar": 3,
            ]), to: nr)
        XCTAssertFalse(lte.isNR)
        XCTAssertEqual(lte.connected, false)
        XCTAssertEqual(lte.rsrp, -108)
        XCTAssertNil(lte.operatorName)

        let unknown = UFIClient.applyingCellular(JSONObject(["Error": "none secure connection"]), to: nr)
        XCTAssertNil(unknown.connected)
        XCTAssertNil(unknown.operatorName)
        XCTAssertNil(unknown.rsrp)
        XCTAssertNotNil(unknown.cellularStatusError)

        for invalid in ["0", "-999", "NaN", "inf", "unavailable", ""] {
            let result = UFIClient.applyingCellular(
                JSONObject(["network_type": "5G", "Z5g_rsrp": invalid, "signalbar": invalid]),
                to: DeviceSnapshot())
            XCTAssertNil(result.rsrp)
            if invalid != "0" { XCTAssertNil(result.signalBars) }
        }
    }

    func testCellularFailurePreservesVerifiedSystemSnapshot() async throws {
        let text = snapshotText
        UFIURLProtocol.handler = { request in
            if request.url?.path == "/api/user_shell" {
                return (200, ["result": ["done": true, "content": text]])
            }
            return (503, ["error": "private-backend-response"])
        }
        let snapshot = try await client().snapshot()
        XCTAssertNotNil(snapshot.identityFingerprint)
        XCTAssertEqual(snapshot.uptime, 123)
        XCTAssertNil(snapshot.connected)
        XCTAssertNotNil(snapshot.cellularStatusError)
        XCTAssertFalse(snapshot.cellularStatusError?.contains("private-backend") == true)
    }

    func testWrongPasswordDoesNotExposeResponse() async {
        UFIURLProtocol.handler = { _ in (401, ["error": "private-response-do-not-show"]) }
        do {
            _ = try await client().snapshot()
            XCTFail("Unauthorized response must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("UFI-TOOLS"))
            XCTAssertFalse(error.localizedDescription.contains("private-response"))
        }
    }

    func testUnknownAdapterCannotStartOrModifyService() async throws {
        let text = snapshotText
        var requests = [String]()
        UFIURLProtocol.handler = { request in
            requests.append(request.url!.path)
            if request.url!.path == "/api/user_shell" {
                return (200, ["result": ["done": true, "content": text]])
            }
            return (200, ["result": "0\nunknown-hash  /data/clash/Scripts/Clash.Service"])
        }
        let fingerprint = try XCTUnwrap(UFIClient.snapshot(from: text).identityFingerprint)
        do {
            _ = try await client(fingerprint: fingerprint).control(.start)
            XCTFail("Unknown service adapter must not execute")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("适配器"))
        }
        XCTAssertEqual(requests, ["/api/user_shell", "/api/root_shell"])
    }

    func testUnboundConfigNeverTransmitsSecrets() async {
        UFIURLProtocol.handler = { _ in
            XCTFail("Unbound file write must not send any network request")
            return (500, [:])
        }
        do {
            try await client().saveConfig("secret: private-config")
            XCTFail("Unbound operation must throw")
        } catch {
            XCTAssertTrue(error is ManagementError)
        }
    }

    @MainActor
    func testF50SystemActionsStayRestricted() {
        XCTAssertTrue(ManagementDestination.service.supportsUFI)
        XCTAssertTrue(ManagementDestination.runtime.supportsUFI)
        XCTAssertFalse(ManagementDestination.factory.supportsUFI)
        XCTAssertFalse(ManagementDestination.backup.supportsUFI)
        XCTAssertTrue(ManagementDestination.updates.supportsUFI)
        XCTAssertTrue(ManagementDestination.history.supportsUFI)
    }

    /// 可选真机只读验收；不在源码/测试报告记录凭据、序列号或完整配置。
    func testLiveF50ReadOnlyWhenExplicitlyConfigured() async throws {
        guard let path = ProcessInfo.processInfo.environment["FLOWDECK_F50_TEST_CREDENTIALS"] else {
            throw XCTSkip("未提供真机私有测试配置")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        let base = try XCTUnwrap(URL(string: try XCTUnwrap(fields["ufiURL"])))
        let password = try XCTUnwrap(fields["password"])
        let probe = UFIClient(baseURL: base, password: password)
        let snapshot = try await probe.snapshot()
        XCTAssertNil(snapshot.cellularStatusError)
        XCTAssertNotNil(snapshot.connected)
        XCTAssertNotNil(snapshot.operatorName)
        XCTAssertNotNil(snapshot.networkType)
        XCTAssertNotNil(snapshot.rsrp)
        let fingerprint = try XCTUnwrap(snapshot.identityFingerprint)
        let controller = try XCTUnwrap(URL(string: try XCTUnwrap(fields["controller"])))
        let mihomo = MihomoClient(baseURL: controller, secret: try XCTUnwrap(fields["secret"]))
        let verified = UFIClient(
            baseURL: base, password: password, expectedFingerprint: fingerprint, mihomo: mihomo)
        try await verified.verifyServiceAdapter()
        let status = try await verified.mihomoStatus()
        XCTAssertTrue(status.running)
        XCTAssertTrue(status.autostart)
        XCTAssertTrue(status.apiReachable)
        let check = try await verified.checkConfig()
        XCTAssertTrue(check.ok)
        let version = try await mihomo.version()
        XCTAssertFalse(version.version.isEmpty)
        let proxies = try await mihomo.proxies()
        XCTAssertNotNil(proxies["Proxies"])
        let rules = try await mihomo.rules()
        XCTAssertFalse(rules.isEmpty)
    }

    private func client(fingerprint: String? = nil) -> UFIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UFIURLProtocol.self]
        return UFIClient(
            baseURL: URL(string: "http://ufi.fixture:2333")!, password: "test-password",
            expectedFingerprint: fingerprint, configuration: configuration)
    }
}

private final class UFIURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: Any]))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (status, object) = try Self.handler!(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: object))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
