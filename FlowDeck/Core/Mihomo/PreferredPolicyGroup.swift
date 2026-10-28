import Foundation

/// 常用组只代表用户在首页关注和快捷切换的策略，不等同于规则模式下所有请求的出口。
/// 多组且无法识别时要求用户选择，避免快捷操作擅自切换其他业务策略。
enum PreferredPolicyGroup {
    static func saved(deviceID: String, defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: "preferredGroup." + deviceID)
    }

    static func save(_ name: String?, deviceID: String, defaults: UserDefaults = .standard) {
        if let name {
            defaults.set(name, forKey: "preferredGroup." + deviceID)
        } else {
            defaults.removeObject(forKey: "preferredGroup." + deviceID)
        }
    }

    static func resolve(in proxies: [String: MihomoProxy], mode: OutboundMode, preferred: String?) -> String? {
        switch mode {
        case .direct:
            return nil
        case .global:
            return proxies["GLOBAL"]?.isGroup == true ? "GLOBAL" : nil
        case .rule:
            if let preferred {
                return preferred != "GLOBAL" && proxies[preferred]?.isGroup == true ? preferred : nil
            }
            if proxies["Proxies"]?.isGroup == true { return "Proxies" }
            let groups = proxies.values.filter { $0.isGroup && $0.name != "GLOBAL" && !$0.hidden }
            return groups.count == 1 ? groups.first?.name : nil
        }
    }
}
