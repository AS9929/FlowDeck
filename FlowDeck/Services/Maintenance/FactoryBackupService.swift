import Foundation

/// WebSSH 原厂备份用例：下载后与设备文件摘要比对，再生成本机受保护的导出文件。
struct FactoryBackupService {
    struct Result {
        let url: URL
        let checksum: String
    }

    let api: any WebSSHAPI
    let profile: DeviceProfile?
    let password: String
    let demo: Bool

    func run() async throws -> Result {
        let data: Data
        if demo {
            data = Data("DEMO ONLY — this is not a restorable device backup".utf8)
        } else {
            guard let profile else { throw ManagementError.deviceChanged }
            let factory = try FactoryClient(host: profile.host, password: password)
            data = try await factory.backup()
            let remote = try await api.runMaintenanceScript("sha256sum /tmp/back_parameter")
                .split(whereSeparator: \.isWhitespace).first.map(String.init)
            guard remote == DeviceIdentity.digest(data) else {
                throw ManagementError.unconfirmed("下载备份与设备原文件的 SHA256 不一致，未提供导出文件。")
            }
        }
        let name = demo ? "U60-DEMO-not-restorable.txt" : "U60-back_parameter-\(Int(Date().timeIntervalSince1970)).bin"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return Result(url: url, checksum: DeviceIdentity.digest(data))
    }
}
