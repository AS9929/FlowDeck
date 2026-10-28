import XCTest

@testable import FlowDeck

/// F50 写协议使用模拟响应验证；唯一真机用例只读取，不发送短信或改变网络。
final class UFIControlTests: XCTestCase {
    private let identity = "model=F50\nserial=TESTF500001\nfirmware=F50_FLYMODEM_ZYV1.0.0B09"

    override func tearDown() {
        ControlProtocol.handler = nil
        super.tearDown()
    }

    private func apnObject() -> [String: Any] {
        var object: [String: Any] = ["apn_mode": "auto", "Current_index": "", "default_APN_size": "1"]
        for index in 0..<20 {
            object["APN_config\(index)"] = ""
            object["ipv6_APN_config\(index)"] = ""
        }
        return object
    }

    private func profile() -> UFIAPNProfile {
        var value = UFIAPNProfile.draft(index: 1)
        value.name = "运营商"
        value.apn = "example.net"
        value.ipv4[5] = "user+name"
        value.ipv4[6] = "p&a=ss"
        return value
    }

    private func stored(_ profile: UFIAPNProfile) -> [String: Any] {
        var object = apnObject()
        for (fields, prefix) in [(profile.ipv4, ""), (profile.ipv6, "ipv6_")] {
            var values = fields
            values[0] = profile.name
            values[7] = profile.protocolType
            object[prefix + "APN_config\(profile.index)"] = values.joined(separator: "($)")
        }
        return object
    }

    func testAPNRequiresCompleteSlotResponse() throws {
        var object = apnObject()
        XCTAssertEqual(try UFIAPNState(JSONObject(object)).freeIndex, 1)
        object.removeValue(forKey: "APN_config19")
        XCTAssertThrowsError(try UFIAPNState(JSONObject(object)))
        object = apnObject()
        object["APN_config1"] = "bad($)shape"
        XCTAssertThrowsError(try UFIAPNState(JSONObject(object)))
    }

    func testAPNPreservesBothFamiliesAndCredentials() throws {
        let value = profile()
        let form = try value.form()
        XCTAssertEqual(form["wan_apn"], "example.net")
        XCTAssertEqual(form["ipv6_wan_apn"], "example.net")
        XCTAssertEqual(form["ppp_passwd"], "p&a=ss")
        XCTAssertEqual(try UFIAPNState(JSONObject(stored(value))).profiles.first?.form(), form)
        let state = try UFIAPNState(JSONObject(stored(value)))
        XCTAssertEqual(try JSONDecoder().decode(UFIAPNState.self, from: JSONEncoder().encode(state)), state)
    }

    func testAPNRejectsDelimiterAndUnknownProtocol() throws {
        var value = profile()
        value.name = "bad($)value"
        XCTAssertThrowsError(try value.form())
        value = profile()
        value.protocolType = "unknown"
        XCTAssertThrowsError(try value.form())
        value = profile()
        value.ipv6[4] = "guess"
        XCTAssertThrowsError(try value.form())
    }

    func testPINFormsAndASCIIValidation() throws {
        XCTAssertEqual(try UFIPINOperation.change.form(pin: "1234", newPIN: "5678", puk: "")["NewPinNumber"], "5678")
        XCTAssertEqual(try UFIPINOperation.unblock.form(pin: "", newPIN: "1234", puk: "12345678")["goformId"], "ENTER_PUK")
        XCTAssertThrowsError(try UFIPINOperation.enable.form(pin: "１２３４", newPIN: "", puk: ""))
        XCTAssertThrowsError(try UFIPINOperation.unblock.form(pin: "", newPIN: "1234", puk: "123"))
    }

    func testSMSUnicodeAndTimezoneEncoding() throws {
        let form = try UFISMSComposer.form(
            number: "+8610010", text: "你好 + &", date: Date(timeIntervalSince1970: 0),
            timeZone: TimeZone(secondsFromGMT: 28_800)!)
        XCTAssertEqual(form["MessageBody"], "4F60597D0020002B00200026")
        XCTAssertEqual(form["sms_time"], "70;01;01;08;00;00;+8")
        XCTAssertEqual(form["ID"], "-1")
        XCTAssertThrowsError(try UFISMSComposer.form(number: "10010", text: "😀"))
        XCTAssertThrowsError(try UFISMSComposer.form(number: "10010&x=1", text: "hello"))
        XCTAssertThrowsError(try UFISMSComposer.form(number: "10010", text: String(repeating: "中", count: 501)))
    }

