import CryptoKit
import Foundation

/// 维护流程共用的可恢复错误；错误文字可以展示，但原始配置和认证响应不进入导出记录。
enum ManagementError: LocalizedError, Equatable {
    case invalid(String)
    case unsupported(String)
    case unconfirmed(String)
    case deviceChanged

    var errorDescription: String? {
        switch self {
        case .invalid(let reason), .unsupported(let reason), .unconfirmed(let reason): return reason
        case .deviceChanged: return "设备身份已变化，请重新配对后再操作。"
        }
    }
}

/// 只保存设备标识的摘要，避免将 IMEI 写入普通偏好或诊断文件。
enum DeviceIdentity {
    static func fingerprint(model: String?, imei: String?) -> String? {
        guard let model, let imei, !model.isEmpty, (14...16).contains(imei.count),
            imei.utf8.allSatisfy({
                (48...57).contains($0)
            }
            )
        else {
            return nil
        }
        return digest(Data("\(model)|\(imei)".utf8))
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

struct WifiNetwork: Identifiable, Equatable, Sendable, Codable {
    let id: String
    var ssid: String
    var password: String
    var hidden: Bool
    var enabled: Bool
    var channel: String
    var encryption: String

    var title: String {
        id == "main_2g" ? "2.4 GHz" : "5 GHz"
    }
    var radio: String {
        id == "main_2g" ? "wifi0" : "wifi1"
    }

    func validate() throws {
        guard (1...32).contains(ssid.utf8.count), !ssid.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw ManagementError.invalid("Wi-Fi 名称须为 1–32 字节，不能包含控制字符。")
        }
        guard (8...63).contains(password.utf8.count) || (password.count == 64 && password.allSatisfy(\.isHexDigit)) else {
            throw ManagementError.invalid("Wi-Fi 密码须为 8–63 字节，或 64 位十六进制密钥。")
        }
        let allowed = id == "main_2g" ? Array(1...13) : [36, 40, 44, 48, 149, 153, 157, 161, 165]
        guard channel == "auto" || channel == "0" || Int(channel).map(allowed.contains) == true else {
            throw ManagementError.invalid("请选择自动或支持的 Wi-Fi 信道。")
        }
        guard ["psk2", "psk2+ccmp", "psk2+aes", "psk3", "psk3-mixed", "sae", "sae-mixed"].contains(encryption) else {
            throw ManagementError.unsupported("当前加密方式不支持直接修改，请先保留原配置。")
        }
    }
}

struct ConfigRevision: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let deviceID: String
    let checksum: String
    let content: String
    var sourceName: String? = nil
}

