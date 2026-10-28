import XCTest

@testable import FlowDeck

/// 使用脱敏的协议样例覆盖字段缺失、重复记录、编码及资源数值边界。
final class UFIDeviceModelsTests: XCTestCase {
    func testClientInterfacesAndDuplicates() throws {
        let row: [String: Any] = ["mac_addr": "aa:bb:cc:dd:ee:ff", "hostname": "", "ip_addr": "192.168.0.2"]
        let result = try UFIDeviceParser.clients(JSONObject(["station_list": [row], "lan_station_list": [row]]))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].interface, "Wi-Fi")
        XCTAssertEqual(result[0].hostname, "未命名设备")
        XCTAssertNil(result[0].signal)
        let wired = try UFIDeviceParser.clients(JSONObject(["station_list": [], "lan_station_list": [row]]))
        XCTAssertEqual(wired[0].interface, "USB / 有线")
    }

    func testMissingClientResponseIsNotAnEmptyList() throws {
        XCTAssertThrowsError(try UFIDeviceParser.clients(JSONObject(["station_list": []])))
        XCTAssertEqual(try UFIDeviceParser.clients(JSONObject(["station_list": [], "lan_station_list": []])).count, 0)
        XCTAssertThrowsError(
            try UFIDeviceParser.clients(
                JSONObject([
                    "station_list": [["mac_addr": "invalid"]], "lan_station_list": [],
                ])))
    }

    func testMessageDecodesUTF8AndPreservesReadState() throws {
        let content = "中文 + emoji 📩"
        let rows: [[String: Any]] = [
            [
                "id": "42", "number": "10000", "tag": "1",
                "date": "26,10,07,08,30,00,+32", "content": Data(content.utf8).base64EncodedString(),
            ]
        ]
        let message = try XCTUnwrap(UFIDeviceParser.messages(JSONObject(["messages": rows])).first)
        XCTAssertEqual(message.content, content)
        XCTAssertTrue(message.unread)
        XCTAssertEqual(message.date, "2026-10-07 08:30:00")
        XCTAssertThrowsError(try UFIDeviceParser.messages(JSONObject(["messages": rows + rows])))
    }

    func testMalformedSMSCannotBecomeEmptyInboxOrGarbledContent() throws {
        XCTAssertThrowsError(try UFIDeviceParser.messages(JSONObject()))
        XCTAssertEqual(try UFIDeviceParser.messages(JSONObject(["messages": []])).count, 0)
        XCTAssertThrowsError(
            try UFIDeviceParser.messages(
                JSONObject([
                    "messages": [
                        [
                            "id": 42, "number": "10000", "tag": "1", "content": "%%%",
                        ]
                    ]
                ])))
    }

    func testMessageStorageDoesNotInventZerosOrHideListMismatch() throws {
        let counts: [String: Any] = [
            "sms_nv_rev_total": 3, "sms_nv_send_total": "2", "sms_nv_draftbox_total": "1",
            "sms_sim_rev_total": "0", "sms_sim_send_total": 0, "sms_sim_draftbox_total": 0,
        ]
        let storage = try UFISMSStorage(JSONObject(counts))
        XCTAssertEqual(storage.received, 3)
        XCTAssertNotNil(storage.listWarning(loadedCount: 0))
        XCTAssertNil(storage.listWarning(loadedCount: 6))
        var missing = counts
        missing.removeValue(forKey: "sms_nv_send_total")
        XCTAssertThrowsError(try UFISMSStorage(JSONObject(missing)))
        var sim = counts
        sim["sms_sim_rev_total"] = 2
        XCTAssertTrue(try UFISMSStorage(JSONObject(sim)).listWarning(loadedCount: 6)?.contains("SIM") == true)
    }

    func testHardwareRejectsUnknownSentinelsAndInvalidNumbers() {
        let value = UFIHardwareDetails(
            system: JSONObject([
                "cpu_temp": -999, "cpu_usage": 101, "mem_usage": "25.5",
                "daily_data": -1, "monthly_data": "123456789", "internal_available_storage": "broken",
            ]), usb: JSONObject(["maxSpeed": 0]))
        XCTAssertNil(value.cpuTemperature)
        XCTAssertNil(value.cpuUsage)
        XCTAssertEqual(value.memoryUsage, 25.5)
        XCTAssertNil(value.dailyBytes)
        XCTAssertEqual(value.monthlyBytes, 123_456_789)
        XCTAssertNil(value.availableStorage)
        XCTAssertNil(value.usbSpeedMbps)
    }

    func testFactoryActionsAreRestrictedAndValidateIDs() throws {
        XCTAssertThrowsError(try UFIFactoryAction.markMessageRead(-1).form())
        XCTAssertEqual(try UFIFactoryAction.reboot.form()["goformId"], "REBOOT_DEVICE")
        XCTAssertEqual(try UFIFactoryAction.markMessageRead(2).form()["msg_id"], "2;")
    }
}
