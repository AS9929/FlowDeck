import SwiftUI

/// 原厂详情入口的展示信息，实际协议操作由服务负责。
enum UFIDetailSection: String, Identifiable {
    case clients, messages, cellular, hardware, maintenance
    var id: String { rawValue }
    var title: String {
        switch self {
        case .clients: return "接入设备"
        case .messages: return "短信"
        case .cellular: return "SIM 与 APN"
        case .hardware: return "系统与 USB"
        case .maintenance: return "检查与重启"
        }
    }
    var symbol: String {
        switch self {
        case .clients: return "person.2"
        case .messages: return "message"
        case .cellular: return "simcard"
        case .hardware: return "cable.connector"
        case .maintenance: return "stethoscope"
        }
    }
    var subtitle: String {
        switch self {
        case .clients: return "识别热点与 USB 接入，查看每台设备的网络地址"
        case .messages: return "收件、发件、草稿与搜索"
        case .cellular: return "SIM 安全状态与当前接入点"
        case .hardware: return "运行资源、蜂窝用量与 USB 连接"
        case .maintenance: return "校验代理配置，或重新启动当前设备"
        }
    }
    var needsFactory: Bool { self != .hardware }
}
