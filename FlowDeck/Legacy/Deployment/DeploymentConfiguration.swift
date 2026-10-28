import Foundation

/// 首次安装使用已适配 B28 透明代理脚本的网络骨架，只从用户 YAML 引入策略相关段落。
/// 不覆盖现有设备配置；最终是否可用由设备上的 Mihomo -t 和控制接口回读判断。
enum DeploymentConfiguration {
    static func make(source: String, host: String, secret: String) throws -> String {
        guard !source.isEmpty, source.utf8.count <= 8 * 1024 * 1024,
            host.split(separator: ".", omittingEmptySubsequences: false).count == 4,
            host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ Int($0).map { (0...255).contains($0) } == true }),
            secret.count >= 24, secret.allSatisfy(\.isHexDigit)
        else { throw ManagementError.invalid("配置、局域网 IPv4 地址或控制密钥无效。") }
        let blocks = SurgeConverter.topLevelBlocks(source)
        let allowed: Set<String> = ["proxies", "proxy-groups", "proxy-providers", "rules", "rule-providers"]
        let selected = blocks.filter { allowed.contains($0.key) }
        guard Set(selected.map(\.key)).count == selected.count,
            selected.contains(where: { $0.key == "proxies" || $0.key == "proxy-providers" }),
            selected.contains(where: { $0.key == "rules" })
        else { throw ManagementError.invalid("请选择含节点或订阅及分流规则的 Mihomo YAML；不支持重复顶层键。") }
        let local = localProviders(in: selected)
        guard local.isEmpty else {
            throw ManagementError.invalid(
                "以下规则集或订阅依赖设备上的本地文件，首次部署无法一并上传：" + local.joined(separator: "、")
                    + "。请改用在线规则版本，或直接导入 Surge 配置由 App 转换。")
        }
        return """
            port: 7890
            socks-port: 7891
            redir-port: 7892
            mixed-port: 7893
            allow-lan: true
            bind-address: '*'
            mode: rule
            log-level: info
            ipv6: false
            external-controller: '\(host):9090'
            secret: '\(secret)'
            geodata-mode: false
            geox-url:
              mmdb: https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb
            dns:
              enable: true
              listen: 0.0.0.0:1053
              ipv6: false
              enhanced-mode: fake-ip
              fake-ip-range: 198.18.0.1/16
              default-nameserver: [223.5.5.5, 119.29.29.29]
              nameserver: [223.5.5.5, 119.29.29.29]
              fake-ip-filter: ['*.lan', '*.local', 'localhost', 'time.*', 'ntp.*']
            tun:
              enable: true
              device: utun
              stack: mixed
              mtu: 1400
              auto-route: false
              auto-redirect: false
              auto-detect-interface: true
            ntp:
              enable: true
              # 已适配设备的启动 NTP 地址，避免时间错误时依赖 DNS/TLS。
              # 地址可在配置编辑器中修改；运营商屏蔽 UDP 123 时需手动校时。
              server: 203.107.6.88
              port: 123
              interval: 1
              dialer-proxy: DIRECT
              write-to-system: false
            \(selected.map(\.text).joined(separator: "\n"))
            """
    }
}

extension DeploymentConfiguration {
    /// 只检查 rule-providers / proxy-providers 中各项的 type 字段，注释和其他段落里的文字不算。
    static func localProviders(in blocks: [SurgeConverter.Block]) -> [String] {
        var names: [String] = []
        for block in blocks where block.key == "rule-providers" || block.key == "proxy-providers" {
            var current: String?
            var itemIndent: Int?
            for line in block.text.components(separatedBy: "\n").dropFirst() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                let indent = line.prefix { $0 == " " }.count
                if itemIndent == nil { itemIndent = indent }
                if indent == itemIndent, let colon = trimmed.firstIndex(of: ":") {
                    let name = String(trimmed[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
                    current = name
                    // 行内写法：local: {type: file, path: ./x.yaml}
                    let inline = trimmed[trimmed.index(after: colon)...].replacingOccurrences(of: " ", with: "")
                    if inline.hasPrefix("{"), ["type:file", "type:'file'", "type:\"file\""].contains(where: inline.contains),
                        !names.contains(name)
                    {
                        names.append(name)
                    }
                    continue
                }
                let body = trimmed.split(separator: "#", maxSplits: 1).first.map(String.init) ?? trimmed
                let parts = body.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, parts[0] == "type",
                    parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) == "file",
                    let current, !names.contains(current)
                {
                    names.append(current)
                }
            }
        }
        return names
    }

    /// Surge 配置在本机转换为节点、策略组、在线规则集和规则四段，再交给 make 套用设备网络骨架。
    /// 新设备上没有本地兼容副本，规则集全部按在线地址生成；Mihomo 会跳过不支持的单行规则并记录日志。
    static func fromSurge(_ text: String) throws -> (yaml: String, summary: String) {
        let result = try SurgeConverter.convert(text)
        guard result.groups.contains(where: { $0.name == "Proxies" }) else {
            throw ManagementError.invalid("Surge 配置缺少 Proxies 策略组，在线规则集需要它作为下载出口。")
        }
        let blocks = SurgeConverter.yamlBlocks(result, fileProviders: [:])
        let yaml = ["proxies", "proxy-groups", "rule-providers", "rules"].compactMap { blocks[$0] }.joined()
        var summary = "Surge 转换：\(result.proxies.count) 个节点 · \(result.groups.count) 个策略组 · \(result.providers.count) 个在线规则集"
        if !result.ignoredRules.isEmpty { summary += " · 忽略 \(result.ignoredRules.count) 条非规则集规则" }
        return (yaml, summary)
    }

    static func looksLikeSurge(_ text: String) -> Bool {
        let sections = SurgeConverter.sections(text)
        return sections["proxy"] != nil && sections["rule"] != nil
    }
}

/// 首次写入以完整原厂固件版本和硬件摘要为边界。IMEI 只保留在本次内存中。
struct FactoryDeploymentIdentity: Equatable, Sendable {
    let imei: String
    let firmware: String
    let fingerprint: String
}

/// 持久化只保存恢复位置和状态，不保存密码、IMEI、配置或未脱敏的服务端输出。
struct DeploymentCheckpoint: Codable {
    var fingerprint: String
    var phase: String
    var host: String
    var updatedAt = Date()
    var configDigest: String?
    var originalDigest: String?
    var preparedDigest: String?
}

enum DeploymentFiles {
    static func directory(_ id: UUID) throws -> URL {
        var url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Deployment", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return url
    }

    static func write(_ data: Data, name: String, id: UUID) throws -> URL {
        let url = try directory(id).appendingPathComponent(name)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    static func checkpoint(_ value: DeploymentCheckpoint, id: UUID) throws {
        _ = try write(JSONEncoder().encode(value), name: "progress.json", id: id)
    }

    static func load(_ id: UUID) -> DeploymentCheckpoint? {
        guard let folder = try? directory(id), let data = try? Data(contentsOf: folder.appendingPathComponent("progress.json")) else { return nil }
        return try? JSONDecoder().decode(DeploymentCheckpoint.self, from: data)
    }
}
