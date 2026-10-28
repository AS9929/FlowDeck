import ActivityKit
import Foundation
import Observation

/// 长操作的唯一前台状态。关闭 Sheet 不会伪装成取消设备操作；超时后允许重新检查。
@MainActor
@Observable
final class ManagementStore {
    private(set) var working = false
    private(set) var operationID = UUID()
    private(set) var operationTitle = ""
    private(set) var completedAt: Date?
    private(set) var recentOperations: [OperationRecord] = []

    /// 只记录动作名称与结果，不持久化可能含凭据的服务端响应。
    struct OperationRecord: Identifiable {
        let id: UUID
        let title: String
        let date: Date
        let succeeded: Bool
    }
    private(set) var stage = ""
    private(set) var progress = 0.0
    private(set) var error: String?
    private(set) var report: DiagnosticReport?
    private(set) var exportURL: URL?
    private(set) var backupURL: URL?
    private(set) var backupChecksum: String?
    private(set) var versions: CoreUpdateInfo?
    private(set) var webVersion = "尚未检查"
    private(set) var recoveryPending = UserDefaults.standard.bool(forKey: "recovery.pending")
    private var activity: Activity<U60RecoveryAttributes>?

    /// 切换设备后，旧报告与导出入口不能误显示为新设备的结果。
    func clearDeviceResults() {
        guard !working else { return }
        stage = ""
        error = nil
        recentOperations = []
        completedAt = nil
        report = nil
        exportURL = nil
        backupURL = nil
        backupChecksum = nil
        versions = nil
        webVersion = "尚未检查"
    }

