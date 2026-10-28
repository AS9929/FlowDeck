import XCTest

@testable import FlowDeck

/// 扩展工具契约只连接内存替身，覆盖未知能力、回读失败与凭据校验。
final class DeviceToolsTests: XCTestCase {
    func testUnknownWirelessStateDoesNotBecomeSavingDisabled() async throws {
        let api = DeviceToolsStub(mode: "unknown")
        let state = try await api.wifiPowerState()
        XCTAssertTrue(state.interfaces.isEmpty)
        do {
            _ = try await api.setWiFiPowerSaving(false, interfaces: [])
            XCTFail("未知接口不应写入")
        } catch {}
        let count = await api.writeCount
        XCTAssertEqual(count, 0)
    }

    func testWirelessReadbackMismatchIsNotSuccess() async throws {
        let api = DeviceToolsStub(mode: "on")
        do {
            _ = try await api.setWiFiPowerSaving(false, interfaces: ["wlan0"])
            XCTFail("回读不一致必须报错")
        } catch {}
        let count = await api.writeCount
        XCTAssertEqual(count, 1)
    }

    func testForwardSettingsPreserveServerCursorAndValidateEnabledChannels() throws {
        var settings = SMSForwardSettings(JSONObject(["last_id": 123]))
        XCTAssertEqual(try settings.payload().int("last_id"), 0, "让服务保留最新游标，不能写回打开页面时的旧游标")
        settings.barkEnabled = true
        settings.barkURL = "http://example.com/token"
        XCTAssertThrowsError(try settings.payload())
        settings.barkURL = "https://example.com/token"
        XCTAssertNoThrow(try settings.payload())
        settings.telegramEnabled = true
        XCTAssertThrowsError(try settings.payload())
    }

    func testCommandPreservesExitCodeAndBoundsOutput() async throws {
        let api = DeviceToolsStub(mode: "on")
        let result = try await api.executeUserCommand("test-command")
        XCTAssertEqual(result.code, 17)
        XCTAssertTrue(result.output.contains("已截断"))
        XCTAssertLessThan(result.output.utf8.count, 66000)
    }

    func testDemoWirelessAndForwardingReadback() async throws {
        let api = DemoWebSSH()
        let state = try await api.setWiFiPowerSaving(false, interfaces: ["wlan0", "wlan1"])
        XCTAssertEqual(state.summary, "性能优先")
        var settings = SMSForwardSettings()
        settings.barkGroup = "test-only"
        let result = try await api.saveSMSForwardSettings(settings)
        XCTAssertEqual(result.object("config")?.string("bark_group"), "test-only")
        XCTAssertEqual(result.bool("running"), false, "保存配置不应启动转发")
    }
}

private actor DeviceToolsStub: WebSSHAPI {
    let mode: String
    private(set) var writeCount = 0
    init(mode: String) { self.mode = mode }

    func management(_ method: String, _ path: String, body: JSONObject?) async throws -> JSONObject {
        if path == "api/wifi/psm/set" {
            writeCount += 1
            return JSONObject(["code": 0])
        }
        return JSONObject(["data": ["wlan0_psm": mode]])
    }

    func rpc(_ service: String, _ method: String, params: JSONObject) async throws -> JSONObject {
        JSONObject(["code": 17, "stdout": String(repeating: "x", count: 70000), "stderr": "failed"])
    }
    // 与本测试无关的接口使用既有演示客户端，避免伪造生产返回值。
    private let base = DemoWebSSH()
    func mihomoStatus() async throws -> MihomoServiceStatus { try await base.mihomoStatus() }
    func control(_ action: ProxyAction) async throws -> String { try await base.control(action) }
    func setAutostart(_ enabled: Bool) async throws { try await base.setAutostart(enabled) }
    func connectivity() async throws -> Bool { try await base.connectivity() }
    func loadConfig() async throws -> String { try await base.loadConfig() }
    func saveConfig(_ content: String) async throws { try await base.saveConfig(content) }
    func checkConfig() async throws -> ConfigCheckResult { try await base.checkConfig() }
    func dataVersion() async throws -> DataVersion { try await base.dataVersion() }
    func startDataUpdate() async throws -> DataUpdateStatus { try await base.startDataUpdate() }
    func dataUpdateStatus() async throws -> DataUpdateStatus { try await base.dataUpdateStatus() }
    func snapshot() async throws -> DeviceSnapshot { try await base.snapshot() }
    func clients() async throws -> [LANClient] { try await base.clients() }
    func sms() async throws -> [SMSMessage] { try await base.sms() }
    func markSMSRead(id: Int) async throws { try await base.markSMSRead(id: id) }
    func wifiSettings() async throws -> [String: WifiRadioSettings] { try await base.wifiSettings() }
    func setWifi(_ settings: [String: WifiRadioSettings]) async throws { try await base.setWifi(settings) }
    func setNetworkMode(_ mode: NetworkMode) async throws { try await base.setNetworkMode(mode) }
    func lockLTEBands(_ bands: [Int]) async throws { try await base.lockLTEBands(bands) }
    func lockNRBands(_ bands: [Int]) async throws { try await base.lockNRBands(bands) }
    func reboot() async throws { try await base.reboot() }

}
