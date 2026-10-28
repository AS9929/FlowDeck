import Foundation

/// 已保存身份与服务凭据分别检查；离线不在这里判定，保留诊断和重试能力。
enum DeviceAccessRequirement {
    case device
    case mihomo
    case webSSH
}

/// 接入前置条件是本地事实，不代表设备当前在线或写入已经授权。
enum DeviceAccessIssue: Equatable {
    case unsupportedBackend
    case invalidEndpoint
    case noDevice
    case unverified
    case missingMihomo
    case missingWebSSH

    static func resolve(
        requirement: DeviceAccessRequirement, demo: Bool, hasDevice: Bool,
        verified: Bool, hasMihomo: Bool, hasWebSSH: Bool
    ) -> Self? {
        if demo { return nil }
        guard hasDevice else { return .noDevice }
        guard verified else { return .unverified }
        switch requirement {
        case .device: return nil
        case .mihomo: return hasMihomo ? nil : .missingMihomo
        case .webSSH: return hasWebSSH ? nil : .missingWebSSH
        }
    }

    var title: String {
        switch self {
        case .unsupportedBackend: return "当前版本不支持此设备记录"
        case .invalidEndpoint: return "设备地址无效"
        case .noDevice: return "先接入你的设备"
        case .unverified: return "验证设备身份"
        case .missingMihomo: return "连接 Mihomo"
        case .missingWebSSH: return "连接设备管理服务"
        }
    }

    var message: String {
        switch self {
        case .unsupportedBackend:
            return "原始记录已保留。请使用支持该管理方式的 App 版本，不会自动改用其他协议。"
        case .invalidEndpoint:
            return "无法创建连接，请在连接与凭据中修正地址和端口。"
        case .noDevice:
            return "尚未接入设备。请先添加设备，再使用状态查询、节点切换和设备管理。"
        case .unverified:
            return "已保存连接地址，但设备身份尚未验证。请在连接与凭据中验证并保存。"
        case .missingMihomo:
            return "当前设备尚未配置 Mihomo Secret。请补充已有凭据；如果尚未安装 Mihomo，请先在电脑上完成部署。"
        case .missingWebSSH:
            return "当前设备缺少管理服务口令（WebSSH 或 UFI-TOOLS）。请在连接与凭据中补充并验证后使用设备管理。"
        }
    }
}
