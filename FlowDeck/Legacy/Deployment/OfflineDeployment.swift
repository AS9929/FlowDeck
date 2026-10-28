import Foundation

/// 历史首次部署的固定资源清单；公开管理客户端不分发此载荷，缺失时拒绝安装。
struct OfflineArtifact: Codable, Sendable {
    let name: String
    let resource: String
    let sha256: String
    let archiveSHA256: String
    let size: Int
    let compressedSize: Int

    static func bundled() throws -> [Self] {
        guard let url = Bundle.main.url(forResource: "OfflineDeploymentManifest", withExtension: "json") else {
            throw ManagementError.invalid("此版本只管理已部署设备，不提供离线首次安装资源。")
        }
        let files = try JSONDecoder().decode([Self].self, from: Data(contentsOf: url))
        let expected: Set<String> = [
            "mihomo", "mm.sh", "GeoSite.dat", "geoip.metadb", "ASN.mmdb", "chnroute.txt", "chnroute6.txt", "data_version.txt", "mihomo_version.txt",
        ]
        guard Set(files.map(\.name)) == expected, files.count == expected.count,
            files.allSatisfy({
                $0.sha256.count == 64 && $0.sha256.allSatisfy(\.isHexDigit)
                    && $0.archiveSHA256.count == 64 && $0.archiveSHA256.allSatisfy(\.isHexDigit)
                    && $0.resource == "Offline-" + $0.name + ".gz" && $0.size > 0 && $0.compressedSize > 0
            })
        else { throw ManagementError.invalid("离线资源清单不完整。") }
        return files
    }

    func data() throws -> Data {
        guard let url = Bundle.main.url(forResource: resource, withExtension: nil) else {
            throw ManagementError.invalid("缺少离线文件：" + name)
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == compressedSize, DeviceIdentity.digest(data) == archiveSHA256 else {
            throw ManagementError.invalid("离线文件校验失败：" + name)
        }
        return data
    }
}

/// 将资源读取与传输状态机分离。生产读取 Bundle 中经过摘要校验的资源；
/// 测试注入自行生成的微型数据，不需要再分发第三方核心或数据库。
struct OfflineDeploymentResources: Sendable {
    let files: [OfflineArtifact]
    let read: @Sendable (OfflineArtifact) throws -> Data

    static func bundled() throws -> Self {
        Self(files: try OfflineArtifact.bundled(), read: { try $0.data() })
    }
}

/// 使用现有 root file.exec 通道分块传输，不开启临时 HTTP 服务，也不依赖额外 SSH 密码。
/// 写入私人暂存目录，校验压缩包和解压文件后再提交；断线后按字节偏移续传，不重复追加。
enum OfflineDeployment {
    static let chunkSize = 36 * 1024

    @MainActor
    static func install(
        api: any WebSSHAPI, id: UUID, resources: OfflineDeploymentResources,
        authorize: () async throws -> Void,
        progress: (String, Double) -> Void
    ) async throws {
        let files = resources.files
        let directory = "/data/kano_plugins/mihomo"
        let staging = directory + "/.flowdeck-" + id.uuidString.lowercased()
        try await authorize()
        _ = try await api.runMaintenanceScript(
            """
            set -eu
            umask 077
            for tool in base64 gzip sha256sum wc cat mv; do command -v "$tool" >/dev/null; done
            test ! -L '\(directory)'
            test ! -L '\(staging)'
            mkdir -p '\(staging)'
            """)
        let total = files.reduce(0) { $0 + $1.compressedSize }
        var transferred = 0
        for file in files {
            try await authorize()
            // 大文件摘要计算不占用主线程；仅映射当前文件，不一次载入全部资源。
            let data = try await Task.detached(priority: .utility) { try resources.read(file) }.value
            let path = staging + "/" + file.name + ".gz"
            let offsetText = try await api.runMaintenanceScript(
                """
                set -eu
                test ! -L '\(path)'
                if test -f '\(path)'; then wc -c < '\(path)'; else echo 0; fi
                """)
            guard let offset = Int(offsetText.trimmingCharacters(in: .whitespacesAndNewlines)), (0...data.count).contains(offset) else {
                throw ManagementError.unconfirmed("暂存文件长度异常，未继续写入：" + file.name)
            }
            var position = offset
            while position < data.count {
                try Task.checkCancellation()
                let end = min(position + chunkSize, data.count)
                let payload = data.subdata(in: position..<end).base64EncodedString()
                _ = try await api.runMaintenanceScript(chunkScript(path: path, offset: position, payload: payload))
                position = end
                progress("传输 " + file.name, Double(transferred + position) / Double(total))
            }
            // 不自动重传完整文件；摘要不符明确失败，避免损坏的暂存被当成安装成功。
            // 解压和摘要可能超过 WebSSH 单次 ubus 调用的 5 秒上限，改为后台执行后轮询结果。
            progress("校验 " + file.name, Double(transferred + data.count) / Double(total))
            _ = try await api.runBackgroundScript(
                directory: staging, name: "verify-" + file.name, title: "校验 " + file.name,
                script: """
                    set -eu
                    cd '\(staging)'
                    echo '\(file.archiveSHA256)  \(file.name).gz' | sha256sum -c - >/dev/null
                    test ! -L '\(file.name).ready'
                    gzip -dc '\(file.name).gz' > '\(file.name).ready'
                    echo '\(file.sha256)  \(file.name).ready' | sha256sum -c - >/dev/null
                    """)
            transferred += data.count
        }
        try await authorize()
        // 调用方验证配置未变、服务未运行后才提交。未全部提交时不会运行核心或设置自启动。
        let commands = files.map { "mv '\(staging)/\($0.name).ready' '\(directory)/\($0.name)'" }.joined(separator: "\n")
        _ = try await api.runMaintenanceScript(
            """
            set -eu
            \(commands)
            chmod 700 '\(directory)/mihomo' '\(directory)/mm.sh'
            """)
        progress("离线资源已安装并校验", 1)
    }

    /// 后台任务的状态目录，用于安装后的核心摘要复核。
    static let jobDirectory = "/data/kano_plugins/mihomo/.flowdeck-jobs"

    /// 启用成功后清理暂存与后台任务文件，释放约 35 MB 空间；失败时保留，便于续传与排查。
    static let cleanupScript = "rm -rf /data/kano_plugins/mihomo/.flowdeck-*"

    /// 固定路径由内部清单生成；偏移校验阻止断线响应丢失后重复追加同一块。
    static func chunkScript(path: String, offset: Int, payload: String) -> String {
        """
        set -eu
        umask 077
        test ! -L '\(path)'
        count=0
        if test -f '\(path)'; then count=$(wc -c < '\(path)'); fi
        test "$count" -eq \(offset)
        printf '%s' '\(payload)' | base64 -d >> '\(path)'
        """
    }
}
