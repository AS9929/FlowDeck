import Foundation
import Observation

/// 设备状态与代理服务：数据来自 WebSSH。写入后都会回读一次。
@MainActor
@Observable
final class DeviceStatusStore {
    private(set) var snapshot: DeviceSnapshot?
    private(set) var snapshotError: String?
    private(set) var snapshotAt: Date?
    private(set) var service: MihomoServiceStatus?
    private(set) var serviceError: String?
    private(set) var clients: [LANClient] = []
    private(set) var messages: [SMSMessage] = []
    private(set) var wifi: [String: WifiRadioSettings] = [:]
    private(set) var dataStatus: DataUpdateStatus?
    private(set) var dataVersion: DataVersion?
    /// 正在执行的长操作（启动代理、重启设备等），界面据此显示进度。
    private(set) var busy: String?
    var notice: String? {
        didSet { noticeID = UUID() }
    }
    /// 同文案的连续操作也重新计时，旧任务不能清除新的提示。
    private(set) var noticeID = UUID()

    var historyDeviceID = "demo"
    var authorizeWrite: (() async throws -> Void)?
    var expectedFingerprint: String?
    private var generation = 0
    private let snapshotReads = LatestDeviceRead<DeviceSnapshot>()
    private let serviceReads = LatestDeviceRead<MihomoServiceStatus>()
    private var pollingOwner: UUID?
    private var lastCacheWrite = Date.distantPast
    private var api: any WebSSHAPI

    init(api: any WebSSHAPI, deviceID: String = "demo") {
        self.api = api
        historyDeviceID = deviceID
        restoreCache()
    }

    private func restoreCache() {
        if let cached = DeviceSnapshotCache.load(historyDeviceID) {
            snapshot = cached.snapshot
            snapshotAt = cached.capturedAt
            snapshotError = "显示上次数据，正在重新连接。"
        }
    }

    func use(_ api: any WebSSHAPI, deviceID: String? = nil) {
        self.api = api
        generation += 1
        snapshotReads.invalidate()
        serviceReads.invalidate()
        pollingOwner = nil
        if let deviceID { historyDeviceID = deviceID }
        lastCacheWrite = .distantPast
        snapshotAt = nil
        snapshot = nil
        snapshotError = nil
        service = nil
        serviceError = nil
        clients = []
        messages = []
        wifi = [:]
        dataStatus = nil
        dataVersion = nil
        restoreCache()
    }

    var unreadCount: Int { messages.filter(\.unread).count }

    // MARK: 读取

    func refreshSnapshot() async {
        let revision = generation
        let currentAPI = api
        let fingerprint = expectedFingerprint
        let result = await snapshotReads.read {
            let value = try await currentAPI.snapshot()
            if let fingerprint, value.identityFingerprint != fingerprint {
                throw ManagementError.deviceChanged
            }
            return value
        }
        guard let result, revision == generation, !Task.isCancelled else { return }
        switch result {
        case .success(let value):
            snapshot = value
            snapshotAt = Date()
            snapshotError = nil
            if Date().timeIntervalSince(lastCacheWrite) > 60 {
                try? DeviceSnapshotCache.save(value, deviceID: historyDeviceID)
                lastCacheWrite = Date()
            }
        case .failure(let error):
            snapshotError = error.localizedDescription
        }
    }

    func refreshService() async {
        let revision = generation
        let currentAPI = api
        guard let result = await serviceReads.read({ try await currentAPI.mihomoStatus() }),
            revision == generation, !Task.isCancelled
        else { return }
        switch result {
        case .success(let value):
            service = value
            serviceError = nil
        case .failure(let error):
            service = nil
            serviceError = error.localizedDescription
        }
    }

    func loadClients() async {
        let revision = generation
        do {
            let value = try await api.clients()
            guard revision == generation else { return }
            clients = value
        } catch {
            if revision == generation { notice = error.localizedDescription }
        }
    }

    func loadMessages() async {
        let revision = generation
        do {
            let value = try await api.sms()
            guard revision == generation else { return }
            messages = value
        } catch {
            if revision == generation { notice = error.localizedDescription }
        }
    }

    func loadWifi() async {
        let revision = generation
        do {
            let value = try await api.wifiSettings()
            guard revision == generation else { return }
            wifi = value
        } catch {
            if revision == generation { notice = error.localizedDescription }
        }
    }

