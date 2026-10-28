import Foundation

/// Mihomo `GET /proxies` 返回的单个代理或策略组。
struct MihomoProxy: Decodable, Hashable, Sendable {
    let name: String
    let type: String
    let now: String?
    let all: [String]?
    let history: [DelayRecord]
    let hidden: Bool
    let icon: String?

    struct DelayRecord: Decodable, Hashable, Sendable {
        let time: String?
        let delay: Int
    }

    private enum CodingKeys: String, CodingKey {
        case name, type, now, all, history, hidden, icon
    }

    init(
        name: String, type: String, now: String? = nil, all: [String]? = nil,
        history: [DelayRecord] = [], hidden: Bool = false, icon: String? = nil
    ) {
        self.name = name
        self.type = type
        self.now = now
        self.all = all
        self.history = history
        self.hidden = hidden
        self.icon = icon
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(String.self, forKey: .type)
        now = try c.decodeIfPresent(String.self, forKey: .now)
        all = try c.decodeIfPresent([String].self, forKey: .all)
        history = (try? c.decodeIfPresent([DelayRecord].self, forKey: .history)) ?? []
        hidden = (try? c.decodeIfPresent(Bool.self, forKey: .hidden)) ?? false
        let rawIcon = try c.decodeIfPresent(String.self, forKey: .icon)
        icon = (rawIcon?.isEmpty ?? true) ? nil : rawIcon
    }

    static let groupTypes: Set<String> = ["Selector", "URLTest", "Fallback", "LoadBalance", "Relay"]

    var isGroup: Bool { Self.groupTypes.contains(type) }
    /// 只有 select 类型的组允许手动指定。
    var isSelectable: Bool { type == "Selector" }
    var isBuiltin: Bool { ["Direct", "Reject", "RejectDrop", "Pass", "Compatible"].contains(type) }

    /// 最近一次测速结果；0 表示超时，nil 表示从未测过。
    var lastDelay: Int? { history.last?.delay }

    var typeLabel: String {
        switch type {
        case "Selector": return "select"
        case "URLTest": return "url-test"
        case "Fallback": return "fallback"
        case "LoadBalance": return "load-balance"
        default: return type.lowercased()
        }
    }
}

struct ProxiesResponse: Decodable {
    let proxies: [String: MihomoProxy]
}

enum OutboundMode: String, CaseIterable, Identifiable, Sendable {
    case direct, global, rule

    var id: String { rawValue }

    /// 菜单、运行设置与状态摘要统一使用同一组图标。
    var symbol: String {
        switch self {
        case .direct: return "arrow.up.right"
        case .global: return "globe"
        case .rule: return "arrow.triangle.branch"
        }
    }

    var title: String {
        switch self {
        case .direct: return "直接连接"
        case .global: return "全局代理"
        case .rule: return "规则判定"
        }
    }
}

struct MihomoConfig: Decodable, Sendable {
    let mode: OutboundMode

    private enum CodingKeys: String, CodingKey { case mode }

    init(mode: OutboundMode) { self.mode = mode }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .mode).lowercased()
        mode = OutboundMode(rawValue: raw) ?? .rule
    }
}

struct VersionResponse: Decodable, Sendable {
    let version: String
    let meta: Bool?
}

struct DelayResponse: Decodable {
    let delay: Int
}

struct MihomoRule: Decodable, Identifiable, Hashable, Sendable {
    var id: Int = 0
    let type: String
    let payload: String
    let proxy: String

    private enum CodingKeys: String, CodingKey { case type, payload, proxy }

    init(id: Int, type: String, payload: String, proxy: String) {
        self.id = id
        self.type = type
        self.payload = payload
        self.proxy = proxy
    }
}

struct RulesResponse: Decodable {
    let rules: [MihomoRule]
}

