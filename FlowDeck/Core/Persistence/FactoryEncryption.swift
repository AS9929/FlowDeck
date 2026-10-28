import CommonCrypto
import Foundation
import Security

/// 对齐原厂网页的 RSA PKCS1 + AES256-CBC 协议。随机密钥只用于单次认证会话。
enum FactoryEncryption {
    static func randomBytes(count: Int) throws -> Data {
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        guard result == errSecSuccess else {
            throw ManagementError.unconfirmed("无法生成安全随机密钥。")
        }
        return data
    }

    static func encryptPIN(_ pin: String, key: Data, iv: Data) throws -> String {
        guard key.count == 32, iv.count == 16 else {
            throw ManagementError.invalid("PIN 加密参数无效。")
        }
        let input = Data(pin.utf8)
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var length = 0
        let status = output.withUnsafeMutableBytes { destination in
            input.withUnsafeBytes { source in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress, source.baseAddress, input.count,
                            destination.baseAddress, destination.count, &length)
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw ManagementError.unconfirmed("PIN 加密失败。")
        }
        return (iv + output.prefix(length)).base64EncodedString()
    }

    static func wrapKey(_ key: Data, publicPEM: String) throws -> String {
        let body = publicPEM.replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .filter {
                !$0.isWhitespace
            }
        guard let spki = Data(base64Encoded: body) else {
            throw ManagementError.invalid("原厂公钥无法解析。")
        }
        // SecKey 接受 PKCS1 公钥。SPKI 的最后一个 BIT STRING 才是 RSA 模数与指数序列。
        let bytes = Array(spki)
        var index = 0
        func field(_ tag: UInt8) throws -> Range<Int> {
            guard index + 2 <= bytes.count, bytes[index] == tag else {
                throw ManagementError.invalid("原厂公钥结构无效。")
            }
            index += 1
            var length = Int(bytes[index])
            index += 1
            if length & 0x80 != 0 {
                let count = length & 0x7f
                guard count > 0, count <= 4, index + count <= bytes.count else {
                    throw ManagementError.invalid("公钥长度无效。")
                }
                length = 0
                for _ in 0..<count {
                    length = length * 256 + Int(bytes[index])
                    index += 1
                }
            }
            guard index + length <= bytes.count else {
                throw ManagementError.invalid("公钥内容不完整。")
            }
            return index..<(index + length)
        }
        _ = try field(0x30)
        let algorithm = try field(0x30)
        index = algorithm.upperBound
        let bitString = try field(0x03)
        guard !bitString.isEmpty, bytes[bitString.lowerBound] == 0 else {
            throw ManagementError.invalid("公钥位串无效。")
        }
        let rawKey = Data(bytes[(bitString.lowerBound + 1)..<bitString.upperBound])
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        guard let rsa = SecKeyCreateWithData(rawKey as CFData, attributes as CFDictionary, &error),
            let cipher = SecKeyCreateEncryptedData(
                rsa, .rsaEncryptionPKCS1,
                Data(
                    key.map {
                        String(format: "%02x", $0)
                    }.joined().utf8) as CFData, &error)
        else {
            throw ManagementError.unconfirmed("无法建立原厂加密会话。")
        }
        return (cipher as Data).base64EncodedString()
    }
}
