import Foundation

/// 演示数据：结构按部署配置还原（Proxies、6 个地区组、14 个应用组、自动选择），
/// 节点名与延迟为示例。没连设备时用它预览界面，所有修改只改内存。
actor DemoMihomo: MihomoAPI {
    static let shared = DemoMihomo()

    private var store: [String: MihomoProxy] = [:]
    private var mode: OutboundMode = .rule
    private var conns: [MihomoConnection] = []
    private var order: [String] = []
    private var runtime: [String: Any] = [
        "log-level": "info", "ipv6": false, "sniffing": true, "tcp-concurrent": true,
        "mixed-port": 7890, "allow-lan": true, "tun": ["enable": true, "stack": "mixed"],
    ]
    private var providerUpdatedAt = "2026-10-04T00:00:00Z"

    func runtimeSettings() -> JSONObject { JSONObject(runtime) }

    func patchRuntime(_ change: RuntimeChange) throws {
        runtime.merge(try change.payload().raw) { _, new in new }
    }

    /// 与实际设备一致：节点直接写在配置里时，Mihomo 只返回每个策略组的 Compatible 内部集合；规则集有在线与本地两类。
    func providers(_ kind: ProviderKind) -> [MihomoProvider] {
        if kind == .proxies {
            return [("日本", 35), ("美国", 22), ("韩国", 5)].map {
                MihomoProvider(name: $0.0, kind: .proxies, vehicle: "Compatible", count: $0.1, updatedAt: "0001-01-01T00:00:00Z")
            }
        }
        return [
            ("Claude", "HTTP", 186), ("Chatgpt", "HTTP", 92), ("Youtube", "HTTP", 1_204), ("AdBlock", "File", 48_310),
            ("Apple", "HTTP", 3_377), ("direct", "File", 21_806),
        ].map { MihomoProvider(name: $0.0, kind: .rules, vehicle: $0.1, count: $0.2, updatedAt: providerUpdatedAt) }
    }

    func updateProvider(_ name: String, kind: ProviderKind) {
        providerUpdatedAt = ISO8601DateFormatter().string(from: Date())
    }

    func flushCache(_ kind: ProxyCacheKind) async throws {
        try await Task.sleep(for: .milliseconds(180))
    }

    func healthCheckProvider(_ name: String) async throws {
        try await Task.sleep(for: .milliseconds(400))
    }

    func queryDNS(_ name: String, type: String) -> JSONObject {
        let examples: [String: (Int, String)] = [
            "A": (1, "192.0.2.1"), "AAAA": (28, "2001:db8::1"), "CNAME": (5, "alias.example.com."),
            "MX": (15, "10 mail.example.com."), "TXT": (16, "演示记录"), "NS": (2, "ns.example.com."),
            "HTTPS": (65, "1 . alpn=h2"),
        ]
        let record = examples[type] ?? (1, "192.0.2.1")
        return JSONObject(["Status": 0, "Answer": [["name": name, "type": record.0, "TTL": 60, "data": record.1]]])
    }

    nonisolated func logs(level: String) -> AsyncThrowingStream<MihomoLog, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    while !Task.isCancelled {
                        continuation.yield(MihomoLog(type: level, payload: "[演示] TCP example.com:443 matched 旅行节点"))
                        try await Task.sleep(for: .seconds(2))
                    }
                    continuation.finish()
                } catch { continuation.finish() }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    init() {
        let (store, order) = Self.build()
        self.store = store
        self.order = order
        self.conns = Self.sampleConnections()
    }

    // MARK: 构造

    private static let regionSpecs: [(name: String, flag: String, lines: [String], bases: [String], count: Int)] = [
        (
            "美国", "🇺🇸", ["华为沪日", "MKCloud沪日", "MKCloud沪日②", "华为沪日②"], ["GreenCloud ⚡", "OVH West", "OVH East", "OVH Seattle", "Breezehost 🖥️ ⚡", "Spartan 🖥️ ⚡"],
            22
        ),
        (
            "香港", "🇭🇰", ["华为广港", "MKCloud沪港", "MKCloud沪港②", "MKCloud沪港③"],
            ["腾讯HK", "DMIT HK Pro ★", "Gomami Turin ★ ⚡", "Hytron-01", "Hytron-02", "MEJIRO HK 🖥️", "MEJIRO HK2 🖥️ ⚡", "HK 备用", "HK 直连 2", "HK 直连 3", "HK 中转"], 44
        ),
        (
            "日本", "🇯🇵", ["华为沪日", "MKCloud沪日", "MKCloud沪日②", "华为沪日②"],
            ["IDCF 东一", "IDCF 东三", "IDCF Osaka", "Ablenet-01", "Ablenet-02", "RFC JP① ★", "RFC JP② ★", "Sharon ★", "Oracle 1C"], 35
        ),
        ("台湾", "🍠", ["华为广港", "MKCloud沪港", "MKCloud沪港②", "MKCloud沪港③"], ["PQS TW", "TW 备用"], 7),
        ("韩国", "🇰🇷", ["华为广港", "MKCloud沪港", "MKCloud沪港②", "MKCloud沪港③"], ["Moack 🖥️", "KR 备用"], 5),
        ("欧洲", "🇪🇺", ["华为广港", "MKCloud沪港", "MKCloud沪港②", "MKCloud沪港③"], ["AlphaVPS", "Frantech", "EU 备用"], 10),
    ]

    private static let appSpecs: [(String, [String], String)] = [
        ("Apple", ["DIRECT", "Proxies", "美国", "香港", "日本", "台湾", "韩国", "欧洲"], "DIRECT"),
        ("Claude", ["Proxies", "美国", "香港", "日本", "台湾", "韩国", "欧洲"], "日本"),
        ("Chatgpt", ["Proxies", "美国", "香港", "日本", "台湾", "韩国", "欧洲"], "美国"),
        ("Gemini", ["Proxies", "美国", "香港", "日本", "台湾", "韩国", "欧洲"], "美国"),
        ("Youtube", ["Proxies", "美国", "香港", "日本", "台湾", "韩国", "欧洲"], "Proxies"),
        ("Netflix", ["Proxies", "美国", "香港", "日本", "台湾", "韩国", "欧洲"], "Proxies"),
        ("Bahamut", ["Proxies", "美国", "香港", "日本", "台湾"], "台湾"),
        ("TruthSocial", ["Proxies", "美国", "日本"], "美国"),
        ("Whatsapp", ["Proxies", "美国", "香港", "日本", "台湾", "韩国", "欧洲"], "Proxies"),
        ("Twitter", ["Proxies", "美国", "香港", "日本", "韩国", "欧洲"], "Proxies"),
        ("Telegram", ["Proxies", "美国", "香港", "日本", "台湾", "韩国", "欧洲"], "Proxies"),
        ("CN", ["DIRECT"], "DIRECT"),
        ("AdBlock", ["REJECT", "Proxies", "DIRECT"], "REJECT"),
        ("Final", ["Proxies", "DIRECT"], "Proxies"),
    ]

    private static func build() -> ([String: MihomoProxy], [String]) {
        var store: [String: MihomoProxy] = [:]
        var seed: UInt64 = 7
        func rnd() -> Double {
            seed = (seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407)
            return Double(seed >> 33) / Double(1 << 31)
        }
        let baseDelay: [String: Double] = ["美国": 150, "香港": 32, "日本": 48, "台湾": 55, "韩国": 70, "欧洲": 220]
        var regionNodes: [String: [String]] = [:]
        var allNodes: [String] = []
        for spec in regionSpecs {
            var names: [String] = []
            outer: for line in spec.lines {
                for base in spec.bases {
                    if names.count == spec.count { break outer }
                    let name = "\(spec.flag) [\(line)] | \(base)"
                    let b = baseDelay[spec.name] ?? 100
                    let delay = rnd() < 0.08 ? 0 : Int(b + rnd() * b * 0.9)
                    store[name] = MihomoProxy(name: name, type: "Shadowsocks", history: [.init(time: nil, delay: delay)])
                    names.append(name)
                }
            }
            regionNodes[spec.name] = names
            allNodes += names
        }
        store["DIRECT"] = MihomoProxy(name: "DIRECT", type: "Direct")
        store["REJECT"] = MihomoProxy(name: "REJECT", type: "Reject")

        let fastest = allNodes.min { (store[$0]?.lastDelay ?? 9999).nonZero < (store[$1]?.lastDelay ?? 9999).nonZero } ?? allNodes[0]
        store["自动选择"] = MihomoProxy(
            name: "自动选择", type: "URLTest", now: fastest, all: allNodes,
            history: store[fastest]?.history ?? [])
        store["Proxies"] = MihomoProxy(name: "Proxies", type: "Selector", now: regionNodes["日本"]![0], all: ["自动选择"] + allNodes)
        for spec in regionSpecs {
            let nodes = regionNodes[spec.name]!
            let now = spec.name == "香港" ? nodes[1] : nodes[0]
            store[spec.name] = MihomoProxy(name: spec.name, type: "Selector", now: now, all: nodes)
        }
        for (name, opts, now) in appSpecs {
            store[name] = MihomoProxy(name: name, type: "Selector", now: now, all: opts)
        }
        // GLOBAL 的 all 按配置顺序列出所有组和节点，App 用它决定策略组的显示顺序。
        let groupOrder = ["Proxies", "自动选择"] + regionSpecs.map(\.name) + appSpecs.map(\.0)
        store["GLOBAL"] = MihomoProxy(
            name: "GLOBAL", type: "Selector", now: "Proxies",
            all: ["DIRECT", "REJECT"] + groupOrder + allNodes)
        return (store, groupOrder)
    }

    private static func sampleConnections() -> [MihomoConnection] {
        func c(_ id: String, _ host: String, _ port: String, _ net: String, _ src: String, _ chains: [String], _ rule: String, _ payload: String, _ down: Int)
            -> MihomoConnection
        {
            MihomoConnection(
                id: id, metadata: .init(network: net, sourceIP: src, destinationIP: "198.18.0.\(id.count)", destinationPort: port, host: host),
                upload: down / 12, download: down, start: nil, chains: chains, rule: rule, rulePayload: payload)
        }
        return [
            c("c1", "claude.ai", "443", "tcp", "192.168.0.105", ["🇯🇵 [华为沪日] | IDCF 东一", "日本", "Claude"], "RuleSet", "claude", 219_000),
            c("c2", "chatgpt.com", "443", "tcp", "192.168.0.161", ["🇺🇸 [华为沪日] | OVH West", "美国", "Chatgpt"], "RuleSet", "chatgpt", 90_000),
            c(
                "c3", "rr3---sn-oguesnzz.googlevideo.com", "443", "udp", "192.168.0.118", ["🇯🇵 [华为沪日] | IDCF 东一", "Proxies", "Youtube"], "RuleSet", "youtube",
                40_000_000),
            c("c4", "api.weixin.qq.com", "443", "tcp", "192.168.0.105", ["DIRECT"], "RuleSet", "china", 12_000),
            c("c5", "stats.g.doubleclick.net", "443", "tcp", "192.168.0.105", ["REJECT", "AdBlock"], "RuleSet", "reject", 0),
            c("c6", "gateway.icloud.com", "443", "tcp", "192.168.0.105", ["DIRECT", "Apple"], "RuleSet", "apple", 31_000),
            c("c7", "stun.l.google.com", "19302", "udp", "192.168.0.161", ["🇯🇵 [华为沪日] | IDCF 东一", "Proxies"], "RuleSet", "global", 2_000),
            c("c8", "api.telegram.org", "443", "tcp", "192.168.0.105", ["🇯🇵 [华为沪日] | IDCF 东一", "Proxies", "Telegram"], "RuleSet", "telegram", 6_000),
        ]
    }

    // MARK: MihomoAPI

    func version() async throws -> VersionResponse { VersionResponse(version: "v1.19.32（演示）", meta: true) }

    func proxies() async throws -> [String: MihomoProxy] {
        try await Task.sleep(nanoseconds: 150_000_000)
        return store
    }

    func select(group: String, proxy: String) async throws {
        guard let g = store[group], g.isSelectable, g.all?.contains(proxy) == true else {
            throw MihomoError.notSelectable(group)
        }
        store[group] = MihomoProxy(name: g.name, type: g.type, now: proxy, all: g.all, history: g.history, hidden: g.hidden, icon: g.icon)
    }

    func delay(proxy: String, url: String, timeoutMs: Int) async throws -> Int {
        try await Task.sleep(nanoseconds: 300_000_000)
        let d = retest(proxy)
        return d
    }

    func groupDelay(group: String, url: String, timeoutMs: Int) async throws -> [String: Int] {
        try await Task.sleep(nanoseconds: 700_000_000)
        guard let members = store[group]?.all else { return [:] }
        var out: [String: Int] = [:]
        for m in members where store[m]?.isGroup == false && store[m]?.isBuiltin == false {
            out[m] = retest(m)
        }
        return out
    }

    private func retest(_ name: String) -> Int {
        guard let p = store[name] else { return 0 }
        let old = p.lastDelay ?? 120
        let d = Double.random(in: 0...1) < 0.06 ? 0 : max(20, Int(Double(old == 0 ? 160 : old) * Double.random(in: 0.8...1.2)))
        store[name] = MihomoProxy(name: p.name, type: p.type, now: p.now, all: p.all, history: [.init(time: nil, delay: d)])
        return d
    }

    func config() async throws -> MihomoConfig { MihomoConfig(mode: mode) }

    func setMode(_ mode: OutboundMode) async throws { self.mode = mode }

    func rules() async throws -> [MihomoRule] {
        let raw = [
            "DOMAIN,captive.apple.com,DIRECT", "GeoSite,private,DIRECT", "GeoIP,private,DIRECT", "RuleSet,custom-direct,DIRECT",
            "RuleSet,custom-proxies,Proxies", "RuleSet,custom-japan,日本", "RuleSet,custom-reject,REJECT", "RuleSet,custom-reject-nodrop,REJECT",
            "RuleSet,custom-no-hybrid,DIRECT", "RuleSet,custom-ext-update,Final", "RuleSet,reject,REJECT", "RuleSet,claude,Claude",
            "RuleSet,chatgpt,Chatgpt", "RuleSet,gemini,Gemini", "RuleSet,ai-misc,Proxies", "RuleSet,youtube,Youtube", "RuleSet,netflix,Netflix",
            "RuleSet,truthsocial,TruthSocial", "RuleSet,whatsapp,Whatsapp", "RuleSet,twitter,Twitter", "RuleSet,telegram,Telegram",
            "RuleSet,bahamut,Bahamut", "RuleSet,apple,Apple", "RuleSet,china,DIRECT", "RuleSet,global,Proxies", "IPCIDR,0.0.0.0/32,REJECT",
            "GeoSite,cn,DIRECT", "GeoIP,CN,DIRECT", "Match,,Final",
        ]
        return raw.enumerated().map { i, line in
            let p = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            return MihomoRule(id: i, type: p[0], payload: p[1], proxy: p[2])
        }
    }

    func connections() async throws -> ConnectionsResponse {
        ConnectionsResponse(downloadTotal: 1_280_000_000, uploadTotal: 84_000_000, connections: conns)
    }

    func closeConnection(id: String) async throws {
        conns.removeAll { $0.id == id }
    }

    nonisolated func traffic() -> AsyncThrowingStream<TrafficSample, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var down = 4_200_000.0
                while !Task.isCancelled {
                    down = max(300_000, down + Double.random(in: -900_000...900_000))
                    continuation.yield(TrafficSample(up: Int(down / 7), down: Int(down)))
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension Int {
    /// 把 0（超时）排到最后。
    fileprivate var nonZero: Int { self == 0 ? 99_999 : self }
}
