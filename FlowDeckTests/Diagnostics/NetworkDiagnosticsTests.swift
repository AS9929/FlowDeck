import XCTest

@testable import FlowDeck

/// 使用确定时间与探测输出覆盖真设备反馈，不连接公网或更改设备时间。
final class NetworkDiagnosticsTests: XCTestCase {
    func testDeviceUDPDoesNotTreatOneResolverTimeoutAsTotalFailure() async throws {
        var requests: [String] = []
        let result = try await DeviceUDPDNSDiagnostic.run { server in
            requests.append(server)
            return server == "223.5.5.5" ? "passed" : "timeout"
        }
        XCTAssertEqual(requests, ["223.5.5.5", "1.1.1.1", "1.1.1.1"])
        XCTAssertEqual(result.outcome, .passed)
        XCTAssertTrue(result.detail.contains("1.1.1.1:53 重试后仍超时"))
        XCTAssertTrue(result.detail.contains("不代表手机 UDP"))
    }

    func testDeviceUDPRetriesTransientLossAndBoundsFailure() async throws {
        var attempts: [String: Int] = [:]
        let recovered = try await DeviceUDPDNSDiagnostic.run { server in
            attempts[server, default: 0] += 1
            return attempts[server] == 1 ? "timeout" : "passed"
        }
        XCTAssertEqual(recovered.outcome, .passed)
        XCTAssertEqual(attempts.values.reduce(0, +), 4)
        var requests = 0
        let failed = try await DeviceUDPDNSDiagnostic.run { _ in
            requests += 1
            return "invalid-response"
        }
        XCTAssertEqual(failed.outcome, .failed)
        XCTAssertEqual(requests, 4)
        XCTAssertTrue(failed.detail.contains("不能据此认定全部 UDP"))
    }

    func testDeviceUDPUnavailableAndCancellationAreNotNetworkFailures() async throws {
        var requests = 0
        let unavailable = try await DeviceUDPDNSDiagnostic.run { _ in
            requests += 1
            return nil
        }
        XCTAssertEqual(unavailable.outcome, .unavailable)
        XCTAssertEqual(requests, 2)
        do {
            _ = try await DeviceUDPDNSDiagnostic.run { _ in throw CancellationError() }
            XCTFail("取消应传递给调用方，不能当成网络故障")
        } catch is CancellationError {
        }
    }

    func testClockSyncUsesAbsoluteEpochAndRejectsInvalidDate() throws {
        let script = try NetworkDiagnostics.clockSyncScript(date: Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(script, "date -u -s '@1790000000' >/dev/null && date +%s")
        XCTAssertThrowsError(try NetworkDiagnostics.clockSyncScript(date: Date(timeIntervalSince1970: .infinity)))
        XCTAssertThrowsError(try NetworkDiagnostics.clockSyncScript(date: Date(timeIntervalSince1970: 0)))
    }

    func testClockSyncReadsBackAndDoesNotRetryFailedWrite() async throws {
        let good = ClockSyncStub(mode: .success)
        let result = try await NetworkDiagnostics.synchronizeClock(api: good)
        XCTAssertEqual(result.outcome, .passed)
        let scripts = await good.scripts
        XCTAssertEqual(scripts.count, 2)
        XCTAssertEqual(scripts.last, "date +%s")
        for mode in [ClockSyncStub.Mode.rejected, .lostReply, .skewedReadback, .invalidReadback] {
            let api = ClockSyncStub(mode: mode)
            do {
                _ = try await NetworkDiagnostics.synchronizeClock(api: api)
                XCTFail("写入失败或未确认不能成功")
            } catch {}
            let writes = await api.scripts.filter { $0.contains("date -u -s") }
            XCTAssertEqual(writes.count, 1)
        }
    }

    @MainActor
    func testClockSyncHonorsReadOnlyAndDemoReport() async {
        let devices = DeviceStore(defaults: UserDefaults(suiteName: "test.FlowDeck." + UUID().uuidString)!)
        let oldReadOnly = devices.readOnly
        let oldDemo = devices.demoMode
        defer {
            devices.readOnly = oldReadOnly
            devices.demoMode = oldDemo
        }
        devices.demoMode = true
        devices.readOnly = true
        let store = ManagementStore()
        await store.synchronizeClock(devices)
        XCTAssertNotNil(store.error)
        XCTAssertNil(store.report)
        devices.readOnly = false
        await store.synchronizeClock(devices)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.report?.checks.first?.outcome, .passed)
        XCTAssertEqual(store.report?.demo, true)
    }

    func testDNSUsesDeviceLANAddressAndEscapesArguments() {
        let script = NetworkDiagnostics.dnsProbe(host: "192.168.0.1")
        XCTAssertTrue(script.contains("nslookup www.apple.com '192.168.0.1'"))
        XCTAssertFalse(script.contains("127.0.0.1"))
        XCTAssertTrue(NetworkDiagnostics.dnsProbe(host: "a'b").contains(ShellValue.quote("a'b")))
    }

    func testDNSFailureAndUnavailableAreDifferent() {
        XCTAssertEqual(NetworkDiagnostics.dnsResult("PASSED\n").outcome, .passed)
        XCTAssertEqual(NetworkDiagnostics.dnsResult("FAILED").outcome, .failed)
        XCTAssertEqual(NetworkDiagnostics.dnsResult("UNAVAILABLE").outcome, .unavailable)
        XCTAssertEqual(NetworkDiagnostics.dnsResult("").outcome, .unavailable)
    }

    func testClockUsesRequestMidpointWithoutTimezoneCorrection() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let end = start.addingTimeInterval(2)
        XCTAssertEqual(NetworkDiagnostics.clockResult("1790000001\n", started: start, finished: end).outcome, .passed)
        let skewed = NetworkDiagnostics.clockResult("1790028801", started: start, finished: end)
        XCTAssertEqual(skewed.outcome, .failed)
        XCTAssertTrue(skewed.detail.contains("快约 8 小时"))
        XCTAssertTrue(NetworkDiagnostics.clockResult("1789992801", started: start, finished: end).detail.contains("慢约 2 小时"))
    }

    func testMalformedClockIsUnknownInsteadOfClockFailure() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        for value in ["", "date: not found", "nan", "inf", "0"] {
            XCTAssertEqual(NetworkDiagnostics.clockResult(value, started: now, finished: now).outcome, .unavailable)
        }
    }
}

/// 只记录固定维护命令，覆盖命令失败、应答丢失与时钟回读漂移；不连接真实设备。
private actor ClockSyncStub: WebSSHAPI {
    enum Mode { case success, rejected, lostReply, skewedReadback, invalidReadback }
    let mode: Mode
    private(set) var scripts: [String] = []
    init(mode: Mode) { self.mode = mode }

    func rpc(_ service: String, _ method: String, params: JSONObject) async throws -> JSONObject {
        let script = params.strings("params").last ?? ""
        scripts.append(script)
        if script.contains("date -u -s") {
            if mode == .lostReply { throw URLError(.timedOut) }
            return JSONObject(["code": mode == .rejected ? 1 : 0, "stdout": ""])
        }
        let output = mode == .invalidReadback ? "bad date" : String(Int(Date().timeIntervalSince1970) + (mode == .skewedReadback ? 28800 : 0))
        return JSONObject(["code": 0, "stdout": output])
    }
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