    /// 可见且处于前台的页面持有轮询。新订阅取代旧订阅，主动刷新期间跳过重复采样。
    func poll() async {
        let owner = UUID()
        pollingOwner = owner
        defer { if pollingOwner == owner { pollingOwner = nil } }
        var cycle = 0
        while !Task.isCancelled, pollingOwner == owner {
            if cycle % 3 == 0, !serviceReads.isReading { await refreshService() }
            guard !Task.isCancelled, pollingOwner == owner else { return }
            if !snapshotReads.isReading { await refreshSnapshot() }
            cycle += 1
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
        }
    }

    // MARK: 代理服务

    func control(_ action: ProxyAction) async {
        let lease: UUID
        do { lease = try DeviceOperationGate.begin("设备设置") } catch {
            notice = error.localizedDescription
            return
        }
        defer { DeviceOperationGate.end(lease) }

        busy = action == .start ? "正在启动代理，加载中国 IP 段约需 30 秒…" : action == .stop ? "正在停用代理…" : "正在\(action.title)…"
        defer { busy = nil }
        do {
            try await requireWriteAuthorization()
            if action == .start || action == .restart {
                let result = try await api.checkConfig()
                guard result.ok else { throw ManagementError.invalid("配置检查失败，未启动核心。") }
            }
            _ = try await api.control(action)
            await refreshService()
            let ok: Bool
            switch action {
            case .start, .restart: ok = service?.running == true
            case .stop: ok = service?.running == false
            case .reloadIPSet: ok = true
            }
            if ok, action == .start || action == .restart {
                busy = "核心已启动，正在验证代理出口…"
                let connected = try await api.connectivity()
                notice = connected ? "代理已启动，出口验证通过" : "核心已运行，但代理出口检测未通过"
            } else {
                notice = ok ? "\(action.title)完成" : "命令已执行，但回读状态与预期不符"
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    func setAutostart(_ on: Bool) async {
        let lease: UUID
        do { lease = try DeviceOperationGate.begin("设备设置") } catch {
            notice = error.localizedDescription
            return
        }
        defer { DeviceOperationGate.end(lease) }

        do {
            try await requireWriteAuthorization()
            try await api.setAutostart(on)
            await refreshService()
            notice = service?.autostart == on ? (on ? "已开启代理开机自启" : "已关闭代理开机自启") : "自启设置回读不一致"
        } catch {
            notice = error.localizedDescription
        }
    }

    // MARK: 配置

    func deviceConfig() async throws -> String {
        try await api.loadConfig()
    }

    func checkCurrentConfig() async -> ConfigCheckResult? {
        busy = "正在检查配置…"
        defer { busy = nil }
        do { return try await api.checkConfig() } catch {
            notice = error.localizedDescription
            return nil
        }
    }

    enum ImportStep: Equatable {
        case uploading, checking, restarting, done
        case failed(String)
        case rolledBack(String)
    }

    /// 导入新配置：保存当前版本 → 写入 → 检查 → 重启核心。检查不通过时写回旧版本。
    func importConfig(_ content: String, sourceName: String? = nil, expectedChecksum: String? = nil, progress: @escaping (ImportStep) -> Void) async {
        let lease: UUID
        do { lease = try DeviceOperationGate.begin("设备设置") } catch {
            notice = error.localizedDescription
            progress(.failed(error.localizedDescription))
            return
        }
        defer { DeviceOperationGate.end(lease) }

        guard busy == nil else {
            progress(.failed("已有设备操作进行中，请等待完成。"))
            return
        }
        busy = "正在导入配置…"
        defer { busy = nil }
        let operationAPI = api
        let deviceID = historyDeviceID
        var previous: String?
        var wasRunning = false
        var wrote = false
        do {
            try await requireWriteAuthorization()
            let current = try await operationAPI.loadConfig()
            if let expectedChecksum, DeviceIdentity.digest(Data(current.utf8)) != expectedChecksum {
                throw ManagementError.unconfirmed("设备配置在预览后发生了变化，请关闭并重新预览后再应用。")
            }
            previous = current
            wasRunning = try await operationAPI.mihomoStatus().running
            try ConfigHistory.save(current, deviceID: deviceID)
            progress(.uploading)
            // 上传断线时仍可能已写入；从发起写入起即进入可回滚状态。
            wrote = true
            try await operationAPI.saveConfig(content)
            progress(.checking)
            let check = try await operationAPI.checkConfig()
            guard check.ok else { throw ManagementError.invalid("新配置未通过核心校验。") }
            progress(.restarting)
            _ = try await operationAPI.control(.restart)
            if operationAPI is UFIClient {
                // F50 服务启动是异步的，只重试读取；不能因首个瞬时状态就反复重启。
                var ready = false
                for _ in 0..<6 {
                    let service = try await operationAPI.mihomoStatus()
                    if service.running, service.apiReachable {
                        ready = true
                        break
                    }
                    try await Task.sleep(for: .seconds(1))
                }
                guard ready, try await operationAPI.connectivity() else {
                    throw ManagementError.unconfirmed("新配置启动后未通过代理 API 与出口验证。")
                }
            } else {
                let service = try await operationAPI.mihomoStatus()
                guard service.running, service.apiReachable, try await operationAPI.connectivity() else {
                    throw ManagementError.unconfirmed("新配置启动后未通过出口验证。")
                }
            }
            try ConfigHistory.save(content, deviceID: deviceID, sourceName: sourceName)
            await refreshService()
            progress(.done)
        } catch {
            if error is UFIConfigurationNotApplied {
                progress(.failed(error.localizedDescription))
                return
            }
            guard wrote, let previous else {
                progress(.failed(error.localizedDescription))
                return
            }
            do {
                if operationAPI is UFIClient {
                    let actual = try await operationAPI.loadConfig()
                    guard actual == content || actual == previous else {
                        throw ManagementError.unconfirmed("设备出现第三个配置版本，停止自动恢复以免覆盖外部修改。")
                    }
                }
                try await operationAPI.saveConfig(previous)
                guard try await operationAPI.checkConfig().ok else {
                    throw ManagementError.unconfirmed("旧配置校验失败。")
                }
                _ = try await operationAPI.control(wasRunning ? .restart : .stop)
                guard try await operationAPI.mihomoStatus().running == wasRunning else {
                    throw ManagementError.unconfirmed("旧运行状态未恢复。")
                }
                progress(.rolledBack("新配置未通过验证，旧配置与原运行状态已恢复。"))
            } catch {
                progress(.failed("导入失败且恢复未确认。旧版仍在本机配置历史中，请恢复连接后重试。"))
            }
        }
    }

    // MARK: 规则数据

    func loadDataVersion() async {
        do {
            dataVersion = try await api.dataVersion()
            dataStatus = try await api.dataUpdateStatus()
        } catch {
            notice = error.localizedDescription
        }
    }

    func updateData() async {
        let lease: UUID
        do { lease = try DeviceOperationGate.begin("设备设置") } catch {
            notice = error.localizedDescription
            return
        }
        defer { DeviceOperationGate.end(lease) }

        do {
            try await requireWriteAuthorization()
            dataStatus = try await api.startDataUpdate()
            while dataStatus?.isRunning == true, !Task.isCancelled {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                dataStatus = try await api.dataUpdateStatus()
            }
            if dataStatus?.state == "done" {
                notice = "规则数据已更新"
                dataVersion = try? await api.dataVersion()
            } else if let s = dataStatus {
                notice = s.message
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    // MARK: 设备

    func markRead(_ msg: SMSMessage) async {
        let lease: UUID
        do { lease = try DeviceOperationGate.begin("设备设置") } catch {
            notice = error.localizedDescription
            return
        }
        defer { DeviceOperationGate.end(lease) }

        guard msg.unread else { return }
        do {
            try await requireWriteAuthorization()
            try await api.markSMSRead(id: msg.id)
            await loadMessages()
        } catch {
            notice = error.localizedDescription
        }
    }

    func setWifi(_ settings: [String: WifiRadioSettings]) async {
        let lease: UUID
        do { lease = try DeviceOperationGate.begin("设备设置") } catch {
            notice = error.localizedDescription
            return
        }
        defer { DeviceOperationGate.end(lease) }

        do {
            try await requireWriteAuthorization()
            try await api.setWifi(settings)
            await loadWifi()
            notice = wifi == settings ? "Wi-Fi 功率已回读确认" : "功率回读不一致，请重新检查"
        } catch {
            notice = error.localizedDescription
        }
    }

    func setNetworkMode(_ mode: NetworkMode) async {
        let lease: UUID
        do { lease = try DeviceOperationGate.begin("设备设置") } catch {
            notice = error.localizedDescription
            return
        }
        defer { DeviceOperationGate.end(lease) }

        busy = "正在切换网络模式，蜂窝会重新注册…"
        defer { busy = nil }
        do {
            try await requireWriteAuthorization()
            try await api.setNetworkMode(mode)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await refreshSnapshot()
            notice = snapshot?.netSelect == mode.rawValue ? "已切换为\(mode.title)" : "命令已发送，制式回读与目标不符，请重新检查。"
        } catch {
            notice = error.localizedDescription
        }
    }

    /// 传入全部可选频段即为“恢复自动选择”，与 WebSSH 网页的做法一致。
    func lockBands(lte: [Int], nr: [Int]) async {
        let lease: UUID
        do { lease = try DeviceOperationGate.begin("设备设置") } catch {
            notice = error.localizedDescription
            return
        }
        defer { DeviceOperationGate.end(lease) }

        guard busy == nil else { return }
        busy = "正在应用频段设置…"
        defer { busy = nil }
        let operationAPI = api
        do {
            try await requireWriteAuthorization()
            let beforeDevice = try await operationAPI.snapshot()
            let identity = beforeDevice.identityFingerprint
            guard identity != nil else { throw ManagementError.deviceChanged }
            let before = try await operationAPI.read("zte_nwinfo_api", "nwinfo_get_netinfo")
            guard let oldLTE = BandSelection.lte(before.string("lte_band_lock")), !oldLTE.isEmpty else {
                throw ManagementError.unconfirmed("无法读取原锁频值，未执行修改。")
            }
            let oldNR = BandSelection.nr(before.string("nr5g_sa_band_lock"))
            guard before.string("nr5g_sa_band_lock") != nil else {
                throw ManagementError.unconfirmed("无法读取原 5G 频段，未执行修改。")
            }
            do {
                try await operationAPI.lockLTEBands(lte)
                try await operationAPI.lockNRBands(nr)
                try await Task.sleep(nanoseconds: 1_500_000_000)
                let result = try await operationAPI.read("zte_nwinfo_api", "nwinfo_get_netinfo")
                guard BandSelection.lte(result.string("lte_band_lock")) == Set(lte),
                    BandSelection.nr(result.string("nr5g_sa_band_lock")) == Set(nr)
                else {
                    throw ManagementError.unconfirmed("锁频回读不符。")
                }
                if beforeDevice.connected == true {
                    busy = "频段已写入，正在等待蜂窝重新连接…"
                    try await waitForCellular(operationAPI, identity: identity)
                    notice = "频段已确认，蜂窝连接已恢复"
                } else {
                    notice = "频段设置已回读；修改前蜂窝未联网，请检查 SIM 与信号。"
                }
            } catch {
                // 补偿只能发给原设备；换网或身份读取失败时停止，不能向同 IP 的另一台设备写入。
                let current = try await operationAPI.snapshot()
                guard current.identityFingerprint == identity else {
                    throw ManagementError.deviceChanged
                }
                try await operationAPI.lockLTEBands(oldLTE.sorted())
                try await operationAPI.lockNRBands(oldNR.sorted())
                let restored = try await operationAPI.read("zte_nwinfo_api", "nwinfo_get_netinfo")
                guard BandSelection.lte(restored.string("lte_band_lock")) == oldLTE,
                    BandSelection.nr(restored.string("nr5g_sa_band_lock")) == oldNR
                else {
                    throw ManagementError.unconfirmed("频段修改失败，恢复未确认。请检查设备信号并恢复自动选择。")
                }
                if beforeDevice.connected == true {
                    busy = "旧频段已恢复，正在检查蜂窝连接…"
                    do {
                        try await waitForCellular(operationAPI, identity: identity)
                    } catch {
                        throw ManagementError.unconfirmed("旧频段已回读恢复，但蜂窝联网尚未确认，请检查 SIM 与信号。")
                    }
                }
                notice = "新频段未通过验证，已恢复修改前的频段"
            }
            await refreshSnapshot()
        } catch {
            notice = error.localizedDescription
        }
    }

    /// 使用单调时钟限制等待；系统时间校正不会延长恢复窗口。
    private func waitForCellular(_ api: any WebSSHAPI, identity: String?) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .seconds(2))
            let current = try await api.snapshot()
            guard current.identityFingerprint == identity else {
                throw ManagementError.deviceChanged
            }
            if current.connected == true { return }
        }
        throw ManagementError.unconfirmed("蜂窝未在等待窗口内恢复，正在恢复原频段。")
    }

    func reboot() async -> Bool {
        let lease: UUID
        do { lease = try DeviceOperationGate.begin("设备设置") } catch {
            notice = error.localizedDescription
            return false
        }
        defer { DeviceOperationGate.end(lease) }

        do {
            try await requireWriteAuthorization()
            try await api.reboot()
            notice = "重启命令已发送，设备会断网约 2 分钟"
            return true
        } catch {
            notice = error.localizedDescription
            return false
        }
    }
    private func requireWriteAuthorization() async throws {
        guard let authorizeWrite else {
            throw ManagementError.invalid("写入授权尚未准备，请返回页面后重试。")
        }
        try await authorizeWrite()
    }

}