    func testAPNSaveChecksCompleteReadback() async throws {
        let before = try UFIAPNState(JSONObject(apnObject()))
        let target = profile()
        var wrote = false
        fixture { _ in
            wrote ? self.stored(target) : self.apnObject()
        } write: { fields in
            XCTAssertEqual(fields["goformId"], "APN_PROC_EX")
            XCTAssertEqual(fields["ppp_passwd"], "p&a=ss")
            wrote = true
            return ["result": "success"]
        }
        try await client().saveAPN(target, replacing: before, password: "factory-test")
        XCTAssertTrue(wrote)
    }

    func testAPNUnchangedResponseCannotReportSuccess() async throws {
        let before = try UFIAPNState(JSONObject(stored(profile())))
        var target = profile()
        target.ipv4[6] = "different"
        var writes = 0
        fixture { _ in
            self.stored(self.profile())
        } write: { _ in
            writes += 1
            return ["result": "success"]
        }
        do {
            try await client().saveAPN(target, replacing: before, password: "factory-test")
            XCTFail("Credential readback must match")
        } catch { XCTAssertTrue(error is ManagementError) }
        XCTAssertEqual(writes, 1)
    }

    func testStaleAPNStopsBeforeWrite() async throws {
        let before = try UFIAPNState(JSONObject(apnObject()))
        var writes = 0
        fixture { _ in
            self.stored(self.profile())
        } write: { _ in
            writes += 1
            return [:]
        }
        do {
            try await client().saveAPN(profile(), replacing: before, password: "factory-test")
            XCTFail("Stale APN must not be overwritten")
        } catch { XCTAssertTrue(error is ManagementError) }
        XCTAssertEqual(writes, 0)
    }

    func testPINWithNoRemainingAttemptsDoesNotSubmit() async throws {
        var writes = 0
        fixture { _ in
            ["pinnumber": "0", "puknumber": "0"]
        } write: { _ in
            writes += 1
            return [:]
        }
        do {
            try await client().operatePIN(.enable, pin: "1234", newPIN: "", puk: "", password: "factory-test")
            XCTFail("No remaining attempts")
        } catch { XCTAssertTrue(error is ManagementError) }
        XCTAssertEqual(writes, 0)
    }

    func testNetworkModeRequiresReadback() async throws {
        var writes = 0
        fixture { _ in
            ["net_select": "Only_LTE"]
        } write: { fields in
            XCTAssertEqual(fields["BearerPreference"], "Only_LTE")
            writes += 1
            return ["result": "success"]
        }
        try await client().setNetworkMode(.lte, password: "factory-test")
        XCTAssertEqual(writes, 1)
    }

    func testUSBReadbackMismatchIsUnconfirmed() async throws {
        var writes = 0
        fixture { _ in
            ["usb_network_protocal": "0"]
        } write: { _ in
            writes += 1
            return ["result": "success"]
        }
        do {
            try await client().setUSBProtocol("2", password: "factory-test")
            XCTFail("Acknowledgement alone is insufficient")
        } catch { XCTAssertTrue(error is ManagementError) }
        XCTAssertEqual(writes, 1)
    }

    func testInvalidUSBAndDisabledAllBandsNeverContactDevice() async throws {
        ControlProtocol.handler = { _ in
            XCTFail("Invalid input should not contact device")
            throw URLError(.badURL)
        }
        do {
            try await client().setUSBProtocol("3", password: "factory-test")
            XCTFail("Invalid USB mode")
        } catch { XCTAssertTrue(error is ManagementError) }
        do {
            try await client().setWifiBands([], replacing: [], password: "factory-test")
            XCTFail("Must retain hotspot")
        } catch { XCTAssertTrue(error is ManagementError) }
    }

    func testSMSSuccessWaitsForCompletionAndNeverResends() async throws {
        var writes = 0
        var polls = 0
        fixture { command in
            XCTAssertEqual(command, "sms_cmd_status_info")
            polls += 1
            return ["sms_cmd_status_result": polls == 1 ? "1" : "3"]
        } write: { fields in
            XCTAssertEqual(fields["goformId"], "SEND_SMS")
            writes += 1
            return ["result": "success"]
        }
        try await client().sendMessage(number: "10010", text: "test", password: "factory-test")
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(polls, 2)
    }

    func testSMSFailureDoesNotResend() async throws {
        var writes = 0
        fixture { _ in
            ["sms_cmd_status_result": "2"]
        } write: { _ in
            writes += 1
            return ["result": "success"]
        }
        do {
            try await client().sendMessage(number: "10010", text: "test", password: "factory-test")
            XCTFail("Modem rejected SMS")
        } catch { XCTAssertTrue(error is ManagementError) }
        XCTAssertEqual(writes, 1)
    }

