import CryptoKit
import Foundation

/// 在既有认证通道上传公钥与密文。辅助程序无监听端口，不把 YAML 放入公开上传目录。
/// 会话使用临时 P-256 ECDH + SHA-256 和 AES-GCM，结束时清除设备上的临时密钥。
struct UFISecureConfigChannel: Sendable {
    static let maximumBytes = 2 * 1024 * 1024
    private static let root = "/data/local/flowdeck-config"
    private let command: @Sendable (String) async throws -> String

    init(command: @escaping @Sendable (String) async throws -> String) {
        self.command = command
    }

    func transfer(saving content: String? = nil) async throws -> String {
        if let content, content.isEmpty || content.utf8.count > Self.maximumBytes {
            throw ManagementError.invalid("配置须为非空 UTF-8 文本，最大 2 MB。")
        }
        let helper = try await prepare()
        let identifier = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let invocation = "CLASSPATH=\(helper) app_process /system/bin FlowDeckConfig"
        do {
            let privateKey = P256.KeyAgreement.PrivateKey()
            let response = try await command(
                "\(invocation) begin \(identifier) '\(privateKey.publicKey.derRepresentation.base64EncodedString())'")
            let fields = UFIClient.fields(response)
            guard fields["status"] == "ready", let encoded = fields["public"],
                let publicData = Data(base64Encoded: encoded)
            else {
                throw ManagementError.unconfirmed("无法建立配置加密会话，未修改配置。")
            }
            let publicKey = try P256.KeyAgreement.PublicKey(derRepresentation: publicData)
            let shared = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
            let key = shared.withUnsafeBytes { SymmetricKey(data: SHA256.hash(data: Data($0))) }
            let read = UFIClient.fields(try await command("\(invocation) read \(identifier)"))
            guard let encryptedText = read["data"], let packet = Data(base64Encoded: encryptedText),
                packet.count <= Self.maximumBytes + 28
            else {
                throw ManagementError.unconfirmed("配置读取不完整，请重试。")
            }
            let plaintext = try Self.decrypt(packet, key: key, context: "read:" + identifier)
            guard let text = String(data: plaintext, encoding: .utf8) else {
                throw ManagementError.invalid("设备配置不是 UTF-8 文本。")
            }
            let result: String
            if let content {
                do {
                    try UFIConfigurationPolicy.validate(original: text, candidate: content)
                } catch {
                    throw UFIConfigurationNotApplied(message: error.localizedDescription)
                }
                let packet = try Self.encrypt(Data(content.utf8), key: key, context: "write:" + identifier)
                let upload = Self.root + "/" + identifier + "/upload"
                try await writeBase64(packet.base64EncodedString(), path: upload)
                let saved = UFIClient.fields(try await command("\(invocation) commit \(identifier)"))
                switch saved["status"] {
                case "busy":
                    throw UFIConfigurationNotApplied(message: "设备有其他配置或核心任务，未替换原配置。")
                case "conflict":
                    throw UFIConfigurationNotApplied(message: "设备配置已发生变化，请重新预览后再应用。")
                case "invalid", "validation-timeout":
                    throw UFIConfigurationNotApplied(message: "新配置未通过设备校验，原配置未替换。")
                case "saved":
                    guard saved["sha256"] == DeviceIdentity.digest(Data(content.utf8)) else {
                        throw ManagementError.unconfirmed("配置已提交，但回读摘要不一致，请检查配置历史。")
                    }
                default:
                    throw ManagementError.unconfirmed("配置提交结果未确认，请恢复连接后检查。")
                }
                result = content
            } else {
                result = text
            }
            _ = try await command("\(invocation) close \(identifier)")
            return result
        } catch {
            // 即便上层任务取消也尝试清理；断网遗留由下次会话清理过期目录。
            _ = try? await command("\(invocation) close \(identifier)")
            throw error
        }
    }

    static func encrypt(_ data: Data, key: SymmetricKey, context: String) throws -> Data {
        guard let packet = try AES.GCM.seal(data, using: key, authenticating: Data(context.utf8)).combined else {
            throw ManagementError.invalid("无法加密配置。")
        }
        return packet
    }

    static func decrypt(_ packet: Data, key: SymmetricKey, context: String) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: packet), using: key, authenticating: Data(context.utf8))
    }

    func prepare() async throws -> String {
        guard let url = Bundle.main.url(forResource: "F50ConfigBridge", withExtension: "dex") else {
            throw ManagementError.unsupported("App 缺少配置传输组件。")
        }
        let data = try Data(contentsOf: url)
        let checksum = DeviceIdentity.digest(data)
        let path = Self.root + "/bridge-" + checksum + ".dex"
        let installed = try await command("sha256sum \(path) 2>/dev/null")
        if installed.split(whereSeparator: \.isWhitespace).first == Substring(checksum) {
            return path
        }
        _ = try await command("umask 077; mkdir -p \(Self.root); chmod 700 \(Self.root)")
        let temporary = Self.root + "/install-" + UUID().uuidString.lowercased()
        do {
            try await writeBase64(data.base64EncodedString(), path: temporary)
            let result = try await command(
                "umask 077; base64 -d \(temporary) > \(temporary).dex && "
                    + "chmod 600 \(temporary).dex && sha256sum \(temporary).dex")
            guard result.split(whereSeparator: \.isWhitespace).first == Substring(checksum) else {
                throw ManagementError.unconfirmed("配置组件校验失败，未启用。")
            }
            _ = try await command("mv \(temporary).dex \(path); rm -f \(temporary)")
            return path
        } catch {
            _ = try? await command("rm -f \(temporary) \(temporary).dex")
            throw error
        }
    }

    /// 分块只传 Base64 密文或无凭据的程序。每块覆盖/追加结果都确认，失败不重发提交。
    private func writeBase64(_ text: String, path: String) async throws {
        let bytes = Array(text.utf8)
        for offset in stride(from: 0, to: bytes.count, by: 16_384) {
            try Task.checkCancellation()
            let chunk = String(decoding: bytes[offset..<min(offset + 16_384, bytes.count)], as: UTF8.self)
            let redirect = offset == 0 ? ">" : ">>"
            let result = try await command(
                "umask 077; printf '%s' '\(chunk)' \(redirect) \(path) && echo flowdeck_chunk=ok")
            guard UFIClient.fields(result)["flowdeck_chunk"] == "ok" else {
                throw ManagementError.unconfirmed("配置传输中断，未继续提交。")
            }
        }
    }
}

/// 明确在替换前被拒绝；上层不得用回滚覆盖其他客户端刚提交的配置。
struct UFIConfigurationNotApplied: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