    /// 同一维护流程内所有步骤串行；发生错误保留阶段，方便重试定位。
    func run(_ title: String, operation: () async throws -> Void) async {
        guard !working else {
            return
        }
        let lease: UUID
        do { lease = try DeviceOperationGate.begin(title) } catch {
            self.error = error.localizedDescription
            return
        }
        defer { DeviceOperationGate.end(lease) }
        working = true
        operationID = UUID()
        operationTitle = title
        completedAt = nil
        error = nil
        stage = title
        progress = 0
        defer {
            working = false
            completedAt = Date()
            recentOperations.insert(.init(id: operationID, title: title, date: Date(), succeeded: error == nil), at: 0)
            recentOperations = Array(recentOperations.prefix(20))
        }
        do {
            try await DeviceOperationGate.$owner.withValue(lease) { try await operation() }
            if stage == title {
                stage = title + "完成"
            }
            progress = 1
        } catch is CancellationError {
            error = "检查已停止。设备可能仍在执行，请重新检查状态。"
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// 代理服务启停的完整流程：核验身份、执行、回读、验证出口；首页开关与服务页共用。
    func controlProxyService(_ action: ProxyAction, status: DeviceStatusStore, devices: DeviceStore, disableAutostart: Bool = false) async {
        await run(action.title) {
            let api = try await verifiedAPI(devices, capability: .proxyService)
            let oldAutostart = try await api.mihomoStatus().autostart
            if action == .stop && disableAutostart {
                try await api.setAutostart(false)
            }
            await status.control(action)
            let actual = try await api.mihomoStatus()
            let expectedRunning = action != .stop
            guard actual.running == expectedRunning else {
                if disableAutostart {
                    try await api.setAutostart(oldAutostart)
                }
                throw ManagementError.unconfirmed("服务状态未符合预期；已尝试恢复原自启设置。")
            }
            if action == .stop && disableAutostart && actual.autostart {
                throw ManagementError.unconfirmed("代理已停止，但开机自启尚未关闭。")
            }
            if expectedRunning {
                if devices.usesUFI {
                    guard actual.apiReachable else {
                        throw ManagementError.unconfirmed("核心已运行，但 Mihomo 控制接口尚未就绪，请重新读取状态。")
                    }
                } else if try await !api.connectivity() {
                    throw ManagementError.unconfirmed("核心运行中，但出口检测未通过。")
                }
            }
            let message =
                devices.usesUFI && expectedRunning
                ? "核心与控制接口已确认，热点出口请用客户端验证"
                : "服务状态已回读确认"
            await setStage(message, progress: 1)
        }
    }

    func setStage(_ text: String, progress: Double) async {
        stage = text
        self.progress = progress
        if let activity {
            await activity.update(ActivityContent(state: .init(stage: text, progress: progress), staleDate: Date().addingTimeInterval(20)))
        }
    }

    /// 每次写入前重新确认身份。旧配置无指纹时要求配对，不把同一 IP 当成同一设备。
    func verifiedAPI(_ devices: DeviceStore, capability: ManagementCapability = .system) async throws -> any WebSSHAPI {
        guard !devices.readOnly else {
            throw ManagementError.invalid("当前为只读模式，请在右上角 App 设置中关闭只读后再操作。")
        }
        try devices.requireAccess(.webSSH)
        let session = devices.session()
        let api = session.management
        let snapshot = try await api.snapshot()
        try session.validate(in: devices)
        if !session.demo {
            guard let profile = session.profile, let expected = profile.fingerprint, !expected.isEmpty else {
                throw ManagementError.invalid("设备尚未验证身份，请打开连接与凭据重新验证。")
            }
            guard snapshot.identityFingerprint == expected else { throw ManagementError.deviceChanged }
            guard let descriptor = BackendRegistry.descriptor(for: profile.backend) else {
                throw ManagementError.unsupported("当前版本不支持此管理方式。")
            }
            try await descriptor.verifyWrite(api, snapshot, capability)
            try session.validate(in: devices)
        }
        return api
    }

    /// 校时沿用身份核验、只读保护和维护互斥；只替换当前设备报告的时间项。
    func synchronizeClock(_ devices: DeviceStore) async {
        await run("同步手机时间") {
            let revision = devices.clientRevision
            let api = try await verifiedAPI(devices, capability: devices.usesUFI ? .clock : .system)
            let check: DiagnosticCheck
            if let ufi = api as? any UFIDiagnosticsService {
                check = try await ufi.synchronizeClock()
            } else {
                check = try await NetworkDiagnostics.synchronizeClock(api: api)
            }
            guard revision == devices.clientRevision else { throw ManagementError.deviceChanged }
            var checks = report?.checks.filter { $0.id != "clock" } ?? []
            checks.append(check)
            let updated = DiagnosticReport(date: Date(), demo: devices.demoMode, checks: checks)
            report = updated
            exportURL = try updated.export()
            stage = devices.demoMode ? "演示：设备时间已同步" : "设备时间已同步并回读确认"
        }
    }

    func diagnose(_ devices: DeviceStore) async {
        await run("检测管理通道") {
            try devices.requireAccess(.device)
            let context = try DeviceServiceContext(devices, revision: devices.clientRevision)
            let service = DeviceDiagnosticsService(context: context) { text, value in
                await self.setStage(text, progress: value)
            }
            let result = try await service.run()
            report = result
            exportURL = try result.export()
            stage = "诊断完成"
        }
    }

    func reboot(_ devices: DeviceStore, sendCommand: Bool = true) async {
        await run(sendCommand ? "准备重启" : "检查恢复状态") {
            if sendCommand { _ = try await verifiedAPI(devices) }
            let context = try DeviceServiceContext(devices, revision: devices.clientRevision)
            let service = WebSSHRecoveryService(
                context: context, storageID: devices.storageID, defaults: .standard,
                pending: { self.recoveryPending = $0 },
                progress: { text, value in await self.setStage(text, progress: value) }
            )
            try await service.prepare(sendCommand: sendCommand)
            for old in Activity<U60RecoveryAttributes>.activities {
                await old.end(nil, dismissalPolicy: .immediate)
            }
            if ActivityAuthorizationInfo().areActivitiesEnabled {
                activity = try? Activity.request(
                    attributes: U60RecoveryAttributes(name: devices.current?.name ?? "U60"),
                    content: ActivityContent(state: .init(stage: "等待设备重启", progress: 0.15), staleDate: Date().addingTimeInterval(20)), pushType: nil)
            }
            let restored: Bool
            do {
                restored = try await service.waitForRecovery()
            } catch {
                if let activity {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
                self.activity = nil
                throw error
            }
            if let activity {
                await activity.end(
                    ActivityContent(state: .init(stage: restored ? "设备已恢复" : "等待重新检查", progress: restored ? 1 : progress), staleDate: nil),
                    dismissalPolicy: .default)
                self.activity = nil
            }
            guard restored else {
                throw ManagementError.unconfirmed("暂未确认恢复。连接 U60 Wi-Fi 后点“重新检查”，不会再次发送重启命令。")
            }
            recoveryPending = false
            UserDefaults.standard.set(false, forKey: "recovery.pending")
            stage = "设备、蜂窝与代理恢复已验证"
        }
    }

    /// 仅结束本机恢复跟踪，不声称设备恢复成功，也不发送任何设备命令。
    func stopRecoveryTracking() {
        guard !working else { return }
        recoveryPending = false
        UserDefaults.standard.set(false, forKey: "recovery.pending")
        stage = "已结束本机跟踪，设备实际状态请另行检查"
    }

    func backup(_ devices: DeviceStore) async {
        await run("生成原厂设置备份") {
            let api = try await verifiedAPI(devices)
            let context = try DeviceServiceContext(devices, revision: devices.clientRevision)
            backupURL = nil
            backupChecksum = nil
            let result = try await FactoryBackupService(
                api: api, profile: context.session.profile,
                password: context.session.profile.map { devices.factoryPassword(for: $0) } ?? "",
                demo: context.session.demo
            ).run()
            try context.validate()
            backupURL = result.url
            backupChecksum = result.checksum
            stage = context.session.demo ? "已生成明确标记的演示文件" : "备份已生成，设备与下载文件的 SHA256 一致"
        }
    }

    /// 两种组件分别查询，页面不会因另一项服务失败而显示不相关的检查结果。
    func checkUpdates(_ devices: DeviceStore) async {
        await run("检查 Mihomo 核心版本") {
            let revision = devices.clientRevision
            let core = try await devices.webClient.coreVersion()
            guard revision == devices.clientRevision else { throw ManagementError.deviceChanged }
            versions = core
            stage = "Mihomo 核心版本已检查"
        }
    }

    func checkWebSSHVersion(_ devices: DeviceStore) async {
        await run("检查 WebSSH 版本") {
            let revision = devices.clientRevision
            webVersion = "尚未检查"
            let data = try await devices.webClient.management("GET", "api/update/version", body: nil).object("data")
            guard revision == devices.clientRevision else { throw ManagementError.deviceChanged }
            guard let current = data?.string("current_version"), !current.isEmpty,
                let latest = data?.string("latest_version"), !latest.isEmpty
            else {
                throw ManagementError.invalid("管理服务未返回完整版本信息，请稍后重试。")
            }
            webVersion = "已安装：\(current)\n可用版本：\(latest)"
            stage = current == latest ? "WebSSH 当前已是最新版本" : "WebSSH 发现可用更新"
        }
    }

    func updateCore(_ devices: DeviceStore, rollback: Bool = false) async {
        await run(rollback ? "回滚核心" : "备份并更新核心") {
            let api = try await verifiedAPI(devices)
            let context = try DeviceServiceContext(devices, revision: devices.clientRevision)
            let service = WebSSHMaintenanceService(api: api, demo: context.session.demo) { text, value in
                await self.setStage(text, progress: value)
            }
            let result = try await service.updateCore(rollback: rollback)
            try context.validate()
            versions = result
            stage = rollback ? "核心已回滚并回读确认" : "核心已更新并验证，保留原启停状态"
        }
    }

    func manageWebSSH(_ devices: DeviceStore, update: Bool) async {
        await run(update ? "更新管理服务" : "重启管理服务") {
            let api = try await verifiedAPI(devices)
            let context = try DeviceServiceContext(devices, revision: devices.clientRevision)
            let service = WebSSHMaintenanceService(api: api, demo: context.session.demo) { text, value in
                await self.setStage(text, progress: value)
            }
            let result = try await service.manageWebSSH(update: update)
            try context.validate()
            webVersion = result.version
            stage = result.alreadyCurrent ? "管理服务已是最新版本" : "管理服务已恢复，版本与设备状态读取通过"
        }
    }

    /// 保留测试与已有调用入口，实际脚本由 WebSSH 维护服务拥有。
    static let webSSHRestartScript = WebSSHMaintenanceService.webSSHRestartScript
}
