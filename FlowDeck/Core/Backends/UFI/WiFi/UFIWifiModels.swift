import Foundation

/// F50 B09 原厂接入点。只编辑主网络，保留设备返回的安全模式，不推断访客网络或发射功率。
struct UFIWifiAccessPoint: Codable, Equatable, Identifiable, Sendable {
    let chip: String
    let index: String
    let enabled: Bool
    var authMode: String
    var isolation: String?
    var ssid: String
    var password: String
    var hidden: Bool
    var maxClients: Int

    var id: String { chip + ":" + index }
    var title: String { chip == "0" ? "2.4 GHz" : "5 GHz" }
    var securityTitle: String {
        switch authMode {
        case "WPA2PSK": return "WPA2 Personal"
        case "WPA3PSK": return "WPA3 Personal"
        case "WPA2PSKWPA3PSK": return "WPA2 / WPA3 Personal"
        case "WPAPSKWPA2PSK": return "WPA / WPA2 Personal"
        default: return authMode
        }
    }

    static func parse(_ object: JSONObject) throws -> [Self] {
        guard let list = object.raw["ResponseList"] as? [[String: Any]] else {
            throw ManagementError.unconfirmed("原厂后台未返回 Wi-Fi 接入点，请重新验证后台密码。")
        }
        let points = try list.compactMap { value -> Self? in
            let item = JSONObject(value)
            guard let chip = item.string("ChipIndex"), ["0", "1"].contains(chip),
                item.string("AccessPointIndex") == "0"
            else { return nil }
            guard let ssid = item.string("SSID"), !ssid.isEmpty,
                let encoded = item.string("Password"), let data = Data(base64Encoded: encoded),
                let password = String(data: data, encoding: .utf8),
                let authMode = item.string("AuthMode"), !authMode.isEmpty,
                let enabled = item.string("AccessPointSwitchStatus"), ["0", "1"].contains(enabled),
                let hidden = item.string("ApBroadcastDisabled"), ["0", "1"].contains(hidden),
                let maxClients = item.string("ApMaxStationNumber").flatMap(Int.init), (1...10).contains(maxClients)
            else {
                throw ManagementError.unsupported("Wi-Fi 配置不完整或超出 F50 B09 适配范围，未生成可保存的默认值。")
            }
            let isolation = item.string("ApIsolate").flatMap { ["0", "1"].contains($0) ? $0 : nil }
            return Self(
                chip: chip, index: "0", enabled: enabled == "1", authMode: authMode,
                isolation: isolation, ssid: ssid, password: password, hidden: hidden == "1", maxClients: maxClients)
        }
        guard !points.isEmpty, Set(points.map(\.id)).count == points.count else {
            throw ManagementError.unsupported("未读取到可识别的 F50 主 Wi-Fi 网络。")
        }
        return points.sorted { $0.chip < $1.chip }
    }

    func validate() throws {
        guard ["0", "1"].contains(chip), index == "0" else { throw ManagementError.deviceChanged }
        guard (1...32).contains(ssid.utf8.count),
            !ssid.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw ManagementError.invalid("网络名称须为 1–32 字节，不能包含换行或控制字符。")
        }
        guard ["WPA2PSK", "WPA3PSK", "WPA2PSKWPA3PSK", "WPAPSKWPA2PSK"].contains(authMode) else {
            throw ManagementError.unsupported("当前加密方式尚不支持原生修改，请保留原配置。")
        }
        guard (8...63).contains(password.utf8.count),
            password.unicodeScalars.allSatisfy({ (32...126).contains(Int($0.value)) })
        else {
            throw ManagementError.invalid("F50 Wi-Fi 密码须为 8–63 位英文字母、数字或 ASCII 符号。")
        }
        guard (1...10).contains(maxClients) else { throw ManagementError.invalid("接入上限须为 1–10 台。") }
    }

    /// 遵循设备自带 service.js 的 setAccessPointInfo；不发送开关字段，避免混合切换与参数修改。
    func form() throws -> [String: String] {
        try validate()
        var values = [
            "goformId": "setAccessPointInfo", "isTest": "false", "ChipIndex": chip, "AccessPointIndex": index,
            "SSID": ssid, "Password": Data(password.utf8).base64EncodedString(), "AuthMode": authMode,
            "EncrypType": authMode == "WPAPSKWPA2PSK" ? "TKIPCCMP" : "CCMP",
            "ApBroadcastDisabled": hidden ? "1" : "0", "ApMaxStationNumber": String(maxClients),
        ]
        if let isolation { values["ApIsolate"] = isolation }
        return values
    }

    var sharingNetwork: WifiNetwork {
        WifiNetwork(
            id: chip == "0" ? "main_2g" : "main_5g", ssid: ssid, password: password,
            hidden: hidden, enabled: enabled, channel: "auto", encryption: "psk2")
    }
}

/// Wi-Fi 断线后的恢复记录含密码，只进入本机 Keychain；按硬件指纹隔离，回读确认后删除。
struct UFIWifiRecovery: Codable {
    let deviceID: String
    let before: UFIWifiAccessPoint
    let requested: UFIWifiAccessPoint

    private static func account(_ deviceID: String) -> String {
        "ufi-wifi-recovery-" + DeviceIdentity.digest(Data(deviceID.utf8))
    }

    func save() throws {
        try KeychainStore.setChecked(try JSONEncoder().encode(self).base64EncodedString(), account: Self.account(deviceID))
    }

    static func load(_ deviceID: String) throws -> Self? {
        guard let encoded = KeychainStore.get(account: account(deviceID)), !encoded.isEmpty else { return nil }
        guard let data = Data(base64Encoded: encoded) else { throw ManagementError.invalid("Wi-Fi 恢复记录无法读取。") }
        let record = try JSONDecoder().decode(Self.self, from: data)
        guard record.deviceID == deviceID else { throw ManagementError.deviceChanged }
        return record
    }

    static func clear(_ deviceID: String) throws {
        try KeychainStore.setChecked("", account: account(deviceID))
    }
}
