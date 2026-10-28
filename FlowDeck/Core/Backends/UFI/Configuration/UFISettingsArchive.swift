import CommonCrypto
import CryptoKit
import Foundation

/// 可移交的设置恢复包。只包含已适配的 Wi-Fi、APN 与 Mihomo，不冒充固件或分区备份。
struct UFISettingsArchive: Codable, Sendable {
    let version: Int
    let fingerprint: String
    let firmware: String
    let createdAt: Date
    let wifi: [UFIWifiAccessPoint]
    let apns: UFIAPNState
    let configuration: String

    func validate(fingerprint expected: String) throws {
        guard version == 1, fingerprint == expected, firmware == "F50_FLYMODEM_ZYV1.0.0B09" else {
            throw ManagementError.invalid("恢复包与当前设备身份或固件不匹配。")
        }
        guard wifi.count == 2, Set(wifi.map(\.id)) == ["0:0", "1:0"],
            !configuration.isEmpty, configuration.utf8.count <= UFISecureConfigChannel.maximumBytes,
            apns.profiles.count <= 20, (0...20).contains(apns.presetCount),
            ["auto", "manual"].contains(apns.mode),
            Set(apns.profiles.map(\.index)).count == apns.profiles.count
        else {
            throw ManagementError.invalid("恢复包的设置结构不完整。")
        }
        for point in wifi { try point.validate() }
        // 预置 APN 可能没有完整协议，不强迫其可写，但必须保证数组索引安全。
        for profile in apns.profiles {
            guard (0..<20).contains(profile.index), profile.ipv4.count == 13, profile.ipv6.count == 13 else {
                throw ManagementError.invalid("恢复包 APN 字段损坏。")
            }
        }
    }
}

/// 将恢复包内容转为待确认草稿；保留实时能力和已有槽位，不直接执行设备写入。
enum UFISettingsRestore {
    static func wifi(_ saved: UFIWifiAccessPoint, current: UFIWifiAccessPoint) throws -> UFIWifiAccessPoint {
        guard saved.id == current.id else { throw ManagementError.deviceChanged }
        var draft = current
        draft.ssid = saved.ssid
        draft.password = saved.password
        draft.authMode = saved.authMode
        draft.hidden = saved.hidden
        draft.maxClients = saved.maxClients
        // 包内缺失隔离状态时保留当前值，不能凭旧包移除设备现在提供的能力。
        if current.isolation != nil, let isolation = saved.isolation {
            draft.isolation = isolation
        }
        try draft.validate()
        return draft
    }

    static func apn(_ saved: UFIAPNProfile, current: UFIAPNState) throws -> UFIAPNProfile {
        guard let index = current.freeIndex else {
            throw ManagementError.invalid("没有可用 APN 槽位，请先整理已有自定义项。")
        }
        let draft = UFIAPNProfile(
            index: index, name: saved.name,
            protocolType: saved.protocolType, ipv4: saved.ipv4, ipv6: saved.ipv6)
        _ = try draft.form()
        return draft
    }
}

/// 固定版本的密码保护容器：PBKDF2-SHA256 600000 次 + AES-256-GCM。
/// 盐和版本头参与认证；解包前限制大小，不读取文件内提供的迭代次数。应在后台任务执行。
enum SettingsArchiveCipher {
    static let maximumBytes = 3 * 1024 * 1024
    private static let magic = Data("FLOWDECK-F50-SETTINGS-1\n".utf8)

    static func seal(_ archive: UFISettingsArchive, password: String) throws -> Data {
        try archive.validate(fingerprint: archive.fingerprint)
        let data = try JSONEncoder().encode(archive)
        guard data.count <= maximumBytes - 128 else { throw failure() }
        let salt = try FactoryEncryption.randomBytes(count: 16)
        let header = magic + salt
        guard let sealed = try AES.GCM.seal(data, using: key(password, salt: salt), authenticating: header).combined else {
            throw failure()
        }
        return header + sealed
    }

    static func open(_ data: Data, password: String, fingerprint: String) throws -> UFISettingsArchive {
        guard data.count <= maximumBytes, data.count >= magic.count + 16 + 28,
            data.starts(with: magic)
        else { throw failure() }
        do {
            let header = Data(data.prefix(magic.count + 16))
            let salt = Data(header.suffix(16))
            let payload = try AES.GCM.open(
                AES.GCM.SealedBox(combined: data.dropFirst(header.count)),
                using: key(password, salt: salt), authenticating: header)
            let archive = try JSONDecoder().decode(UFISettingsArchive.self, from: payload)
            try archive.validate(fingerprint: fingerprint)
            return archive
        } catch { throw failure() }
    }

    private static func key(_ password: String, salt: Data) throws -> SymmetricKey {
        guard (12...256).contains(password.utf8.count) else {
            throw ManagementError.invalid("备份密码须为 12–256 字节，请单独妥善保存。")
        }
        let passwordBytes = Array(password.utf8)
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = passwordBytes.withUnsafeBytes { input in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    input.bindMemory(to: Int8.self).baseAddress, passwordBytes.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 600_000, &bytes, bytes.count)
            }
        }
        guard status == kCCSuccess else { throw failure() }
        return SymmetricKey(data: bytes)
    }

    private static func failure() -> ManagementError {
        .invalid("无法打开设置恢复包：请核对密码、设备身份及文件完整性。")
    }
}

extension UFIClient {
    /// 顺序捕获并复核可变设置；任何一项失败都不产生声称完整的恢复包。
    func captureSettings(password: String) async throws -> UFISettingsArchive {
        guard let expectedFingerprint else { throw ManagementError.deviceChanged }
        try await verifyServiceAdapter()
        let identity = try await identitySnapshot()
        guard let firmware = identity.firmware else { throw ManagementError.deviceChanged }
        let wifi = try await readWifiAccessPoints(password: password)
        let apns = try await readAPNs(password: password)
        let configuration = try await loadConfig()
        guard try await readWifiAccessPoints(password: password) == wifi,
            try await readAPNs(password: password) == apns
        else {
            throw ManagementError.unconfirmed("备份期间设置发生变化，请重新生成恢复包。")
        }
        let archive = UFISettingsArchive(
            version: 1, fingerprint: expectedFingerprint,
            firmware: firmware, createdAt: Date(), wifi: wifi, apns: apns, configuration: configuration)
        try archive.validate(fingerprint: expectedFingerprint)
        return archive
    }
}
