import Foundation

/// App 每次刷新后写入共享容器，小组件只读取这份快照；刷新时机由 iOS 决定，所以界面上会标出更新时间。
struct WidgetSnapshot: Codable, Equatable {
    var deviceName: String
    var exitName: String?
    var exitLine: String?
    var delay: Int?
    var mode: String
    var proxyRunning: Bool?
    var battery: Int?
    var charging: Bool
    var rsrp: Int?
    var signalQuality: String?
    var todayBytes: Int64?
    var clients: Int?
    var demo: Bool
    var updatedAt: Date
    /// 可选字段兼容旧快照；身份标识为摘要，不包含设备密码或 IMEI。
    var deviceID: String? = nil
    var connectionMessage: String? = nil

    func isStale(at date: Date) -> Bool { date.timeIntervalSince(updatedAt) >= 120 }
    func statusText(at date: Date) -> String {
        if demo { return "演示数据" }
        if updatedAt == .distantPast { return "尚未读取" }
        if connectionMessage != nil { return "连接待检查" }
        return isStale(at: date) ? "待刷新" : "最近已读取"
    }

    static let appGroup = AppIdentity.appGroup
    private static let key = "widget.snapshot.v1"

    static var placeholder: WidgetSnapshot {
        WidgetSnapshot(
            deviceName: "随身设备", exitName: "IDCF 东一", exitLine: "🇯🇵 [华为沪日]", delay: 63, mode: "规则",
            proxyRunning: true, battery: 94, charging: true, rsrp: -94, signalQuality: "良好",
            todayBytes: 1_284_000_000, clients: 4, demo: true, updatedAt: Date())
    }

    static func load() -> WidgetSnapshot? {
        guard let data = UserDefaults(suiteName: appGroup)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults(suiteName: Self.appGroup)?.set(data, forKey: Self.key)
    }
}
