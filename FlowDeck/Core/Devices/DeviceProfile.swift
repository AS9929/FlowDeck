import Foundation

/// 已保存设备的稳定格式；凭据本体仅存于钥匙串。
struct DeviceProfile: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var host: String = "192.168.0.1"
    var mihomoPort: Int = 9090
    var webPort: Int = 8899
    var webUser: String = "admin"
    var fingerprint: String?
    var model: String?
    var backend: ManagementBackend = .webSSH
    var schemaVersion = 1

    init(name: String) { self.name = name }

    private enum CodingKeys: String, CodingKey { case id, name, host, mihomoPort, webPort, webUser, fingerprint, model, backend, schemaVersion }

    /// 旧版本保存的数据没有 WebSSH 字段，缺省时用默认值。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? "192.168.0.1"
        mihomoPort = try c.decodeIfPresent(Int.self, forKey: .mihomoPort) ?? 9090
        webPort = try c.decodeIfPresent(Int.self, forKey: .webPort) ?? 8899
        webUser = try c.decodeIfPresent(String.self, forKey: .webUser) ?? "admin"
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        backend = try c.decodeIfPresent(ManagementBackend.self, forKey: .backend) ?? .webSSH
    }

    /// 兼容旧记录：保存连接地址不等于完成硬件身份验证。
    var needsVerification: Bool { fingerprint?.isEmpty != false }

    var mihomoURL: URL? { DeviceEndpoint.url(host: host, port: mihomoPort) }
    var webURL: URL? { DeviceEndpoint.url(host: host, port: webPort) }
    var factoryPasswordAccount: String { "factory-password-\(id.uuidString)" }
    var secretAccount: String { "mihomo-secret-\(id.uuidString)" }
    var webPasswordAccount: String { "\(backend == .webSSH ? "webssh" : backend == .ufiTools ? "ufi" : backend.rawValue)-password-\(id.uuidString)" }
}
