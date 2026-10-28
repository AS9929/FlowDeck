import Foundation

/// 仅传输公开软件包，不传凭据、YAML 或用户备份。按摘要寻址，断线后按已确认长度续传。
/// 设备和手机都核对 SHA-256；部分包不会交给安装事务。
enum UFIPackageTransfer {
    static let maximumBytes = 120 * 1024 * 1024
    static let directory = "/data/local/flowdeck-packages"

    static func path(checksum: String) throws -> String {
        guard checksum.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw ManagementError.invalid("软件包摘要无效。")
        }
        return directory + "/" + checksum
    }

    static func send(
        data: Data, checksum: String,
        command: @Sendable (String) async throws -> String,
        progress: @Sendable (Double) async -> Void
    ) async throws -> String {
        guard !data.isEmpty, data.count <= maximumBytes, DeviceIdentity.digest(data) == checksum else {
            throw ManagementError.invalid("软件包大小或 SHA-256 不匹配。")
        }
        let file = try path(checksum: checksum)
        let partial = file + ".part"
        let probe = try await command("umask 077; mkdir -p \(directory); chmod 700 \(directory); sha256sum \(file) 2>/dev/null")
        if probe.split(whereSeparator: \.isWhitespace).first == Substring(checksum) {
            await progress(1)
            return file
        }
        let size = try await command("if test -f \(partial); then stat -c %s \(partial); else echo 0; fi")
        guard var offset = Int(size.trimmingCharacters(in: .whitespacesAndNewlines)), (0...data.count).contains(offset) else {
            throw ManagementError.unconfirmed("设备上的软件包暂存状态异常，请清理该包后重试。")
        }
        // Android 单个 shell 参数上限约 128 KiB，Base64 扩张后也必须留出脚本空间。
        let chunkSize = 48 * 1024
        while offset < data.count {
            try Task.checkCancellation()
            let end = min(offset + chunkSize, data.count)
            let encoded = data[offset..<end].base64EncodedString()
            // 追加前再检查长度；同一包并发上传会失败关闭，不产生静默错位。
            let output = try await command(
                """
                umask 077
                test -f \(partial) || touch \(partial)
                if test "$(stat -c %s \(partial))" = \(offset); then
                    printf '%s' '\(encoded)' | base64 -d >> \(partial)
                    stat -c %s \(partial)
                fi
                """)
            guard Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) == end else {
                throw ManagementError.unconfirmed("传输中断，未启动安装。重新选择同一软件包可续传。")
            }
            offset = end
            await progress(Double(offset) / Double(data.count))
        }
        let result = try await command(
            """
            if test "$(sha256sum \(partial) | cut -d ' ' -f1)" = '\(checksum)'; then
                chmod 600 \(partial) && mv \(partial) \(file) && echo verified
            else
                rm -f \(partial)
                echo invalid
            fi
            """)
        guard result.trimmingCharacters(in: .whitespacesAndNewlines) == "verified" else {
            throw ManagementError.unconfirmed("设备校验失败，未启动安装；损坏的暂存包已清理。")
        }
        return file
    }
}

/// 官方发布信息仅由 GitHub 接口写入本机缓存；导入包必须匹配这份可信摘要。
enum UFICorePackageCache {
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VerifiedCorePackages", isDirectory: true)
    }

    static func remember(_ release: UFICoreRelease) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(release).write(to: directory.appendingPathComponent("official.json"), options: .atomic)
    }

    static func remembered() -> UFICoreRelease? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("official.json")) else { return nil }
        return try? JSONDecoder().decode(UFICoreRelease.self, from: data)
    }

    static func file(_ release: UFICoreRelease) -> URL {
        directory.appendingPathComponent(release.url.lastPathComponent)
    }

    static func validatedData(_ url: URL, release: UFICoreRelease) throws -> Data {
        guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == release.size else {
            throw ManagementError.invalid("文件大小与官方发布信息不符。")
        }
        let data = try Data(contentsOf: url)
        guard DeviceIdentity.digest(data) == release.checksum else {
            throw ManagementError.invalid("文件 SHA-256 与官方发布信息不符。")
        }
        return data
    }

    static func store(_ url: URL, release: UFICoreRelease) throws -> URL {
        let data = try validatedData(url, release: release)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file(release), options: .atomic)
        return file(release)
    }

    static func download(_ release: UFICoreRelease) async throws -> URL {
        var request = URLRequest(url: release.url)
        request.timeoutInterval = 180
        let (temporary, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ManagementError.unconfirmed("手机未能下载官方内核，请稍后重试或导入同版本文件。")
        }
        return try store(temporary, release: release)
    }
}
