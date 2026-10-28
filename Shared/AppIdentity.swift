import Foundation

/// App 与 Widget 从构建配置读取同一身份，避免修改签名后仍访问其他构建的共享容器。
/// 这些值不是设备凭据；缺失时终止初始化，不静默回退到维护者的历史身份。
enum AppIdentity {
    static let appGroup = requiredValue("FlowDeckAppGroup")
    static let keychainService = requiredValue("FlowDeckKeychainService")
    static let urlScheme = requiredValue("FlowDeckURLScheme")

    /// 构造内部入口；route 是代码中定义的固定 host，不包含设备密码或订阅。
    static func url(for route: String) -> URL {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = route
        guard let url = components.url else {
            preconditionFailure("Invalid internal route")
        }
        return url
    }

    private static func requiredValue(_ key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
            !value.isEmpty, !value.contains("$(")
        else {
            preconditionFailure("Missing build identity: \(key)")
        }
        return value
    }
}
