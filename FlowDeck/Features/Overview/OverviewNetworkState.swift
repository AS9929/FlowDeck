import Foundation

/// 将新鲜度、可达性与蜂窝结果映射为首页连接状态。
struct OverviewNetworkState {
    let title: String
    let detail: String?
    let symbol: String
    let needsAttention: Bool
    private(set) var isConnected = false

    /// 联网文案只允许由新鲜、明确的蜂窝连接结果触发；加载不属于故障，也不等于成功。
    func subtitle(cellular: String) -> String {
        isConnected ? cellular + " · 蜂窝已联网" : title
    }

    init(connected: Bool?, updatedAt: Date?, error: String?, now: Date, managementAvailable: Bool = true) {
        if !managementAvailable {
            title = "设备管理未配置"
            detail = "添加管理凭据后可读取蜂窝和用量"
            symbol = "wifi.router"
            needsAttention = true
        } else if error != nil {
            title = "设备连接待恢复"
            detail = "请确认连接到了设备的 Wi-Fi"
            symbol = "wifi.exclamationmark"
            needsAttention = true
        } else if let updatedAt, now.timeIntervalSince(updatedAt) > 15 {
            title = "设备状态待刷新"
            detail = "上次读取于 " + updatedAt.formatted(date: .omitted, time: .standard)
            symbol = "clock.badge.exclamationmark"
            needsAttention = true
        } else if connected == false, updatedAt != nil {
            title = "蜂窝未联网"
            detail = "设备可访问，蜂窝连接尚未建立"
            symbol = "antenna.radiowaves.left.and.right.slash"
            needsAttention = true
        } else if connected == true, updatedAt != nil {
            isConnected = true
            title = "蜂窝已联网"
            detail = nil
            symbol = "antenna.radiowaves.left.and.right"
            needsAttention = false
        } else {
            title = "正在读取设备"
            detail = "等待网络状态"
            symbol = "wifi"
            needsAttention = false
        }
    }
}