    func testDeleteSMSUsesTerminatedIDAndCompletionPolling() async throws {
        fixture { _ in
            ["sms_cmd_status_result": "3"]
        } write: { fields in
            XCTAssertEqual(fields["goformId"], "DELETE_SMS")
            XCTAssertEqual(fields["msg_id"], "42;")
            return ["result": "success"]
        }
        try await client().deleteMessage(id: 42, password: "factory-test")
    }

    func testAPNSelectionAndDeletePreserveMode() async throws {
        let original = try UFIAPNState(JSONObject(stored(profile())))
        var writes = 0
        fixture { _ in
            writes == 0 ? self.stored(self.profile()) : self.apnObject()
        } write: { fields in
            XCTAssertEqual(fields["apn_action"], "delete")
            XCTAssertEqual(fields["apn_mode"], "auto")
            writes += 1
            return ["result": "success"]
        }
        try await client().deleteAPN(original.profiles[0], from: original, password: "factory-test")
        XCTAssertEqual(writes, 1)
    }

    func testAPNPreinstalledProfileCannotBeDeleted() async throws {
        var object = stored(profile())
        object["default_APN_size"] = "2"
        let state = try UFIAPNState(JSONObject(object))
        ControlProtocol.handler = { _ in
            XCTFail("Preset rejection must happen before a request")
            throw URLError(.badURL)
        }
        do {
            try await client().deleteAPN(state.profiles[0], from: state, password: "factory-test")
            XCTFail("Preset APN must remain intact")
        } catch { XCTAssertTrue(error is ManagementError) }
    }

    func testRoamingPreservesManualDialAndReadsBack() async throws {
        var writes = 0
        fixture { _ in
            ["connectionMode": "manual_dial", "autoConnectWhenRoaming": writes == 0 ? "off" : "on"]
        } write: { fields in
            XCTAssertEqual(fields["ConnectionMode"], "manual_dial")
            XCTAssertEqual(fields["roam_setting_option"], "on")
            writes += 1
            return ["result": "success"]
        }
        try await client().setRoaming(true, password: "factory-test")
        XCTAssertEqual(writes, 1)
    }

    func testDualBandSwitchPreservesAtLeastOneNetworkAndReadsBack() async throws {
        var writes = 0
        func response(enabled: Set<String>) -> JSONObject {
            JSONObject([
                "ResponseList": ["0", "1"].map { chip in
                    [
                        "ChipIndex": chip, "AccessPointIndex": "0", "AccessPointSwitchStatus": enabled.contains(chip) ? "1" : "0",
                        "SSID": "fixture", "Password": Data("fixture-password".utf8).base64EncodedString(),
                        "AuthMode": "WPA2PSK", "ApBroadcastDisabled": "0", "ApMaxStationNumber": "10",
                    ]
                }
            ])
        }
        let before = try UFIWifiAccessPoint.parse(response(enabled: ["0", "1"]))
        fixture { _ in
            response(enabled: writes == 0 ? ["0", "1"] : ["1"]).raw
        } write: { fields in
            XCTAssertEqual(fields["goformId"], "switchWiFiChip")
            XCTAssertEqual(fields["ChipEnum"], "chip2")
            writes += 1
            return ["result": "success"]
        }
        try await client().setWifiBands(["1"], replacing: before, password: "factory-test")
        XCTAssertEqual(writes, 1)
    }

    func testPINAcceptedRequestStillRequiresStateReadback() async throws {
        var writes = 0
        fixture { _ in
            ["pin_status": "0", "pinnumber": "3", "puknumber": "10", "modem_main_state": "modem_init_complete"]
        } write: { fields in
            XCTAssertEqual(fields["goformId"], "ENABLE_PIN")
            writes += 1
            return ["result": "success"]
        }
        do {
            try await client().operatePIN(.enable, pin: "1234", newPIN: "", puk: "", password: "factory-test")
            XCTFail("Unchanged PIN state is not success")
        } catch { XCTAssertTrue(error is ManagementError) }
        XCTAssertEqual(writes, 1)
    }

    private func accessObject() -> [String: String] {
        [
            "AclMode": "2", "WhiteMacList": "11:22:33:44:55:66;", "WhiteNameList": "keep;",
            "BlackMacList": "AA:BB:CC:DD:EE:FF;", "BlackNameList": "blocked;",
        ]
    }

