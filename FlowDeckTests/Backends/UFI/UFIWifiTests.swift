import XCTest

@testable import FlowDeck

/// F50 goform 认证、单频段写入与中断边界。真机用例仅登录及读取，不重载无线网络。
final class UFIWifiTests: XCTestCase {
    private let identity = "model=F50\nserial=TESTF500001\nfirmware=F50_FLYMODEM_ZYV1.0.0B09"

    private var point: UFIWifiAccessPoint {
        UFIWifiAccessPoint(
            chip: "1", index: "0", enabled: true, authMode: "WPA2PSK", isolation: nil,
            ssid: "F50 test", password: "test-password", hidden: false, maxClients: 10)
    }

    override func tearDown() {
        WifiProtocol.handler = nil
        super.tearDown()
    }

    func testParseActualF50ShapeAndRejectIncompleteOrDuplicatePoints() throws {
        let original = point
        XCTAssertEqual(try UFIWifiAccessPoint.parse(response(original)), [original])
        var fields = response(original).raw["ResponseList"] as! [[String: Any]]
        fields[0]["ApBroadcastDisabled"] = "unexpected"
        XCTAssertThrowsError(try UFIWifiAccessPoint.parse(JSONObject(["ResponseList": fields])))
        fields[0]["ApBroadcastDisabled"] = "0"
        fields[0]["Password"] = "%%%"
        XCTAssertThrowsError(try UFIWifiAccessPoint.parse(JSONObject(["ResponseList": fields])))
        let item = response(original).raw["ResponseList"] as! [[String: Any]]
        XCTAssertThrowsError(try UFIWifiAccessPoint.parse(JSONObject(["ResponseList": item + item])))
        XCTAssertThrowsError(try UFIWifiAccessPoint.parse(JSONObject(["Error": "not logged in"])))
    }

    func testFormPreservesSecurityAndEncodesNamesAndPasswords() throws {
        var target = point
        target.ssid = "随身 + & = Wi-Fi"
        target.password = "p+a&ss=word?"
        target.hidden = true
        let form = try target.form()
        let encoded = UFIClient.formData(form)
        let decoded = decode(encoded)
        XCTAssertEqual(decoded["SSID"], target.ssid)
        XCTAssertEqual(decoded["Password"], Data(target.password.utf8).base64EncodedString())
        XCTAssertEqual(decoded["AuthMode"], "WPA2PSK")
        XCTAssertEqual(decoded["EncrypType"], "CCMP")
        XCTAssertEqual(decoded["ChipIndex"], "1")
        XCTAssertEqual(decoded["ApBroadcastDisabled"], "1")
        XCTAssertNil(decoded["AccessPointSwitchStatus"])
        XCTAssertNil(decoded["SwitchOption"])
        XCTAssertNil(decoded["ApIsolate"])
        target.ssid = String(repeating: "中", count: 11)
        XCTAssertThrowsError(try target.validate())
        target.ssid = "valid"
        target.password = "bad\npassword"
        XCTAssertThrowsError(try target.validate())
    }

