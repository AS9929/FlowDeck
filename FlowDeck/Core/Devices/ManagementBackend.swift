import Foundation

/// 管理通道与设备型号分离。旧记录默认 WebSSH，避免升级后更换原有认证方式。
struct ManagementBackend: RawRepresentable, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let webSSH = Self(rawValue: "webSSH")
    static let ufiTools = Self(rawValue: "ufiTools")
    static var allCases: [Self] { BackendRegistry.supportedIDs }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var id: String { rawValue }
    var title: String {
        switch self {
        case .webSSH: return "WebSSH"
        case .ufiTools: return "UFI-TOOLS"
        default: return "不支持的管理方式"
        }
    }

    /// 接入页由已实现的后端生成；新增后端必须同时提供认证与能力适配。
    var connectionTitle: String { "\(title) + Mihomo" }

    var connectionDescription: String {
        switch self {
        case .webSSH:
            return "使用 WebSSH 密码与 Mihomo Secret 连接。当前适配 U60 Pro。"
        case .ufiTools:
            return "使用 UFI-TOOLS 口令与 Mihomo Secret 连接。当前适配 F50。"
        default: return "请使用支持此管理方式的 App 版本。"
        }
    }

    var symbol: String {
        switch self {
        case .webSSH: return "terminal"
        case .ufiTools: return "server.rack"
        default: return "questionmark.square"
        }
    }

    var defaultPort: Int {
        switch self {
        case .webSSH: return 8899
        case .ufiTools: return 2333
        default: return 0
        }
    }

    var defaultMihomoPort: Int {
        switch self {
        case .webSSH: return 9090
        case .ufiTools: return 7788
        default: return 0
        }
    }
}

/// 同一台设备的代理选择、服务启停和原厂系统写入有不同授权边界。
enum ManagementCapability {
    case system
    case mihomo
    case proxyService
    case wifi
    case factoryControl
    case clock
}