    func testACLRetainsWhiteListAndAllowsUnblock() throws {
        let state = try UFIClientAccess(JSONObject(accessObject()))
        let actual = try state.changing(mac: "aa:bb:cc:dd:ee:ff", name: "blocked", blocked: false)
        XCTAssertTrue(actual.blocked.isEmpty)
        XCTAssertEqual(actual.fields["WhiteMacList"], state.fields["WhiteMacList"])
        XCTAssertEqual(actual.fields["WhiteNameList"], "keep;")
        XCTAssertEqual(actual.fields["AclMode"], "2")
    }

    func testACLRejectsUnknownShapeAndDoesNotSwitchWhitelistMode() throws {
        var object = accessObject()
        object["AclMode"] = "1"
        let state = try UFIClientAccess(JSONObject(object))
        XCTAssertThrowsError(try state.changing(mac: "AA:BB:CC:DD:EE:FF", name: "blocked", blocked: false))
        object.removeValue(forKey: "BlackNameList")
        XCTAssertThrowsError(try UFIClientAccess(JSONObject(object)))
        object = accessObject()
        object["BlackMacList"] = "not-a-mac;"
        XCTAssertThrowsError(try UFIClientAccess(JSONObject(object)))
    }

    func testACLUnblockPostsBothListsAndVerifiesResult() async throws {
        let original = try UFIClientAccess(JSONObject(accessObject()))
        let target = try original.changing(mac: "AA:BB:CC:DD:EE:FF", name: "blocked", blocked: false)
        var writes = 0
        fixture { _ in
            writes == 0 ? original.fields : target.fields
        } write: { fields in
            XCTAssertEqual(fields["goformId"], "setDeviceAccessControlList")
            XCTAssertEqual(fields["WhiteMacList"], original.fields["WhiteMacList"])
            XCTAssertEqual(fields["BlackMacList"], "")
            writes += 1
            return ["result": "success"]
        }
        try await client().setClientBlocked(
            mac: "AA:BB:CC:DD:EE:FF", name: "blocked", blocked: false,
            replacing: original, password: "factory-test")
        XCTAssertEqual(writes, 1)
    }

    func testACLRefusesToBlockManagementClient() async throws {
        let original = try UFIClientAccess(JSONObject(accessObject()))
        var writes = 0
        fixture { command in
            if command == "queryDeviceAccessControlList" { return original.fields }
            if command == "baseDeviceInfo" { return ["client_ip": "192.168.0.2"] }
            return [
                "station_list": [["hostname": "phone", "ip_addr": "192.168.0.2", "mac_addr": "AA:BB:CC:11:22:33"]],
                "lan_station_list": [],
            ]
        } write: { _ in
            writes += 1
            return ["result": "success"]
        }
        do {
            try await client().setClientBlocked(
                mac: "AA:BB:CC:11:22:33", name: "phone", blocked: true,
                replacing: original, password: "factory-test")
            XCTFail("Management client must remain connected")
        } catch { XCTAssertTrue(error is ManagementError) }
        XCTAssertEqual(writes, 0)
    }

    private func client() throws -> UFIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ControlProtocol.self]
        return UFIClient(
            baseURL: URL(string: "http://ufi.fixture:2333")!, password: "test-password",
            expectedFingerprint: try UFIClient.snapshot(from: identity).identityFingerprint, configuration: configuration)
    }

    private func fixture(query: @escaping (String) throws -> [String: Any], write: @escaping ([String: String]) throws -> [String: Any]) {
        ControlProtocol.handler = { request in
            if request.url?.path == "/api/user_shell" { return (["result": ["done": true, "content": self.identity]], [:]) }
            if request.url?.path == "/api/baseDeviceInfo" { return (try query("baseDeviceInfo"), [:]) }
            if request.url?.path == "/api/getSupportNrBandList" {
                return (try query("supportedNR"), [:])
            }
            if request.httpMethod == "GET" {
                let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertEqual(items.last?.name, "_")
                let command = items.first { $0.name == "cmd" }!.value!
                switch command {
                case "LD": return (["LD": "challenge"], [:])
                case "loginfo": return (["loginfo": "ok"], [:])
                case "wa_inner_version,cr_version": return (["wa_inner_version": "inner", "cr_version": "outer"], [:])
                case "RD": return (["RD": "fresh"], [:])
                default: return (try query(command), [:])
                }
            }
            let body = Self.body(request)
            let items = URLComponents(string: "http://fixture/?" + String(decoding: body, as: UTF8.self))!.queryItems!
            let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            if fields["goformId"] == "LOGIN" { return (["result": "0"], ["kano-cookie": "stok=test; Path=/"]) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Kano-Cookie"), "stok=test")
            XCTAssertEqual(fields["AD"], UFIClient.factoryDigest(UFIClient.factoryDigest("innerouter") + "fresh"))
            return (try write(fields), [:])
        }
    }

    private static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 2048)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

