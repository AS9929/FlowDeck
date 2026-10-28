import Foundation

/// 在手机上把 Surge 配置转换成 Mihomo 配置。
/// 规则与部署时用的 generate-openclash.py、adapt-u60-config.py 保持一致：
/// - 只接受 SS 节点，SS-2022 校验密钥长度；
/// - 策略组按 Surge 的 [Proxy Group] 重建（include-all-proxies、include-other-group、policy-regex-filter），
///   Proxies 末尾追加 url-test 组“自动选择”，没有节点的地区组会被去掉；
/// - 规则取 [Rule] 里的远程 RULE-SET，前后加上固定的局域网、国内直连和 MATCH,Final；
/// - 设备上的其余设置（Secret、端口、DNS、TUN、NTP、本地兼容规则集）原样保留。
enum SurgeConverter {
    struct SSProxy: Equatable {
        var name: String
        var server: String
        var port: Int
        var cipher: String
        var password: String
        var udp: Bool
    }

    struct Group: Equatable {
        var name: String
        var type: String
        var members: [String]
        var icon: String?
        var extra: [(String, String)] = []

        static func == (a: Group, b: Group) -> Bool {
            a.name == b.name && a.type == b.type && a.members == b.members && a.icon == b.icon
        }
    }

    struct Provider: Equatable {
        var name: String
        var url: String
        var policy: String
    }

    struct Result {
        var proxies: [SSProxy]
        var groups: [Group]
        var providers: [Provider]
        var rules: [String]
        var droppedGroups: [String]
        var ignoredSections: [String]
        var ignoredRules: [String]
    }

    enum ConvertError: LocalizedError, Equatable {
        case noProxies
        case unsupportedProtocol(String, String)
        case badProxy(String)
        case badKey(String)
        case duplicateNames([String])
        case noRuleSets
        case unknownPolicy(String)
        case notMihomoConfig

        var errorDescription: String? {
            switch self {
            case .noProxies: return "[Proxy] 段里没有 SS 节点。"
            case .unsupportedProtocol(let n, let p): return "节点“\(n)”使用了暂不支持的协议 \(p)，目前只支持 SS。"
            case .badProxy(let n): return "节点“\(n)”的格式不完整。"
            case .badKey(let n): return "节点“\(n)”的 SS-2022 密钥长度不对。"
            case .duplicateNames(let n): return "有重名节点：\(n.joined(separator: "、"))"
            case .noRuleSets: return "[Rule] 段里没有远程 RULE-SET。"
            case .unknownPolicy(let p): return "规则用到的策略“\(p)”在转换后不存在。"
            case .notMihomoConfig: return "设备上的当前配置格式无法识别，没有改动。"
            }
        }
    }

    static let autoGroup = "自动选择"
    static let builtins: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP", "PASS"]
    static let policyMap = ["REJECT-NO-DROP": "REJECT", "REJECT-TINYGIF": "REJECT", "NO-HYBRID": "DIRECT"]
    static let ss2022KeyLengths = ["2022-blake3-aes-128-gcm": 16, "2022-blake3-aes-256-gcm": 32, "2022-blake3-chacha20-poly1305": 32]
    /// Mihomo 不支持、转换时忽略的 Surge 段落。
    static let surgeOnlySections = ["URL Rewrite", "Header Rewrite", "MITM", "Script", "Panel", "Host", "SSID Setting", "Body Rewrite", "Map Local"]

    // MARK: 解析

