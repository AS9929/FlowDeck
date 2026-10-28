import Foundation

/// WebSSH 返回的无线接口省电状态。未知值不映射为开关，避免误导或写错接口。
struct WiFiPowerState: Sendable {
    let modes: [String: String]
    var interfaces: [String] { modes.keys.sorted() }
    var summary: String {
        guard !modes.isEmpty else { return "此设备未提供可用状态" }
        if modes.values.allSatisfy({ $0 == "off" }) { return "性能优先" }
        if modes.values.allSatisfy({ $0 == "on" }) { return "节能优先" }
        return "各接口设置不同"
    }
}

/// 转发凭据仅用于编辑当前设备配置，不写入 App 的操作日志。
struct SMSForwardSettings: Sendable {
    var barkEnabled = false
    var barkURL = ""
    var barkGroup = "短信"
    var telegramEnabled = false
    var telegramToken = ""
    var telegramChatID = ""
    var lastID = 0

    init(_ value: JSONObject = JSONObject()) {
        barkEnabled = value.bool("bark_enabled") ?? false
        barkURL = value.string("bark_url") ?? ""
        barkGroup = value.string("bark_group") ?? "短信"
        telegramEnabled = value.bool("tg_enabled") ?? false
        telegramToken = value.string("tg_bot_token") ?? ""
        telegramChatID = value.string("tg_chat_id") ?? ""
        lastID = value.int("last_id") ?? 0
    }

    func payload() throws -> JSONObject {
        if barkEnabled {
            guard let url = URL(string: barkURL), url.scheme == "https", url.host != nil else {
                throw ManagementError.invalid("请输入有效的 HTTPS Bark 地址。")
            }
        }
        if telegramEnabled && (telegramToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || telegramChatID.isEmpty) {
            throw ManagementError.invalid("启用 Telegram 前请填写 Bot Token 与 Chat ID。")
        }
        return JSONObject([
            "bark_enabled": barkEnabled, "bark_url": barkURL, "bark_group": barkGroup,
            "tg_enabled": telegramEnabled, "tg_bot_token": telegramToken, "tg_chat_id": telegramChatID,
            // 保存设置时由服务端保留最新游标，避免编辑期间收到的新短信被重复转发。
            "last_id": 0,
        ])
    }
}

/// 单次命令执行结果，不是持续交互的 PTY 会话；退出码与输出分别呈现。
struct DeviceCommandResult: Sendable {
    let code: Int
    let output: String
}

extension WebSSHAPI {
    func wifiPowerState() async throws -> WiFiPowerState {
        let response = try await management("POST", "api/wifi/psm/get", body: JSONObject(["ifaces": ["wlan0", "wlan1", "wlan2", "wlan3"]]))
        guard let data = response.object("data") else { throw ManagementError.unconfirmed("未读取到无线接口状态。") }
        var modes: [String: String] = [:]
        for interface in ["wlan0", "wlan1", "wlan2", "wlan3"] {
            if let mode = data.string(interface + "_psm"), ["on", "off"].contains(mode) {
                modes[interface] = mode
            }
        }
        return WiFiPowerState(modes: modes)
    }

    func setWiFiPowerSaving(_ enabled: Bool, interfaces: [String]) async throws -> WiFiPowerState {
        guard !interfaces.isEmpty, interfaces.allSatisfy({ ["wlan0", "wlan1", "wlan2", "wlan3"].contains($0) }) else {
            throw ManagementError.invalid("请先读取支持的无线接口。")
        }
        let mode = enabled ? "on" : "off"
        _ = try await management("POST", "api/wifi/psm/set", body: JSONObject(["ifaces": interfaces, "mode": mode]))
        let actual = try await wifiPowerState()
        guard interfaces.allSatisfy({ actual.modes[$0] == mode }) else {
            throw ManagementError.unconfirmed("请求已发送，但部分接口未回读到目标模式。")
        }
        return actual
    }

    func smsForwardStatus() async throws -> JSONObject {
        let response = try await management("GET", "api/system/sms-forward/status", body: nil)
        guard let data = response.object("data"), data.object("config") != nil else {
            throw ManagementError.unsupported("此 WebSSH 版本未提供短信转发状态。")
        }
        return data
    }

    func saveSMSForwardSettings(_ settings: SMSForwardSettings) async throws -> JSONObject {
        let payload = try settings.payload()
        _ = try await management("PUT", "api/system/sms-forward/config", body: payload)
        let status = try await smsForwardStatus()
        guard let actual = status.object("config"),
            actual.bool("bark_enabled") == settings.barkEnabled,
            actual.bool("tg_enabled") == settings.telegramEnabled,
            actual.raw["bark_url"] as? String == settings.barkURL,
            actual.raw["tg_bot_token"] as? String == settings.telegramToken,
            actual.raw["tg_chat_id"] as? String == settings.telegramChatID,
            actual.raw["bark_group"] as? String == settings.barkGroup
        else { throw ManagementError.unconfirmed("配置提交后未回读到一致的转发设置。") }
        return status
    }

    /// 用户明确执行后才调用；输出截取到 64 KiB，离开页面不代表设备进程已取消。
    func executeUserCommand(_ command: String) async throws -> DeviceCommandResult {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, command.utf8.count <= 8192 else {
            throw ManagementError.invalid("命令不能为空，且不能超过 8 KB。")
        }
        let result = try await rpc("file", "exec", params: JSONObject(["command": "/bin/sh", "params": ["-c", command]]))
        guard let code = result.int("code") else { throw ManagementError.unconfirmed("设备没有返回命令退出码。") }
        let output = [result.string("stdout"), result.string("stderr")].compactMap { $0 }.joined(separator: "\n")
        let bytes = Array(output.utf8.prefix(65536))
        let suffix = output.utf8.count > 65536 ? "\n[输出超过 64 KB，已截断]" : ""
        return DeviceCommandResult(code: code, output: String(decoding: bytes, as: UTF8.self) + suffix)
    }
}