    func testLoginAndSaveUseFactoryCookieAndADAndOnlyOneAccessPoint() async throws {
        var target = point
        target.ssid = "New + 中文"
        target.maxClients = 9
        let expected = target
        var writes = 0
        installFixture { request, form in
            writes += 1
            XCTAssertEqual(form["goformId"], "setAccessPointInfo")
            XCTAssertEqual(form["SSID"], expected.ssid)
            XCTAssertEqual(form["ChipIndex"], "1")
            XCTAssertEqual(form["ApMaxStationNumber"], "9")
            XCTAssertEqual(form["AD"], UFIClient.factoryDigest(UFIClient.factoryDigest("innerouter") + "RD-value"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Kano-Cookie"), "stok=fixture-cookie")
            return ["result": "success"]
        }
        try await client().saveWifiAccessPoint(target, replacing: point, password: "factory-test")
        XCTAssertEqual(writes, 1)
    }

    func testConcurrentConfigurationChangeStopsBeforeWrite() async throws {
        var other = point
        other.ssid = "Changed elsewhere"
        var writes = 0
        installFixture(current: other) { _, _ in
            writes += 1
            return ["result": "success"]
        }
        var target = point
        target.ssid = "Requested"
        do {
            try await client().saveWifiAccessPoint(target, replacing: point, password: "factory-test")
            XCTFail("Stale configuration must not be overwritten")
        } catch { XCTAssertTrue(error.localizedDescription.contains("其他操作")) }
        XCTAssertEqual(writes, 0)
    }

    func testDisconnectNeverReplaysWrite() async throws {
        var writes = 0
        installFixture { _, _ in
            writes += 1
            throw URLError(.networkConnectionLost)
        }
        do {
            try await client().saveWifiAccessPoint(point, replacing: point, password: "factory-test")
            XCTFail("Network loss must remain unconfirmed")
        } catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        XCTAssertEqual(writes, 1)
    }

    func testWrongPasswordStopsBeforeConfigurationWrite() async throws {
        var writes = 0
        installFixture(loginResult: "3") { _, _ in
            writes += 1
            return ["result": "success"]
        }
        do {
            _ = try await client().readWifiAccessPoints(password: "factory-test")
            XCTFail("Rejected login must not expose editable defaults")
        } catch { XCTAssertTrue(error.localizedDescription.contains("原厂登录未通过")) }
        XCTAssertEqual(writes, 0)
    }

    func testChangedDeviceAndUnsupportedFirmwareNeverWrite() async throws {
        for text in [identity.replacingOccurrences(of: "B09", with: "B07"), identity.replacingOccurrences(of: "0001", with: "0002")] {
            var writes = 0
            installFixture(identity: text) { _, _ in
                writes += 1
                return ["result": "success"]
            }
            do {
                try await client().saveWifiAccessPoint(point, replacing: point, password: "factory-test")
                XCTFail("Only the bound B09 device may be changed")
            } catch { XCTAssertTrue(error is ManagementError) }
            XCTAssertEqual(writes, 0)
        }
    }

    func testLiveF50WifiReadOnlyWhenCredentialsProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["FLOWDECK_F50_TEST_CREDENTIALS"] else {
            throw XCTSkip("No private F50 credential file supplied")
        }
        let credentials = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard let factory = credentials["factoryPassword"] else { throw XCTSkip("Factory password not supplied") }
        let base = try XCTUnwrap(URL(string: try XCTUnwrap(credentials["ufiURL"])))
        let password = try XCTUnwrap(credentials["password"])
        let probe = UFIClient(baseURL: base, password: password)
        let snapshot = try await probe.snapshot()
        let client = UFIClient(baseURL: base, password: password, expectedFingerprint: snapshot.identityFingerprint)
        let points = try await client.readWifiAccessPoints(password: factory)
        XCTAssertEqual(Set(points.map(\.chip)), ["0", "1"])
        XCTAssertTrue(points.contains(where: \.enabled))
        for point in points { try point.validate() }
        try await client.verifyWifiFirmware()
        let clients = try await client.readClients(password: factory)
        XCTAssertFalse(clients.isEmpty)
        let messages = try await client.readMessages(page: 0, password: factory)
        XCTAssertLessThanOrEqual(messages.count, 20)
        let storage = try await client.messageStorage(password: factory)
        XCTAssertNil(storage.listWarning(loadedCount: messages.count))
        let details = try await client.factoryDetails(password: factory)
        XCTAssertNotNil(details.string("apn_mode"))
        let access = try await client.readClientAccess(password: factory)
        XCTAssertTrue(["0", "1", "2"].contains(access.fields["AclMode"] ?? ""))
        let apns = try await client.readAPNs(password: factory)
        XCTAssertTrue(["auto", "manual"].contains(apns.mode))
        XCTAssertNotNil(details.string("net_select"))
        XCTAssertNotNil(details.string("usb_network_protocal"))
        let clock = try await client.readClock()
        XCTAssertNotNil(Int(clock.trimmingCharacters(in: .whitespacesAndNewlines)))
        let hardware = try await client.hardwareDetails()
        XCTAssertNotNil(hardware.version)
        XCTAssertNotNil(hardware.memoryUsage)
        // 不将真实 SSID、密码或会话内容作为断言消息写入测试日志。
    }

    func testMessageQueryMatchesUFIAllMessagesAndPreservesPage() async throws {
        installFixture { _, _ in
            XCTFail("Read should never modify messages")
            return [:]
        }
        let original = WifiProtocol.handler!
        WifiProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if query.first(where: { $0.name == "cmd" })?.value == "sms_data_total" {
                let fields = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(fields["tags"], "100")
                XCTAssertEqual(fields["page"], "1")
                XCTAssertEqual(fields["mem_store"], "1")
                return (
                    [
                        "messages": [
                            [
                                "id": "42", "number": "10010", "tag": "1",
                                "content": Data("测试消息".utf8).base64EncodedString(),
                            ]
                        ]
                    ], [:]
                )
            }
            return try original(request)
        }
        let messages = try await client().readMessages(page: 1, password: "factory-test")
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].unread)
    }

    func testFactoryActionRequiresCookieAndFreshChallenge() async throws {
        var writes = 0
        installFixture { request, fields in
            writes += 1
            XCTAssertEqual(fields["goformId"], "SET_MSG_READ")
            XCTAssertEqual(fields["msg_id"], "42;")
            XCTAssertEqual(fields["tag"], "0")
            XCTAssertEqual(fields["AD"], UFIClient.factoryDigest(UFIClient.factoryDigest("innerouter") + "RD-value"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Kano-Cookie"), "stok=fixture-cookie")
            return ["result": "success"]
        }
        try await client().performFactoryAction(.markMessageRead(42), password: "factory-test")
        XCTAssertEqual(writes, 1)
    }

    func testRebootDisconnectIsNeverRetried() async throws {
        var writes = 0
        installFixture { _, fields in
            writes += 1
            XCTAssertEqual(fields["goformId"], "REBOOT_DEVICE")
            throw URLError(.networkConnectionLost)
        }
        do {
            try await client().performFactoryAction(.reboot, password: "factory-test")
            XCTFail("Disconnect must remain unconfirmed")
        } catch { XCTAssertTrue(error is URLError) }
        XCTAssertEqual(writes, 1)
    }

    func testFactoryActionRejectsUnsupportedFirmwareBeforeWrite() async throws {
        var writes = 0
        installFixture(identity: identity.replacingOccurrences(of: "B09", with: "B07")) { _, _ in
            writes += 1
            return ["result": "success"]
        }
        do {
            try await client().performFactoryAction(.reboot, password: "factory-test")
            XCTFail("Unverified firmware must not be changed")
        } catch { XCTAssertTrue(error is ManagementError) }
        XCTAssertEqual(writes, 0)
    }

    private func response(_ value: UFIWifiAccessPoint) -> JSONObject {
        JSONObject([
            "ResponseList": [
                [
                    "ChipIndex": value.chip, "AccessPointIndex": value.index, "AccessPointSwitchStatus": value.enabled ? "1" : "0",
                    "SSID": value.ssid, "Password": Data(value.password.utf8).base64EncodedString(), "AuthMode": value.authMode,
                    "ApBroadcastDisabled": value.hidden ? "1" : "0", "ApMaxStationNumber": value.maxClients,
                ]
            ]
        ])
    }

    private func client() throws -> UFIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WifiProtocol.self]
        return UFIClient(
            baseURL: URL(string: "http://ufi.fixture:2333")!, password: "test-password",
            expectedFingerprint: try UFIClient.snapshot(from: identity).identityFingerprint, configuration: configuration)
    }

    private func installFixture(
        current: UFIWifiAccessPoint? = nil, identity: String? = nil, loginResult: String = "0",
        write: @escaping (URLRequest, [String: String]) throws -> [String: Any]
    ) {
        let snapshot = identity ?? self.identity
        let response = response(current ?? point).raw
        WifiProtocol.handler = { request in
            let headers = UFIClient.headers(
                password: "test-password", method: request.httpMethod!, path: request.url!.path,
                timestamp: request.value(forHTTPHeaderField: "kano-t")!)
            XCTAssertEqual(request.value(forHTTPHeaderField: "kano-sign"), headers["kano-sign"])
            if request.url?.path == "/api/user_shell" { return (["result": ["done": true, "content": snapshot]], [:]) }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            if request.httpMethod == "GET" {
                XCTAssertEqual(query?.last?.name, "_")
                switch query?.first(where: { $0.name == "cmd" })?.value {
                case "LD": return (["LD": "LD-value"], [:])
                case "loginfo":
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Kano-Cookie"), "stok=fixture-cookie")
                    return (["loginfo": "ok"], [:])
                case "queryAccessPointInfo": return (response, [:])
                case "wa_inner_version,cr_version": return (["wa_inner_version": "inner", "cr_version": "outer"], [:])
                case "RD": return (["RD": "RD-value"], [:])
                default: throw URLError(.unsupportedURL)
                }
            }
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/x-www-form-urlencoded") == true)
            let fields = self.decode(Self.body(request))
            if fields["goformId"] == "LOGIN" {
                XCTAssertEqual(fields["password"], UFIClient.factoryDigest(UFIClient.factoryDigest("factory-test") + "LD-value"))
                return (["result": loginResult], ["kano-cookie": "stok=fixture-cookie; Path=/"])
            }
            return (try write(request, fields), [:])
        }
    }

    private func decode(_ data: Data) -> [String: String] {
        let components = URLComponents(string: "http://fixture/?" + (String(data: data, encoding: .utf8) ?? ""))
        return Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    private static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

private final class WifiProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> ([String: Any], [String: String]))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            let (object, headers) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: object))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}