struct MihomoConnection: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let metadata: Metadata
    let upload: Int
    let download: Int
    let start: String?
    let chains: [String]
    let rule: String
    let rulePayload: String

    struct Metadata: Decodable, Hashable, Sendable {
        let network: String
        let sourceIP: String
        let destinationIP: String
        let destinationPort: String
        let host: String

        private enum CodingKeys: String, CodingKey {
            case network, sourceIP, destinationIP, destinationPort, host
        }

        init(network: String, sourceIP: String, destinationIP: String, destinationPort: String, host: String) {
            self.network = network
            self.sourceIP = sourceIP
            self.destinationIP = destinationIP
            self.destinationPort = destinationPort
            self.host = host
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            network = (try? c.decodeIfPresent(String.self, forKey: .network)) ?? ""
            sourceIP = (try? c.decodeIfPresent(String.self, forKey: .sourceIP)) ?? ""
            destinationIP = (try? c.decodeIfPresent(String.self, forKey: .destinationIP)) ?? ""
            host = (try? c.decodeIfPresent(String.self, forKey: .host)) ?? ""
            // 不同版本的 Mihomo 端口字段可能是字符串或数字。
            if let s = try? c.decodeIfPresent(String.self, forKey: .destinationPort) {
                destinationPort = s
            } else if let n = try? c.decodeIfPresent(Int.self, forKey: .destinationPort) {
                destinationPort = String(n)
            } else {
                destinationPort = ""
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, metadata, upload, download, start, chains, rule, rulePayload
    }

    init(
        id: String, metadata: Metadata, upload: Int, download: Int, start: String?,
        chains: [String], rule: String, rulePayload: String
    ) {
        self.id = id
        self.metadata = metadata
        self.upload = upload
        self.download = download
        self.start = start
        self.chains = chains
        self.rule = rule
        self.rulePayload = rulePayload
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        metadata = try c.decode(Metadata.self, forKey: .metadata)
        upload = (try? c.decodeIfPresent(Int.self, forKey: .upload)) ?? 0
        download = (try? c.decodeIfPresent(Int.self, forKey: .download)) ?? 0
        start = try? c.decodeIfPresent(String.self, forKey: .start)
        chains = (try? c.decodeIfPresent([String].self, forKey: .chains)) ?? []
        rule = (try? c.decodeIfPresent(String.self, forKey: .rule)) ?? ""
        rulePayload = (try? c.decodeIfPresent(String.self, forKey: .rulePayload)) ?? ""
    }

    enum Kind { case proxy, direct, reject }

    /// chains 的第一个元素是最终出口，最后一个是命中的策略组。
    var kind: Kind {
        switch chains.first {
        case "DIRECT": return .direct
        case "REJECT", "REJECT-DROP": return .reject
        default: return .proxy
        }
    }

    var target: String {
        let h = metadata.host.isEmpty ? metadata.destinationIP : metadata.host
        return metadata.destinationPort.isEmpty ? h : "\(h):\(metadata.destinationPort)"
    }

    /// 按“策略组 → … → 节点”的顺序展示。
    var chainText: String { chains.reversed().joined(separator: " → ") }
}

struct ConnectionsResponse: Decodable, Sendable {
    let downloadTotal: Int
    let uploadTotal: Int
    let connections: [MihomoConnection]

    private enum CodingKeys: String, CodingKey { case downloadTotal, uploadTotal, connections }

    init(downloadTotal: Int, uploadTotal: Int, connections: [MihomoConnection]) {
        self.downloadTotal = downloadTotal
        self.uploadTotal = uploadTotal
        self.connections = connections
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        downloadTotal = (try? c.decodeIfPresent(Int.self, forKey: .downloadTotal)) ?? 0
        uploadTotal = (try? c.decodeIfPresent(Int.self, forKey: .uploadTotal)) ?? 0
        connections = (try? c.decodeIfPresent([MihomoConnection].self, forKey: .connections)) ?? []
    }
}

/// `GET /traffic` 流里的一行：每秒的上下行字节数。
struct TrafficSample: Decodable, Sendable {
    let up: Int
    let down: Int
}