/// 历史配置含节点密码，只存受 iOS 文件保护的私有目录，并从设备备份中排除。
enum ConfigHistory {
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ConfigurationHistory", isDirectory: true)
    }

    static func list(deviceID: String) throws -> [ConfigRevision] {
        let file = directory.appendingPathComponent(DeviceIdentity.digest(Data(deviceID.utf8)) + ".json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            return []
        }
        return try JSONDecoder().decode([ConfigRevision].self, from: Data(contentsOf: file))
    }

    static func remove(deviceID: String) {
        try? removeChecked(deviceID: deviceID)
    }

    /// 删除设备时需传播文件系统错误，避免历史配置未删却提示移除成功。
    static func removeChecked(deviceID: String) throws {
        let file = directory.appendingPathComponent(DeviceIdentity.digest(Data(deviceID.utf8)) + ".json")
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    static func save(_ content: String, deviceID: String, sourceName: String? = nil) throws {
        var revisions = try list(deviceID: deviceID)
        let digest = DeviceIdentity.digest(Data(content.utf8))
        guard revisions.first?.checksum != digest else {
            return
        }
        revisions.insert(ConfigRevision(id: UUID(), createdAt: Date(), deviceID: deviceID, checksum: digest, content: content, sourceName: sourceName), at: 0)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var file = directory.appendingPathComponent(DeviceIdentity.digest(Data(deviceID.utf8)) + ".json")
        try JSONEncoder().encode(Array(revisions.prefix(5))).write(to: file, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try file.setResourceValues(values)
    }
}

/// 诊断只记录固定项目和结果，不接受任意日志文本，避免错误响应夹带凭据。
struct DiagnosticCheck: Identifiable, Codable {
    enum Outcome: String, Codable {
        case passed, failed, unavailable
    }
    let id: String
    let title: String
    let outcome: Outcome
    let detail: String
}

struct DiagnosticReport: Codable {
    let date: Date
    let demo: Bool
    let checks: [DiagnosticCheck]

    func export() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("U60-diagnostics-\(UUID().uuidString).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}

struct CoreUpdateInfo: Sendable {
    let current: String
    let latest: String
    let available: Bool
}

/// Wi-Fi 改名导致断线后，App 被终止仍能取回旧值。敏感旧值存储于仅本机钥匙串，读取时迁移旧版保护文件。
struct WifiRecovery: Codable {
    let deviceID: String
    let before: [WifiNetwork]
    let requested: [WifiNetwork]

    private static func url(_ deviceID: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wifi-recovery-" + DeviceIdentity.digest(Data(deviceID.utf8)) + ".json")
    }

    private static func account(_ deviceID: String) -> String {
        "wifi-recovery-" + DeviceIdentity.digest(Data(deviceID.utf8))
    }

    func save() throws {
        let encoded = try JSONEncoder().encode(self).base64EncodedString()
        try KeychainStore.setChecked(encoded, account: Self.account(deviceID))
        let legacy = Self.url(deviceID)
        if FileManager.default.fileExists(atPath: legacy.path) { try FileManager.default.removeItem(at: legacy) }
    }

    static func load(_ deviceID: String) throws -> Self? {
        let data: Data
        if let value = KeychainStore.get(account: account(deviceID)), let decoded = Data(base64Encoded: value) {
            data = decoded
        } else {
            let file = url(deviceID)
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            data = try Data(contentsOf: file)
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.deviceID == deviceID else { throw ManagementError.deviceChanged }
        try value.save()
        return value
    }

    static func clear(_ deviceID: String) throws {
        try KeychainStore.setChecked("", account: account(deviceID))
        let file = url(deviceID)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

}

/// LTE 锁频返回十六进制位掩码，lte_band 则是支持频段列表，二者不能混用。
enum BandSelection {
    static func lte(_ value: String?) -> Set<Int>? {
        guard let value else {
            return nil
        }
        let hex = value.lowercased().hasPrefix("0x") ? String(value.dropFirst(2)) : value
        guard !hex.isEmpty, hex.count <= 32, hex.allSatisfy(\.isHexDigit) else {
            return nil
        }
        var selected = Set<Int>()
        for (offset, digit) in hex.reversed().enumerated() {
            guard let nibble = digit.hexDigitValue else {
                return nil
            }
            for bit in 0..<4 where nibble & (1 << bit) != 0 {
                selected.insert(offset * 4 + bit + 1)
            }
        }
        return selected
    }

    static func nr(_ value: String?) -> Set<Int> {
        Set(
            (value ?? "").split(separator: ",").compactMap {
                Int($0.trimmingCharacters(in: .whitespaces))
            })
    }

    static func mask(_ bands: [Int]) -> String {
        var digits = [Int](repeating: 0, count: 32)
        for band in bands where (1...128).contains(band) {
            digits[(band - 1) / 4] |= 1 << ((band - 1) % 4)
        }
        let value = digits.reversed().map {
            String($0, radix: 16)
        }
        .joined().drop {
            $0 == "0"
        }
        return "0x" + (value.isEmpty ? "0" : String(value))
    }
}

/// 每台设备的最近快照只用于离线展示，不能替代写入前的实时身份检查。
/// 缓存剔除 SIM、IMEI 和电话号码，并使用本机文件保护。
struct DeviceSnapshotCache: Codable {
    let capturedAt: Date
    let snapshot: DeviceSnapshot

    private static func url(_ deviceID: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("snapshot-" + DeviceIdentity.digest(Data(deviceID.utf8)) + ".json")
    }

    static func save(_ state: DeviceSnapshot, deviceID: String, date: Date = Date()) throws {
        var sanitized = state
        sanitized.imei = nil
        sanitized.iccid = nil
        sanitized.imsi = nil
        sanitized.msisdn = nil
        var file = url(deviceID)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Self(capturedAt: date, snapshot: sanitized)).write(to: file, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try file.setResourceValues(values)
    }

    static func load(_ deviceID: String) -> Self? {
        guard let data = try? Data(contentsOf: url(deviceID)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    static func remove(_ deviceID: String) {
        try? removeChecked(deviceID)
    }

    /// 缓存不存在视为已清除，其他错误交由设备删除流程提示重试。
    static func removeChecked(_ deviceID: String) throws {
        let file = url(deviceID)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }
}
