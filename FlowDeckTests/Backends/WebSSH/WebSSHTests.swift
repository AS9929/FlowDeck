import XCTest

@testable import FlowDeck

final class WebSSHTests: XCTestCase {
    private func obj(_ json: String) -> JSONObject { JSONObject(data: Data(json.utf8))! }

    func testSnapshotParsesStringNumbersAndPrefersNR() {
        let net = obj(
            #"{"network_provider":"CMCC","network_type":"SA","signalbar":"4","nr5g_rsrp":"-94","nr5g_snr":"18","nr5g_rsrq":"-11","nr5g_action_band":"78","nr5g_pci":"412","lte_rsrp":"-100","lte_band":"3","net_select":"WL_AND_5G"}"#
        )
        let traffic = obj(#"{"real_rx_speed":"4404019","real_tx_speed":"600000","day_rx_bytes":"1000","day_tx_bytes":"24","month_rx_bytes":62400000000}"#)
        let device = obj(#"{"bat_percent":"94","bat_charger_connect":"1","device_uptime":"11520","meminfo":{"total":"1919000","avaliable":"1102000"}}"#)
        let mdm = obj(#"{"values":{"imei":"868000001234567"}}"#)
        let wan = obj(#"{"connect_status":"ipv4_ipv6_connected","ipv4_address":"10.0.0.2"}"#)
        let s = DeviceSnapshot(
            netinfo: net, traffic: traffic, device: device, cpuTemp: nil, mdm: mdm, sim: nil,
            common: nil, wlan: nil, users: nil, wan: wan)
        XCTAssertEqual(s.operatorName, "中国移动")
        XCTAssertTrue(s.isNR)
        XCTAssertEqual(s.rsrp, -94)
        XCTAssertEqual(s.bandLabel, "n78")
        XCTAssertEqual(s.signalQuality, "良好")
        XCTAssertEqual(s.rxSpeed, 4_404_019)
        XCTAssertEqual(s.monthRx, 62_400_000_000)
        XCTAssertEqual(s.battery, 94)
        XCTAssertTrue(s.charging)
        XCTAssertEqual(s.memAvailKB, 1_102_000)
        XCTAssertEqual(s.connected, true)
        XCTAssertEqual(NetworkMode(rawValue: s.netSelect ?? ""), .auto)
    }

    func testSnapshotFallsBackToLTE() {
        let net = obj(#"{"network_provider":"CT","network_type":"LTE","lte_rsrp":"-108","lte_band":"3","lte_pci":"77"}"#)
        let s = DeviceSnapshot(
            netinfo: net, traffic: nil, device: nil, cpuTemp: nil, mdm: nil, sim: nil,
            common: nil, wlan: nil, users: nil, wan: obj(#"{"connect_status":"disconnected"}"#))
        XCTAssertFalse(s.isNR)
        XCTAssertEqual(s.bandLabel, "B3")
        XCTAssertEqual(s.operatorName, "中国电信")
        XCTAssertEqual(s.signalQuality, "一般")
        XCTAssertEqual(s.connected, false)
    }

    func testServiceStatusAndMissingFiles() {
        let o = obj(
            #"{"running":true,"pid":2481,"start_time":"2026-10-04 08:31:02","api_reachable":false,"autostart_enabled":true,"files":[{"name":"chnroute.txt","desc":"中国 IPv4 段","exists":true},{"name":"GeoSite.dat","desc":"GeoSite","exists":false}]}"#
        )
        let s = MihomoServiceStatus(o)
        XCTAssertTrue(s.running)
        XCTAssertEqual(s.pid, 2481)
        XCTAssertTrue(s.autostart)
        XCTAssertFalse(s.apiReachable)
        XCTAssertEqual(s.missingFiles, ["GeoSite"])
    }

    func testDataUpdateStatus() {
        let d = DataUpdateStatus(obj(#"{"state":"downloading","msg":"正在下载","file_name":"geoip.metadb","file_index":2,"file_total":4,"percent":37}"#))
        XCTAssertTrue(d.isRunning)
        XCTAssertEqual(d.percent, 37)
        XCTAssertEqual(d.fileName, "geoip.metadb")
    }

    func testMaskingKeepsLastFour() {
        XCTAssertEqual(Masking.tail("868000001234567"), "••••••••4567")
        XCTAssertEqual(Masking.tail(nil), "—")
        XCTAssertEqual(Masking.tail("123"), "123")
    }

    func testDeviceProfileDecodesOldDataWithoutWebFields() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"随身","host":"192.168.0.1","mihomoPort":9090}"#
        let d = try JSONDecoder().decode(DeviceProfile.self, from: Data(old.utf8))
        XCTAssertEqual(d.webPort, 8899)
        XCTAssertEqual(d.webUser, "admin")
        XCTAssertTrue(d.needsVerification, "旧记录可读取状态，但不能误认为身份已验证")
    }

    func testSavedIdentitySurvivesProfileRoundTrip() throws {
        var profile = DeviceProfile(name: "随身")
        XCTAssertTrue(profile.needsVerification)
        profile.fingerprint = ""
        XCTAssertTrue(profile.needsVerification)
        profile.fingerprint = DeviceIdentity.fingerprint(model: "MU5250", imei: "868000001234567")
        let restored = try JSONDecoder().decode(DeviceProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertFalse(restored.needsVerification)
        XCTAssertEqual(restored.id, profile.id, "验证旧设备应保留原来的凭据归属")
    }

    func testDemoImportRollsBackOnFailedCheck() async {
        let demo = DemoWebSSH()
        let store = await DeviceStatusStore(api: demo)
        await MainActor.run { store.authorizeWrite = {} }
        var steps: [DeviceStatusStore.ImportStep] = []
        await store.importConfig("rules:\n  - USER-AGENT,foo,DIRECT\n") { steps.append($0) }
        guard case .rolledBack = steps.last else { return XCTFail("应当回退，实际 \(steps)") }
        let restored = try? await demo.loadConfig()
        XCTAssertFalse(restored?.contains("USER-AGENT") ?? true, "检查失败后应写回旧配置")
    }
}