    static func sections(_ text: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        var current: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast()).lowercased()
                out[current!, default: []] = out[current!] ?? []
                continue
            }
            if let current { out[current, default: []].append(raw) }
        }
        return out
    }

    /// 逗号分隔，支持双引号包裹（与 Python csv 的 skipinitialspace 行为一致）。
    static func splitCSV(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inQuotes = false
        var atFieldStart = true
        for ch in s {
            if atFieldStart && ch == " " { continue }
            atFieldStart = false
            if ch == "\"" {
                inQuotes.toggle()
                continue
            }
            if ch == ",", !inQuotes {
                out.append(cur.trimmingCharacters(in: .whitespaces))
                cur = ""
                atFieldStart = true
                continue
            }
            cur.append(ch)
        }
        out.append(cur.trimmingCharacters(in: .whitespaces))
        return out
    }

    private static func isComment(_ line: String) -> Bool {
        line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") || line.hasPrefix("//")
    }

    private static func splitDefinition(_ line: String) -> (String, String)? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let name = line[..<eq].trimmingCharacters(in: .whitespaces)
        let def = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : (name, def)
    }

    static func parseProxies(_ lines: [String]) throws -> [SSProxy] {
        var out: [SSProxy] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !isComment(line), let (name, def) = splitDefinition(line) else { continue }
            let parts = splitCSV(def)
            guard parts.count >= 4 else { throw ConvertError.badProxy(name) }
            let proto = parts[0].lowercased()
            // Surge 的 direct/reject 类内置别名不是节点，跳过。
            if ["direct", "reject", "reject-tinygif"].contains(proto) { continue }
            guard proto == "ss" else { throw ConvertError.unsupportedProtocol(name, proto) }
            var opts: [String: String] = [:]
            for item in parts.dropFirst(3) {
                guard let eq = item.firstIndex(of: "=") else { throw ConvertError.badProxy(name) }
                opts[item[..<eq].trimmingCharacters(in: .whitespaces).lowercased()] = item[item.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            }
            guard let cipher = opts["encrypt-method"], let password = opts["password"], let port = Int(parts[2]) else {
                throw ConvertError.badProxy(name)
            }
            if let need = ss2022KeyLengths[cipher] {
                guard let key = Data(base64Encoded: password), key.count == need else { throw ConvertError.badKey(name) }
            }
            let udp = ["true", "1", "yes"].contains((opts["udp-relay"] ?? "true").lowercased())
            out.append(SSProxy(name: name, server: parts[1], port: port, cipher: cipher, password: password, udp: udp))
        }
        guard !out.isEmpty else { throw ConvertError.noProxies }
        let names = out.map(\.name)
        let dups = Set(names.filter { n in names.filter { $0 == n }.count > 1 })
        if !dups.isEmpty { throw ConvertError.duplicateNames(dups.sorted()) }
        return out
    }

    static func parseGroups(_ lines: [String], nodes: [String]) -> (groups: [Group], dropped: [String]) {
        struct Raw {
            var name: String
            var type: String
            var members: [String]
            var opts: [String: String]
        }
        var raws: [Raw] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !isComment(line), let (name, def) = splitDefinition(line) else { continue }
            let parts = splitCSV(def)
            guard let type = parts.first?.lowercased() else { continue }
            var members: [String] = []
            var opts: [String: String] = [:]
            for item in parts.dropFirst() {
                if let eq = item.firstIndex(of: "="), !item.hasPrefix("http") {
                    opts[item[..<eq].trimmingCharacters(in: .whitespaces).lowercased()] = item[item.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                } else if !item.isEmpty {
                    members.append(policyMap[item] ?? item)
                }
            }
            raws.append(Raw(name: name, type: type, members: members, opts: opts))
        }

        var resolved: [String: [String]] = [:]
        func nodesOf(_ group: String, depth: Int = 0) -> [String] {
            if let r = resolved[group] { return r }
            guard depth < 6, let g = raws.first(where: { $0.name == group }) else { return [] }
            var included: [String] = []
            if g.opts["include-all-proxies"]?.lowercased() == "true" { included += nodes }
            if let others = g.opts["include-other-group"] {
                for o in others.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                    included += nodesOf(o, depth: depth + 1).filter { nodes.contains($0) }
                }
            }
            if let pattern = g.opts["policy-regex-filter"], let re = try? NSRegularExpression(pattern: pattern) {
                included = included.filter { re.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
            }
            var seen = Set<String>()
            let all = (g.members + included).filter { seen.insert($0).inserted }
            resolved[group] = all
            return all
        }

        var groups: [Group] = []
        for r in raws {
            let type: String
            switch r.type {
            case "url-test", "fallback", "load-balance": type = r.type
            default: type = "select"
            }
            var g = Group(name: r.name, type: type, members: nodesOf(r.name), icon: r.opts["icon-url"])
            if type != "select" {
                g.extra = [("url", r.opts["url"] ?? "https://www.gstatic.com/generate_204"), ("interval", r.opts["interval"] ?? "600")]
            }
            groups.append(g)
        }

        // 没有任何成员的组（例如这批节点里没有某个地区）去掉，并从其他组的成员里剔除。
        var dropped: [String] = []
        var changed = true
        while changed {
            changed = false
            let empty = Set(groups.filter { $0.members.isEmpty }.map(\.name))
            if !empty.isEmpty {
                dropped += empty
                groups.removeAll { empty.contains($0.name) }
                for i in groups.indices { groups[i].members.removeAll { empty.contains($0) } }
                changed = true
            }
        }

        // 与转换器一致：Proxies 末尾追加“自动选择”，并在 Proxies 后插入 url-test 组。
        if let pi = groups.firstIndex(where: { $0.name == "Proxies" }), !groups.contains(where: { $0.name == autoGroup }) {
            groups[pi].members.append(autoGroup)
            let auto = Group(
                name: autoGroup, type: "url-test", members: nodes, icon: nil,
                extra: [("url", "https://www.gstatic.com/generate_204"), ("interval", "600"), ("tolerance", "100"), ("lazy", "true")])
            groups.insert(auto, at: pi + 1)
        }
        return (groups, dropped)
    }

    static func parseRuleSets(_ lines: [String]) -> [(url: String, policy: String)] {
        lines.compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.uppercased().hasPrefix("RULE-SET,") else { return nil }
            let parts = splitCSV(line)
            guard parts.count >= 3, parts[1].hasPrefix("http://") || parts[1].hasPrefix("https://") else { return nil }
            return (parts[1], parts[2])
        }
    }

    /// custom/direct.list → custom-direct；reject.list → reject。与转换器的命名规则相同。
    static func providerName(_ url: String, used: inout Set<String>) -> String {
        let path = URL(string: url)?.path ?? url
        let comps = path.split(separator: "/").map(String.init)
        let file = comps.last ?? "ruleset"
        let stem = file.contains(".") ? String(file[..<file.lastIndex(of: ".")!]) : file
        let parent = comps.count > 1 ? comps[comps.count - 2] : ""
        var name = parent == "custom" ? "\(parent)-\(stem)" : stem
        name = name.replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if name.isEmpty { name = "ruleset" }
        let base = name
        var i = 2
        while used.contains(name) {
            name = "\(base)-\(i)"
            i += 1
        }
        used.insert(name)
        return name
    }

    static func convert(_ text: String) throws -> Result {
        let secs = sections(text)
        let proxies = try parseProxies(secs["proxy"] ?? [])
        let names = proxies.map(\.name)
        let (groups, dropped) = parseGroups(secs["proxy group"] ?? [], nodes: names)
        let groupNames = Set(groups.map(\.name))
        let allPolicies = groupNames.union(names).union(builtins)
        for group in groups {
            for member in group.members where !allPolicies.contains(member) {
                throw ConvertError.unknownPolicy(group.name + " → " + member)
            }
        }
        guard groupNames.contains("Final") else { throw ConvertError.unknownPolicy("Final（转换模板的最终策略）") }
        let sets = parseRuleSets(secs["rule"] ?? [])
        guard !sets.isEmpty else { throw ConvertError.noRuleSets }

        var used = Set<String>()
        var providers: [Provider] = []
        var rules = ["DOMAIN,captive.apple.com,DIRECT", "GEOSITE,private,DIRECT", "GEOIP,private,DIRECT,no-resolve"]
        for (url, policy) in sets {
            let mapped = policyMap[policy] ?? policy
            let target: String
            if builtins.contains(mapped) || groupNames.contains(mapped) {
                target = mapped
            } else if dropped.contains(mapped) {
                guard groupNames.contains("Proxies") else { throw ConvertError.unknownPolicy("Proxies（空组的回退策略）") }
                target = "Proxies"
            } else {
                throw ConvertError.unknownPolicy(policy)
            }
            let name = providerName(url, used: &used)
            providers.append(Provider(name: name, url: url, policy: target))
            rules.append("RULE-SET,\(name),\(target)")
        }
        rules += ["IP-CIDR,0.0.0.0/32,REJECT,no-resolve", "GEOSITE,cn,DIRECT", "GEOIP,CN,DIRECT,no-resolve", "MATCH,Final"]

        let ignored = surgeOnlySections.filter { secs[$0.lowercased()].map { $0.contains { !isComment($0.trimmingCharacters(in: .whitespaces)) } } ?? false }
        let ignoredRules = (secs["rule"] ?? []).filter {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return !isComment(line) && !line.uppercased().hasPrefix("RULE-SET,")
        }
        return Result(proxies: proxies, groups: groups, providers: providers, rules: rules,
                      droppedGroups: dropped, ignoredSections: ignored, ignoredRules: ignoredRules)
    }

    // MARK: 生成 YAML 并合并到设备配置

    /// JSON 字符串同时是合法的 YAML 双引号标量，用它保证特殊字符安全。
    static func q(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])
        let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }

    static func yamlBlocks(_ r: Result, fileProviders: [String: (behavior: String, format: String, path: String)]) -> [String: String] {
        var proxies = "proxies:\n"
        for p in r.proxies {
            proxies +=
                "- {name: \(q(p.name)), type: ss, server: \(q(p.server)), port: \(p.port), cipher: \(q(p.cipher)), password: \(q(p.password)), udp: \(p.udp), tfo: false}\n"
        }
        var groups = "proxy-groups:\n"
        for g in r.groups {
            groups += "- name: \(q(g.name))\n  type: \(g.type)\n"
            groups += "  proxies: [\(g.members.map(q).joined(separator: ", "))]\n"
            for (k, v) in g.extra {
                let isScalar = Int(v) != nil || v == "true" || v == "false"
                groups += "  \(k): \(isScalar ? v : q(v))\n"
            }
            if let icon = g.icon { groups += "  icon: \(q(icon))\n" }
        }
        var providers = "rule-providers:\n"
        for p in r.providers {
            providers += "  \(q(p.name)):\n"
            if let f = fileProviders[p.name] {
                providers += "    type: file\n    behavior: \(f.behavior)\n    format: \(f.format)\n    path: \(q(f.path))\n"
            } else {
                providers += "    type: http\n    behavior: classical\n    format: text\n    url: \(q(p.url))\n"
                providers += "    path: \(q("./rule_provider/\(p.name).list"))\n    interval: 86400\n    proxy: Proxies\n"
            }
        }
        var rules = "rules:\n"
        for rule in r.rules { rules += "- \(q(rule))\n" }
        return ["proxies": proxies, "proxy-groups": groups, "rule-providers": providers, "rules": rules]
    }

    /// 设备配置里 type: file 的规则集（部署时生成的本地兼容副本），按名字保留。
    static func fileProviders(in config: String) -> [String: (behavior: String, format: String, path: String)] {
        guard let block = topLevelBlocks(config).first(where: { $0.key == "rule-providers" })?.text else { return [:] }
        var out: [String: (String, String, String)] = [:]
        var name: String?
        var fields: [String: String] = [:]
        func flush() {
            if let name, fields["type"] == "file", let path = fields["path"] {
                out[name] = (fields["behavior"] ?? "classical", fields["format"] ?? "text", path)
            }
        }
        for line in block.components(separatedBy: "\n").dropFirst() {
            let indent = line.prefix { $0 == " " }.count
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.hasPrefix("#") else { continue }
            if indent == 2, t.hasSuffix(":") {
                flush()
                name = unquote(String(t.dropLast()))
                fields = [:]
            } else if indent >= 4, let c = t.firstIndex(of: ":") {
                fields[String(t[..<c])] = unquote(t[t.index(after: c)...].trimmingCharacters(in: .whitespaces))
            }
        }
        flush()
        return out
    }

    private static func unquote(_ s: String) -> String {
        var v = s
        if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")), v.count >= 2 {
            v = String(v.dropFirst().dropLast())
        }
        return v
    }

    struct Block {
        let key: String
        let text: String
    }

    /// 按顶层键切分 YAML（PyYAML 的块格式：顶层键从第 0 列开始）。
    static func topLevelBlocks(_ yaml: String) -> [Block] {
        var blocks: [Block] = []
        var key = ""
        var buf: [String] = []
        for line in yaml.components(separatedBy: "\n") {
            let first = line.first
            let isTop = first != nil && first != " " && first != "-" && first != "#" && line.contains(":")
            if isTop {
                if !buf.isEmpty { blocks.append(Block(key: key, text: buf.joined(separator: "\n"))) }
                key = String(line[..<line.firstIndex(of: ":")!]).trimmingCharacters(in: .whitespaces)
                buf = [line]
            } else {
                buf.append(line)
            }
        }
        if !buf.isEmpty { blocks.append(Block(key: key, text: buf.joined(separator: "\n"))) }
        return blocks
    }

    /// 把转换结果合并进设备上的当前配置：只替换节点、策略组、规则集和规则四段。
    static func merge(_ r: Result, into deviceConfig: String) throws -> (yaml: String, keptLocalProviders: [String]) {
        let blocks = topLevelBlocks(deviceConfig)
        let keys = Set(blocks.map(\.key))
        guard keys.contains("proxies"), keys.contains("rules"), keys.contains("external-controller") else {
            throw ConvertError.notMihomoConfig
        }
        let files = fileProviders(in: deviceConfig)
        let replacement = yamlBlocks(r, fileProviders: files)
        var out: [String] = []
        var inserted = Set<String>()
        for b in blocks {
            if let rep = replacement[b.key] {
                out.append(rep.hasSuffix("\n") ? String(rep.dropLast()) : rep)
                inserted.insert(b.key)
            } else {
                out.append(b.text)
            }
        }
        for key in ["proxies", "proxy-groups", "rule-providers", "rules"] where !inserted.contains(key) {
            out.append(String(replacement[key]!.dropLast()))
        }
        var text = out.joined(separator: "\n")
        if !text.hasSuffix("\n") { text += "\n" }
        let kept = r.providers.map(\.name).filter { files[$0] != nil }
        return (text, kept)
    }
}
