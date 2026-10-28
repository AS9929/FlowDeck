import XCTest

@testable import FlowDeck

/// 真实状态机搭配内存服务替身，覆盖下载、摘要、配置及中途竞争，而非跳过逻辑的演示分支。
final class DeploymentPipelineTests: XCTestCase {
    @MainActor
    func testFirstInstallValidatesWithoutStartingAndCheckpointResumes() async throws {
        try await withStore(.success) { store, devices, api in
            await store.installProxy(devices)
            XCTAssertNil(store.error)
            XCTAssertEqual(store.phase, "validated")
            let events = await api.events
            XCTAssertEqual(events.filter { $0 == "install" }.count, 1)
            XCTAssertEqual(events.filter { $0 == "save" }.count, 1)
            XCTAssertFalse(events.contains("start"))
            XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "digest")), try XCTUnwrap(events.firstIndex(of: "save")))
            // 9 个资源的解压校验与安装后的核心复核都走后台任务，避开 WebSSH 单次调用 5 秒上限。
            let launches = await api.jobLaunches
            XCTAssertEqual(launches, 10)
            let resumed = DeploymentStore(api: api)
            resumed.load(devices)
            XCTAssertEqual(resumed.phase, "validated")
            XCTAssertEqual(resumed.profile.fingerprint, store.profile.fingerprint)
        }
    }

    /// B28 时间普遍偏快约 8 小时；安装校验只提示，由配置内 NTP 运行时校正，不要求改系统时间。
    @MainActor
    func testClockSkewDoesNotBlockValidation() async throws {
        try await withStore(.success) { store, devices, api in
            await api.setClockOffset(8 * 3600)
            await store.installProxy(devices)
            XCTAssertNil(store.error)
            XCTAssertEqual(store.phase, "validated")
            XCTAssertTrue(store.message.contains("NTP"))
        }
    }

    func testBackgroundJobWaitsUntilDone() async throws {
        let api = DeploymentPipelineFixture(.success)
        await api.setPollReplies(["FLOWDECK_JOB_PENDING", "FLOWDECK_JOB_PENDING", "FLOWDECK_JOB_DONE 0\nresult-tail"])
        let output = try await api.runBackgroundScript(
            directory: "/tmp/fixture", name: "fixture", title: "测试任务", script: "true", pollInterval: .milliseconds(1))
        XCTAssertEqual(output, "result-tail")
    }

    func testBackgroundJobFailuresAreReported() async {
        for replies in [["FLOWDECK_JOB_DONE 1\nsha256sum: FAILED"], ["FLOWDECK_JOB_PENDING", "FLOWDECK_JOB_LOST"]] {
            let api = DeploymentPipelineFixture(.success)
            await api.setPollReplies(replies)
            do {
                _ = try await api.runBackgroundScript(
                    directory: "/tmp/fixture", name: "fixture", title: "测试任务", script: "true", pollInterval: .milliseconds(1))
                XCTFail("后台任务失败不能被当作成功：\(replies)")
            } catch {}
        }
    }

    func testBackgroundJobTimesOut() async {
        let api = DeploymentPipelineFixture(.success)
        await api.setPollReplies(Array(repeating: "FLOWDECK_JOB_PENDING", count: 100))
        do {
            _ = try await api.runBackgroundScript(
                directory: "/tmp/fixture", name: "fixture", title: "测试任务", script: "true",
                timeout: .milliseconds(20), pollInterval: .milliseconds(5))
            XCTFail("超时必须失败")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("超时"))
        }
    }

    func testJobScriptsQuoteInnerScriptAndDetachOutput() {
        let launch = BackgroundJob.launchScript(directory: "/data/x", name: "verify-mihomo", script: "echo 'a'")
        XCTAssertTrue(launch.contains(#"printf '%s\n' 'echo '\''a'\''' > 'verify-mihomo.sh'"#))
        XCTAssertTrue(launch.contains("</dev/null >/dev/null 2>&1 &"))
        XCTAssertTrue(launch.contains("kill -0"))
        let poll = BackgroundJob.pollScript(directory: "/data/x", name: "verify-mihomo")
        XCTAssertTrue(poll.contains("FLOWDECK_JOB_DONE"))
        XCTAssertTrue(poll.contains("FLOWDECK_JOB_LOST"))
    }

    /// 核心回滚包含大文件摘要和 mm.sh 启停，必须走后台任务而不是单次 5 秒调用。
    func testCoreRollbackRunsAsBackgroundJob() async throws {
        let api = DeploymentPipelineFixture(.success)
        try await api.rollbackCore()
        let launches = await api.jobLaunches
        XCTAssertEqual(launches, 1)
        let scripts = await api.launchedScripts
        XCTAssertTrue(scripts.first?.contains("rollback-core") == true)
        XCTAssertTrue(scripts.first?.contains("mm.sh stop") == true)
    }

    @MainActor
    func testChangedConfigDuringDownloadIsPreserved() async throws {
        try await withStore(.changedConfig) { store, devices, api in
            await store.installProxy(devices)
            XCTAssertTrue(store.error?.contains("配置已变化") == true)
            let config = try await api.loadConfig()
            XCTAssertEqual(config, "other-manager-config")
            let events = await api.events
            XCTAssertFalse(events.contains("save"))
            XCTAssertFalse(events.contains("start"))
        }
    }

    @MainActor
    func testUnrecognizedArtifactNeverExecutesCoreOrSavesConfiguration() async throws {
        try await withStore(.wrongArtifact) { store, devices, api in
            await store.installProxy(devices)
            XCTAssertTrue(store.error?.contains("适配资源不一致") == true)
            let events = await api.events
            XCTAssertFalse(events.contains("version"))
            XCTAssertFalse(events.contains("save"))
            XCTAssertFalse(events.contains("start"))
        }
    }

    @MainActor
    func testFailedStartIsStoppedOnlyAfterRecheckingIdentity() async throws {
        try await withStore(.startFailure) { store, devices, api in
            await store.installProxy(devices)
            await store.activate(devices)
            let events = await api.events
            XCTAssertTrue(events.contains("start"))
            XCTAssertTrue(events.contains("stop"))
            XCTAssertTrue(store.error?.contains("已确认停用") == true)
            XCTAssertNotEqual(store.phase, "complete")
        }
    }

    @MainActor
    func testFailedStartDoesNotSendCompensationToAnotherDevice() async throws {
        try await withStore(.changedDeviceAtFailure) { store, devices, api in
            await store.installProxy(devices)
            await store.activate(devices)
            let events = await api.events
            XCTAssertTrue(events.contains("start"))
            XCTAssertFalse(events.contains("stop"))
            XCTAssertTrue(store.error?.contains("未能确认恢复状态") == true)
            XCTAssertNotEqual(store.phase, "complete")
        }
    }

    /// 只生成无执行能力的文本压缩包，测试传输、恢复与身份竞争，不携带上游二进制。
    private static func syntheticResources() throws -> OfflineDeploymentResources {
        let names = [
            "mihomo", "mm.sh", "GeoSite.dat", "geoip.metadb", "ASN.mmdb",
            "chnroute.txt", "chnroute6.txt", "data_version.txt", "mihomo_version.txt",
        ]
        var files: [OfflineArtifact] = []
        var payloads: [String: Data] = [:]
        for name in names {
            let data = Data("FlowDeck synthetic fixture: \(name)".utf8)
            let compressed = try FactoryBackupArchive.gzip(data, compress: true)
            files.append(
                OfflineArtifact(
                    name: name, resource: "Offline-" + name + ".gz",
                    sha256: DeviceIdentity.digest(data), archiveSHA256: DeviceIdentity.digest(compressed),
                    size: data.count, compressedSize: compressed.count
                ))
            payloads[name] = compressed
        }
        let immutablePayloads = payloads
        return OfflineDeploymentResources(files: files) { artifact in
            try XCTUnwrap(immutablePayloads[artifact.name])
        }
    }

    @MainActor
    private func withStore(
        _ scenario: DeploymentPipelineFixture.Scenario,
        run: (DeploymentStore, DeviceStore, DeploymentPipelineFixture) async throws -> Void
    ) async throws {
        let devices = DeviceStore(defaults: UserDefaults(suiteName: "test.FlowDeck." + UUID().uuidString)!)
        let original = devices.current
        let originalDemo = devices.demoMode
        let originalReadOnly = devices.readOnly
        devices.readOnly = false
        let api = DeploymentPipelineFixture(scenario)
        let resources = try Self.syntheticResources()
        let store = DeploymentStore(api: api, offlineResources: { resources })
        store.simulation = false
        store.source = "proxies: []\nproxy-groups: []\nrules:\n  - MATCH,DIRECT\n"
        defer {
            devices.remove(store.profile)
            if let original { devices.select(original) }
            devices.demoMode = originalDemo
            devices.readOnly = originalReadOnly
            if let directory = try? DeploymentFiles.directory(store.profile.id) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        await store.inspect(devices)
        XCTAssertNil(store.error)
        try await run(store, devices, api)
    }
}

private actor DeploymentPipelineFixture: WebSSHAPI {
    enum Scenario { case success, changedConfig, wrongArtifact, startFailure, changedDeviceAtFailure }
    let scenario: Scenario
    let base = DemoWebSSH()
    var events: [String] = []
    private var binary = false
    private var configuration = ""
    private var lastJobOutput = ""
    private var pollReplies: [String] = []
    private var clockOffset: TimeInterval = 0
    var jobLaunches = 0
    var launchedScripts: [String] = []

    func setPollReplies(_ replies: [String]) { pollReplies = replies }
    func setClockOffset(_ offset: TimeInterval) { clockOffset = offset }

    init(_ scenario: Scenario) { self.scenario = scenario }

    func rpc(_ service: String, _ method: String, params: JSONObject) async throws -> JSONObject {
        guard service == "file", method == "exec", let script = params.strings("params").last else {
            throw ManagementError.unsupported("Unexpected fixture request")
        }
        let output: String
        if script.contains("FLOWDECK_JOB_PENDING") {
            // 轮询：默认后台任务在第一次查询时即已完成；测试可预置逐次应答。
            output = pollReplies.isEmpty ? "FLOWDECK_JOB_DONE 0\n" + lastJobOutput : pollReplies.removeFirst()
        } else if script.contains("FLOWDECK_JOB_STARTED") {
            jobLaunches += 1
            launchedScripts.append(script)
            if script.contains("FLOWDECK_ARTIFACTS_VERIFIED") {
                events.append("digest")
                lastJobOutput = scenario == .wrongArtifact ? "" : "FLOWDECK_ARTIFACTS_VERIFIED"
            } else {
                lastJobOutput = ""
            }
            output = "FLOWDECK_JOB_STARTED"
        } else if script.contains("FLOWDECK_ARTIFACTS_VERIFIED") {
            events.append("digest")
            output = scenario == .wrongArtifact ? "" : "FLOWDECK_ARTIFACTS_VERIFIED"
        } else if script.contains("wc -c") && !script.contains("base64 -d") {
            output = "0"
        } else if script.contains(".ready") && script.contains("chmod 700") {
            events.append("install")
            binary = true
            if scenario == .changedConfig { configuration = "other-manager-config" }
            output = ""
        } else if script == "date +%s" {
            output = String(Int(Date().timeIntervalSince1970 + clockOffset))
        } else if script.contains("FLOWDECK_SCRIPT_READY") {
            output = binary ? "FLOWDECK_SCRIPT_READY" : ""
        } else if script.contains("FLOWDECK_READY") {
            output = "FLOWDECK_READY"
        } else {
            output = ""
        }
        return JSONObject(["code": 0, "stdout": output])
    }

    func management(_ method: String, _ path: String, body: JSONObject?) async throws -> JSONObject {
        if path == "api/mihomo/dir" { return JSONObject(["data": ["mihomo_dir": "/data/kano_plugins/mihomo"]]) }
        if method == "POST", path == "api/mihomo/install" {
            events.append("install")
            binary = true
        }
        return JSONObject(["data": ["state": binary ? "done" : "idle", "percent": binary ? 100 : 0]])
    }

    func mihomoStatus() async throws -> MihomoServiceStatus {
        if binary { events.append("version") }
        return MihomoServiceStatus(running: false, pid: nil, startTime: nil, binaryVersion: binary ? "fixture" : nil, apiReachable: false, autostart: false)
    }
    func loadConfig() async throws -> String { configuration }
    func saveConfig(_ content: String) async throws {
        events.append("save")
        configuration = content
    }
    func checkConfig() async throws -> ConfigCheckResult { .init(ok: true, message: "valid", output: "valid") }
    func startDataUpdate() async throws -> DataUpdateStatus {
        if scenario == .changedConfig { configuration = "other-manager-config" }
        return .init(JSONObject(["state": "done"]))
    }
    func dataUpdateStatus() async throws -> DataUpdateStatus { .init(JSONObject(["state": "idle"])) }
    func control(_ action: ProxyAction) async throws -> String {
        events.append(action.rawValue)
        if action == .start, scenario == .startFailure || scenario == .changedDeviceAtFailure {
            throw URLError(.networkConnectionLost)
        }
        return "fixture"
    }
    func setAutostart(_ enabled: Bool) async throws { events.append("autostart") }
    func connectivity() async throws -> Bool { false }
    func snapshot() async throws -> DeviceSnapshot {
        var snapshot = try await base.snapshot()
        if scenario == .changedDeviceAtFailure, events.contains("start") {
            snapshot.imei = "868000001234568"
        }
        return snapshot
    }
    func dataVersion() async throws -> DataVersion { try await base.dataVersion() }
    func clients() async throws -> [LANClient] { try await base.clients() }
    func sms() async throws -> [SMSMessage] { try await base.sms() }
    func markSMSRead(id: Int) async throws { throw ManagementError.unsupported("fixture") }
    func wifiSettings() async throws -> [String: WifiRadioSettings] { try await base.wifiSettings() }
    func setWifi(_ settings: [String: WifiRadioSettings]) async throws { throw ManagementError.unsupported("fixture") }
    func setNetworkMode(_ mode: NetworkMode) async throws { throw ManagementError.unsupported("fixture") }
    func lockLTEBands(_ bands: [Int]) async throws { throw ManagementError.unsupported("fixture") }
    func lockNRBands(_ bands: [Int]) async throws { throw ManagementError.unsupported("fixture") }
    func reboot() async throws { throw ManagementError.unsupported("fixture") }
}
