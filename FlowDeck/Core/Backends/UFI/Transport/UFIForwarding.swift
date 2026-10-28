import Foundation

/// 转发属于 UFI 应用能力，与原厂 SIM 短信接口分离；保存参数会由 UFI 自动发送测试消息。
struct UFIForwardingState: Equatable, Sendable {
    enum Method: String, CaseIterable, Identifiable {
        case smtp = "SMTP"
        case dingtalk = "DINGTALK"
        var id: String { rawValue }
        var title: String { self == .smtp ? "电子邮件" : "钉钉机器人" }
        var route: String { self == .smtp ? "sms_forward_mail" : "sms_forward_dingtalk" }
        var keys: [String] {
            self == .smtp
                ? ["smtp_host", "smtp_port", "smtp_to", "smtp_username", "smtp_password", "smtp_from", "smtp_from_name", "forward_dev_info"]
                : ["webhook_url", "secret", "forward_dev_info"]
        }
    }
    let enabled: Bool
    let method: String
    let values: [String: String]
    let filter: [String: String]

    static func validate(_ values: [String: String], method: Method) throws {
        guard Set(values.keys) == Set(method.keys), values.values.allSatisfy({ $0.utf8.count < 4096 && !$0.contains("\n") && !$0.contains("\r") }),
            ["0", "1"].contains(values["forward_dev_info"] ?? "0")
        else {
            throw ManagementError.invalid("转发参数格式无效。")
        }
        if method == .smtp {
            guard let host = values["smtp_host"], host.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil,
                let port = Int(values["smtp_port"] ?? ""), [465, 587].contains(port),
                values["smtp_to"]?.contains("@") == true,
                !(values["smtp_username"] ?? "").isEmpty, !(values["smtp_password"] ?? "").isEmpty
            else {
                throw ManagementError.invalid("请填写 SMTP 地址、465/587 端口、收件邮箱、账号和授权码。")
            }
        } else {
            guard let url = URL(string: values["webhook_url"] ?? ""), url.scheme == "https",
                url.host == "oapi.dingtalk.com", url.path == "/robot/send", url.user == nil,
                url.password == nil, url.fragment == nil, url.port == nil,
                let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "access_token" })?.value,
                !token.isEmpty
            else {
                throw ManagementError.invalid("请填写钉钉官方 HTTPS 机器人地址。")
            }
        }
    }
}

extension UFIClient {
    func forwardingState(method: UFIForwardingState.Method) async throws -> UFIForwardingState {
        _ = try await identitySnapshot()
        let enabled = try await request("api/sms_forward_enabled")
        let selected = try await request("api/sms_forward_method")
        let values = try await request("api/" + method.route)
        let filter = try await request("api/sms_forward_blacklist")
        guard let flag = enabled.string("enabled"), ["0", "1"].contains(flag),
            let name = selected.raw["sms_forward_method"] as? String
        else {
            throw ManagementError.unconfirmed("未读取到完整转发状态。")
        }
        let fields = try method.keys.reduce(into: [String: String]()) { result, key in
            guard let value = values.raw[key] as? String else {
                throw ManagementError.unsupported("当前 UFI 版本缺少转发字段。")
            }
            result[key] = value
        }
        guard let phone = filter.raw["phone"] as? String, let keywords = filter.raw["keywords"] as? String else {
            throw ManagementError.unconfirmed("未读取到完整过滤设置。")
        }
        return UFIForwardingState(
            enabled: flag == "1", method: name, values: fields,
            filter: ["phone": phone, "keywords": keywords])
    }

    func saveForwarding(
        _ values: [String: String], method: UFIForwardingState.Method,
        replacing original: UFIForwardingState
    ) async throws {
        guard expectedFingerprint != nil else { throw ManagementError.deviceChanged }
        try UFIForwardingState.validate(values, method: method)
        guard try await forwardingState(method: method) == original else {
            throw ManagementError.unconfirmed("转发设置已变化，请重新读取后再保存。")
        }
        if method == .dingtalk {
            // UFI 4.1.5 会在调试日志写入 webhook，不能在日志开启时提交带 token 的目标。
            let logging = try await request("api/get_log_status")
            guard logging.string("debug_log_enabled") == "0" else {
                throw ManagementError.invalid("请先在 UFI 管理页关闭调试日志，再保存钉钉目标，避免机器人地址被 UFI 记入日志。")
            }
        }
        _ = try await request("api/" + method.route, body: values)
        let actual = try await forwardingState(method: method)
        guard actual.method == method.rawValue, actual.values == values else {
            throw ManagementError.unconfirmed("转发保存尚未确认，请刷新检查；不要重复发送测试消息。")
        }
    }

    func toggleForwarding(
        _ enabled: Bool, method: UFIForwardingState.Method,
        replacing original: UFIForwardingState
    ) async throws {
        guard expectedFingerprint != nil else { throw ManagementError.deviceChanged }
        guard try await forwardingState(method: method) == original else { throw ManagementError.deviceChanged }
        if enabled {
            guard original.method == method.rawValue else { throw ManagementError.invalid("请先保存所选转发方式。") }
            try UFIForwardingState.validate(original.values, method: method)
        }
        _ = try await request("api/sms_forward_enabled", query: [URLQueryItem(name: "enable", value: enabled ? "1" : "0")], body: [:])
        guard try await forwardingState(method: method).enabled == enabled else {
            throw ManagementError.unconfirmed("转发开关回读未确认，请刷新检查。")
        }
    }

    func saveForwardingFilter(
        _ filter: [String: String], method: UFIForwardingState.Method,
        replacing original: UFIForwardingState
    ) async throws {
        guard expectedFingerprint != nil, let phone = filter["phone"], let words = filter["keywords"],
            phone.utf8.allSatisfy({ $0 == 10 || (48...57).contains($0) }),
            phone.utf8.count <= 4096, words.utf8.count <= 4096
        else {
            throw ManagementError.invalid("过滤号码每行一个，只能包含数字。")
        }
        guard try await forwardingState(method: method) == original else { throw ManagementError.deviceChanged }
        _ = try await request("api/sms_forward_blacklist", body: filter)
        guard try await forwardingState(method: method).filter == filter else {
            throw ManagementError.unconfirmed("过滤设置回读尚未确认。")
        }
    }
}
