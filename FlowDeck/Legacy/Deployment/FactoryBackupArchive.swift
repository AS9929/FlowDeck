import CommonCrypto
import CryptoKit
import Foundation
import zlib

/// 原厂 OpenSSL 3DES + 双层 tar.gz 容器。仅在内存中改写 rc.local，不展开到文件系统。
/// 限制解压大小并保留每个原始 tar 记录，避免链接、权限或未知配置在重打包时变化。
enum FactoryBackupArchive {
    static let innerPath = "tmp/back_parameter_r1.tgz"
    static let digestPath = "tmp/back_parameter_r.md5"
    static let startupPath = "etc/rc.local"
    static let maximumBytes = 32 * 1024 * 1024

    struct Entry {
        var header: Data
        var content: Data
        var name: String

        init(name: String, content: Data, mode: Int = 0o644) throws {
            guard name.utf8.count < 100 else { throw failure("归档路径过长") }
            self.name = name
            self.content = content
            header = Data(repeating: 0, count: 512)
            header.replaceSubrange(0..<name.utf8.count, with: name.utf8)
            Self.octal(mode, into: &header, at: 100, length: 8)
            header[156] = 48
            header.replaceSubrange(257..<263, with: Data("ustar\0".utf8))
        }

        func encoded() -> Data {
            var record = header
            // 未改长度的原始记录逐字节保留头部，包括 BusyBox tar 的八进制填充形式。
            let originalSize = String(decoding: header[124..<136].prefix { $0 != 0 }, as: UTF8.self)
            if Int(originalSize.trimmingCharacters(in: .whitespaces), radix: 8) != content.count {
                Self.octal(content.count, into: &record, at: 124, length: 12)
                record.replaceSubrange(148..<156, with: Data(repeating: 32, count: 8))
                Self.octal(record.reduce(0) { $0 + Int($1) }, into: &record, at: 148, length: 8)
            }
            record.append(content)
            record.append(Data(repeating: 0, count: (512 - content.count % 512) % 512))
            return record
        }

        private static func octal(_ value: Int, into data: inout Data, at offset: Int, length: Int) {
            let digits = String(value, radix: 8)
            let field = String(repeating: "0", count: length - 1 - digits.count) + digits + "\0"
            data.replaceSubrange(offset..<(offset + length), with: field.utf8)
        }
    }

    static func failure(_ detail: String) -> ManagementError {
        .invalid("原厂备份校验失败：" + detail)
    }

