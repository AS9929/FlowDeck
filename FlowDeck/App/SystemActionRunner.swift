import ActivityKit
import Foundation
import WidgetKit

/// 小组件、控制中心共用操作。每次重新读取当前设备及身份，不依据小组件旧快照执行切换。
@MainActor
enum SystemActionRunner {
    private static var running = false

    static func perform(_ action: U60DirectAction) async throws {
        guard !running else {
            throw ManagementError.invalid("上一项操作尚未完成。")
        }
        let lease = try DeviceOperationGate.begin("系统快捷操作")
        defer { DeviceOperationGate.end(lease) }
        running = true
        defer {
            running = false
        }
        let devices = DeviceStore()
        try devices.requireAccess(.webSSH)
        if action == .cycleMode || action == .nextNode {
            try devices.requireAccess(.mihomo)
        }
        let api = devices.webClient
        let policy = PolicyStore(api: devices.client, deviceID: devices.storageID, defaults: devices.defaults)
        let status = DeviceStatusStore(api: api, deviceID: devices.storageID)
        status.expectedFingerprint = devices.demoMode ? nil : devices.current?.fingerprint
        var activity: Activity<U60RecoveryAttributes>?
        if ActivityAuthorizationInfo().areActivitiesEnabled {
            activity = try? Activity.request(
                attributes: U60RecoveryAttributes(name: devices.current?.name ?? "U60"),
                content: ActivityContent(state: .init(stage: "正在执行快捷操作", progress: 0.2), staleDate: Date().addingTimeInterval(30)), pushType: nil)
        }
        do {
            if action != .refresh {
                _ = try await ManagementStore().verifiedAPI(devices, capability: action == .toggleProxy ? .proxyService : .mihomo)
            }
            switch action {
            case .refresh:
                break
            case .toggleProxy:
                let before = try await api.mihomoStatus()
                if !before.running {
                    guard try await api.checkConfig().ok else {
                        throw ManagementError.invalid("配置检查失败，未启动代理。")
                    }
                }
                _ = try await api.control(before.running ? .stop : .start)
                let after = try await api.mihomoStatus()
                guard after.running != before.running else {
                    throw ManagementError.unconfirmed("代理启停未得到回读确认。")
                }
                if after.running, try await !api.connectivity() {
                    throw ManagementError.unconfirmed("代理运行中，但出口检测失败。")
                }
            case .cycleMode:
                let current = try await devices.client.config().mode
                let next: OutboundMode = current == .rule ? .global : current == .global ? .direct : .rule
                try await devices.client.setMode(next)
                guard try await devices.client.config().mode == next else {
                    throw ManagementError.unconfirmed("出站模式未得到回读确认。")
                }
            case .nextNode:
                var proxies = try await devices.client.proxies()
                let mode = try await devices.client.config().mode
                guard mode != .direct else { throw ManagementError.invalid("当前为直连模式，请先在 App 中更改出站模式。") }
                let group = nextNodeGroup(proxies, mode: mode, preferred: policy.preferredGroup)
                guard let group, proxies[group]?.isSelectable == true else {
                    throw ManagementError.invalid("当前地区没有可手动切换的节点组，请在 App 中选择。")
                }
                _ = try await devices.client.groupDelay(group: group, url: DelayTest.url, timeoutMs: DelayTest.timeoutMs)
                proxies = try await devices.client.proxies()
                guard let next = nextNode(in: group, proxies: proxies) else {
                    throw ManagementError.unconfirmed("当前地区没有其他测速成功的节点。")
                }
                try await devices.client.select(group: group, proxy: next)
                guard try await devices.client.proxies()[group]?.now == next else {
                    throw ManagementError.unconfirmed("节点切换未确认。")
                }
            }
            if devices.mihomoAvailable { await policy.refresh() }
            await status.refreshSnapshot()
            await status.refreshService()
            guard status.snapshot != nil, status.snapshotError == nil else {
                throw ManagementError.unconfirmed("设备不在附近或管理凭据已失效。")
            }
            WidgetSync.update(devices: devices, policy: policy, status: status, force: true)
            if let activity {
                await activity.end(
                    ActivityContent(state: .init(stage: "快捷操作已完成", progress: 1), staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(5)))
            }
        } catch is CancellationError {
            if let activity { await activity.end(nil, dismissalPolicy: .immediate) }
            throw CancellationError()
        } catch {
            UserDefaults(suiteName: WidgetSnapshot.appGroup)?.set("连接或操作失败，请打开 App 检查", forKey: "widget.error")
            WidgetCenter.shared.reloadAllTimelines()
            if let activity {
                await activity.end(ActivityContent(state: .init(stage: "操作未完成，请打开 App 检查", progress: 0), staleDate: nil), dismissalPolicy: .default)
            }
            throw error
        }
    }

    /// 沿常用组的当前选择定位节点组，不跨业务组或地区自动改变选择。
    static func nextNodeGroup(
        _ proxies: [String: MihomoProxy], mode: OutboundMode = .rule, preferred: String? = nil
    ) -> String? {
        guard var name = PreferredPolicyGroup.resolve(in: proxies, mode: mode, preferred: preferred) else { return nil }
        var seen = Set<String>()
        while let group = proxies[name], group.isGroup, seen.insert(name).inserted {
            guard let next = group.now, proxies[next]?.isGroup == true else {
                return name
            }
            name = next
        }
        return nil
    }

    static func nextNode(in name: String, proxies: [String: MihomoProxy]) -> String? {
        guard let group = proxies[name] else {
            return nil
        }
        let nodes = (group.all ?? []).compactMap {
            proxies[$0]
        }
        .filter {
            !$0.isGroup && !$0.isBuiltin && ($0.lastDelay ?? 0) > 0
        }
        .sorted {
            ($0.lastDelay ?? 0, $0.name) < ($1.lastDelay ?? 0, $1.name)
        }
        guard !nodes.isEmpty else {
            return nil
        }
        let current = nodes.firstIndex {
            $0.name == group.now
        }
        let next =
            current.map {
                ($0 + 1) % nodes.count
            } ?? 0
        return nodes[next].name == group.now ? nil : nodes[next].name
    }
}