private final class ControlProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> ([String: Any], [String: String]))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        do {
            let (object, headers) = try Self.handler!(request)
            client?.urlProtocol(
                self,
                didReceive: HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: object))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

extension UFIControlTests {
    private func radioObject(lte: String = "", nr: String = "", cells: [[String: Any]] = []) -> [String: Any] {
        ["lte_band_lock": lte, "nr_band_lock": nr, "locked_cell_info": cells]
    }

    func testRadioChangesOnlySelectedTechnologyAndChecksReadback() async throws {
        var wrote = 0
        let original = try UFIRadioState(JSONObject(radioObject(nr: "78")), supportedNR: [1, 78])
        fixture { command in
            command == "supportedNR" ? ["band_list": [1, 78]] : self.radioObject(lte: wrote == 0 ? "" : "1,3", nr: "78")
        } write: { fields in
            XCTAssertEqual(fields["goformId"], "LTE_BAND_LOCK")
            XCTAssertEqual(fields["lte_band_lock"], "1,3")
            XCTAssertNil(fields["nr_band_lock"])
            wrote += 1
            return ["result": "success"]
        }
        try await client().setRadioBands([3, 1], technology: .lte, replacing: original, password: "fixture")
        XCTAssertEqual(wrote, 1)
    }

    func testRadioRejectsConcurrentChangesBeforePost() async throws {
        let original = try UFIRadioState(JSONObject(radioObject()), supportedNR: [78])
        fixture { command in
            command == "supportedNR" ? ["band_list": [78]] : self.radioObject(lte: "3")
        } write: { _ in
            XCTFail("Concurrent change must stop the write")
            return ["result": "success"]
        }
        do {
            try await client().setRadioBands([1], technology: .lte, replacing: original, password: "fixture")
            XCTFail("Unexpected successful write")
        } catch {}
    }

    func testRadioMissingSupportStillAllowsAutomaticRecovery() async throws {
        var wrote = false
        let original = try UFIRadioState(JSONObject(radioObject(nr: "78")), supportedNR: nil)
        fixture { command in
            command == "supportedNR" ? [:] : self.radioObject(nr: wrote ? "" : "78")
        } write: { fields in
            XCTAssertEqual(fields["goformId"], "NR_BAND_LOCK")
            XCTAssertEqual(fields["nr_band_lock"], "")
            wrote = true
            return ["result": "success"]
        }
        try await client().setRadioBands([], technology: .nr, replacing: original, password: "fixture")
        XCTAssertTrue(wrote)
    }

    func testRadioDoesNotResubmitAfterAcceptedButUnchangedState() async throws {
        var writes = 0
        let original = try UFIRadioState(JSONObject(radioObject()), supportedNR: [78])
        fixture { command in
            command == "supportedNR" ? ["band_list": [78]] : self.radioObject()
        } write: { _ in
            writes += 1
            return ["result": "success"]
        }
        do {
            try await client().setRadioBands([78], technology: .nr, replacing: original, password: "fixture")
            XCTFail("Accepted POST is not confirmed success")
        } catch {}
        XCTAssertEqual(writes, 1)
    }

    func testCellLockAndUnlockUseDedicatedProtocolAndReadback() async throws {
        var cells: [[String: Any]] = []
        var writes = 0
        fixture { command in
            command == "supportedNR" ? ["band_list": [78]] : self.radioObject(cells: cells)
        } write: { fields in
            writes += 1
            if writes == 1 {
                XCTAssertEqual(fields["goformId"], "CELL_LOCK")
                XCTAssertEqual(fields["rat"], "16")
                cells = [["rat": "16", "pci": "507", "earfcn": "426030"]]
            } else {
                XCTAssertEqual(fields["goformId"], "UNLOCK_ALL_CELL")
                cells = []
            }
            return ["result": "success"]
        }
        let client = try client()
        let original = try await client.radioState(password: "fixture")
        try await client.setRadioCell(UFILockedCell(technology: .nr, pci: 507, frequency: 426030),
                                      replacing: original, password: "fixture")
        let locked = try await client.radioState(password: "fixture")
        try await client.setRadioCell(nil, replacing: locked, password: "fixture")
        XCTAssertEqual(writes, 2)
    }
}