    /// OpenSSL EVP_BytesToKey SHA256 的首个块恰好覆盖 24 字节密钥和 8 字节 IV。
    static func crypt(_ input: Data, password: String, encrypt: Bool) throws -> Data {
        guard !password.isEmpty, input.count <= maximumBytes else { throw failure("密钥或大小无效") }
        let salt: Data
        let payload: Data
        if encrypt {
            salt = try FactoryEncryption.randomBytes(count: 8)
            payload = input
        } else {
            guard FactoryClient.isEncryptedBackup(input) else { throw failure("加密容器无效") }
            salt = Data(input[8..<16])
            payload = Data(input.dropFirst(16))
        }
        let derived = Data(SHA256.hash(data: Data(password.utf8) + salt))
        let key = Data(derived.prefix(24))
        let iv = Data(derived.suffix(8))
        var output = Data(count: payload.count + 8)
        var length = 0
        let result = output.withUnsafeMutableBytes { destination in
            payload.withUnsafeBytes { source in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithm3DES),
                            CCOptions(kCCOptionPKCS7Padding), keyBytes.baseAddress, 24, ivBytes.baseAddress,
                            source.baseAddress, payload.count, destination.baseAddress, destination.count, &length)
                    }
                }
            }
        }
        guard result == kCCSuccess else { throw failure("解密后缀错误或文件损坏") }
        let data = Data(output.prefix(length))
        return encrypt ? Data("Salted__".utf8) + salt + data : data
    }

    /// 使用 gzip 包装，单层最多 32 MB；拒绝截断、拼接容器及解压炸弹。
    static func gzip(_ input: Data, compress: Bool) throws -> Data {
        guard input.count <= maximumBytes else { throw failure("输入超过大小上限") }
        var stream = z_stream()
        let status =
            compress
            ? deflateInit2_(
                &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY,
                ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            : inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw failure("无法创建 gzip 流") }
        defer {
            if compress { deflateEnd(&stream) } else { inflateEnd(&stream) }
        }
        return try input.withUnsafeBytes { bytes in
            stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var result = Data()
            var chunk = [UInt8](repeating: 0, count: 65_536)
            while true {
                let code = chunk.withUnsafeMutableBytes { destination -> Int32 in
                    stream.next_out = destination.bindMemory(to: UInt8.self).baseAddress
                    stream.avail_out = uInt(destination.count)
                    return compress ? deflate(&stream, Z_FINISH) : inflate(&stream, Z_NO_FLUSH)
                }
                let count = chunk.count - Int(stream.avail_out)
                guard result.count + count <= maximumBytes else { throw failure("解压超过大小上限") }
                result.append(contentsOf: chunk.prefix(count))
                if code == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw failure("gzip 尾部含未知数据") }
                    return result
                }
                guard code == Z_OK, count > 0 else { throw failure("gzip 损坏或不完整") }
            }
        }
    }

    static func unpack(_ data: Data) throws -> [Entry] {
        var entries: [Entry] = []
        var seen = Set<String>()
        var offset = 0
        while offset + 512 <= data.count {
            let header = Data(data[offset..<(offset + 512)])
            if header.allSatisfy({ $0 == 0 }) {
                guard data[offset...].allSatisfy({ $0 == 0 }) else { throw failure("tar 尾部有未知记录") }
                return entries
            }
            func field(_ start: Int, _ length: Int) -> String {
                String(decoding: header[start..<(start + length)].prefix { $0 != 0 }, as: UTF8.self)
            }
            guard let size = Int(field(124, 12).trimmingCharacters(in: .whitespaces), radix: 8),
                let checksum = Int(field(148, 8).trimmingCharacters(in: .whitespaces), radix: 8),
                size >= 0, size <= maximumBytes, offset + 512 + size <= data.count
            else { throw failure("tar 长度无效") }
            let actual = header.enumerated().reduce(0) { $0 + ((148..<156).contains($1.offset) ? 32 : Int($1.element)) }
            guard actual == checksum else { throw failure("tar 头校验和错误") }
            let prefix = field(345, 155)
            let path = (prefix.isEmpty ? "" : prefix + "/") + field(0, 100)
            let name = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
            guard !name.isEmpty, !name.hasPrefix("/"), !name.split(separator: "/").contains(".."),
                seen.insert(name).inserted, [0, 48, 50, 53].contains(header[156])
            else { throw failure("含重复、越界或未支持的 tar 记录") }
            var entry = try Entry(name: name, content: Data(data[(offset + 512)..<(offset + 512 + size)]))
            entry.header = header
            entries.append(entry)
            offset += 512 + ((size + 511) / 512) * 512
        }
        throw failure("缺少 tar 结束记录")
    }

    static func pack(_ entries: [Entry]) -> Data {
        entries.reduce(into: Data()) { $0.append($1.encoded()) } + Data(repeating: 0, count: 1024)
    }

    static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func replaceStartup(in encrypted: Data, password: String, transform: (String) throws -> String) throws -> Data {
        let plain = try crypt(encrypted, password: password, encrypt: false)
        var outer = try unpack(gzip(plain, compress: false))
        guard let innerIndex = outer.firstIndex(where: { $0.name == innerPath }),
            let digestIndex = outer.firstIndex(where: { $0.name == digestPath }),
            String(decoding: outer[digestIndex].content, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                == md5(outer[innerIndex].content)
        else { throw failure("内层摘要不一致") }
        var inner = try unpack(gzip(outer[innerIndex].content, compress: false))
        guard let startupIndex = inner.firstIndex(where: { $0.name == startupPath }),
            [0, 48].contains(inner[startupIndex].header[156]),
            let original = String(data: inner[startupIndex].content, encoding: .utf8)
        else { throw failure("缺少可编辑的 rc.local") }
        inner[startupIndex].content = Data(try transform(original).utf8)
        outer[innerIndex].content = try gzip(pack(inner), compress: true)
        outer[digestIndex].content = Data((md5(outer[innerIndex].content) + "\n").utf8)
        let updated = try gzip(pack(outer), compress: true)
        let result = try crypt(updated, password: password, encrypt: true)
        guard try crypt(result, password: password, encrypt: false) == updated else { throw failure("加解密往返不一致") }
        return result
    }
}
