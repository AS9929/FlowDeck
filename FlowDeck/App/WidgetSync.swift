import Foundation
import WidgetKit

/// 把当前状态写给小组件。只在内容变化时写入，并限制刷新频率。
@MainActor
enum WidgetSync {
    private static var last: WidgetSnapshot?
    private static var lastReload = Date.distantPast

    static func update(devices: DeviceStore, policy: PolicyStore, status: DeviceStatusStore, force: Bool = false) {
        let previousIssue = last?.connectionMessage
        let deviceChanged = last?.deviceID != devices.storageID
        let issue: String?
        if let accessIssue = devices.accessIssue(for: .device) {
            issue = accessIssue.message
        } else if status.snapshotError != nil {
            issue = "设备状态读取失败，请打开 App 检查"
        } else if case .failed = policy.state {
            issue = "代理连接失败，请打开 App 检查"
        } else {
            issue = nil
        }
        UserDefaults(suiteName: WidgetSnapshot.appGroup)?.removeObject(forKey: "widget.error")
        let policyDate: Date?
        if case .loaded(let date) = policy.state { policyDate = date } else { policyDate = nil }
        // 写共享缓存的时间不能充当设备采样时间；取最旧来源，避免旧节点配上新时间。
        let sampledAt = [status.snapshotAt, policyDate].compactMap { $0 }.min() ?? .distantPast
        let s = devices.webAvailable ? status.snapshot : nil
        let exit = devices.mihomoAvailable ? policy.exitNode : nil
        let snap = WidgetSnapshot(
            deviceName: devices.demoMode ? "演示设备" : devices.current?.name ?? "尚未接入设备",
            exitName: exit.map { PolicyStore.shortName($0.name) },
            exitLine: exit.flatMap { $0.name.components(separatedBy: " | ").first },
            delay: exit?.lastDelay,
            mode: policy.mode == .rule ? "规则" : policy.mode == .global ? "全局" : "直连",
            proxyRunning: devices.webAvailable ? status.service?.running : nil,
            battery: s?.battery,
            charging: s?.charging ?? false,
            rsrp: s?.rsrp.map { Int($0) },
            signalQuality: s?.signalQuality,
            todayBytes: s?.dayRx.map { $0 + (s?.dayTx ?? 0) },
            clients: s?.clientsTotal,
            demo: devices.demoMode,
            updatedAt: sampledAt, deviceID: devices.storageID, connectionMessage: issue)
        // 相同读数的新采样仍更新真实时间，只限制 WidgetKit 重载频率。
        if !force && snap == last { return }
        snap.save()
        last = snap
        if force || deviceChanged || previousIssue != issue || Date().timeIntervalSince(lastReload) > 60 {
            lastReload = Date()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
