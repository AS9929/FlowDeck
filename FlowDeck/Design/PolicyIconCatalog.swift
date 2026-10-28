import Foundation

/// 策略图标的语义目录；只改变展示，不修改发送到 Mihomo 的原始组名。
struct PolicyIconSpec: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let category: String
    let aliases: [String]
    var symbol: String?
    var asset: String?
    var regionCode: String?

    /// 展示资源与策略身份分离；台湾分组按产品要求使用中国国旗，不改动组名及请求参数。
    var flagAssetName: String? {
        guard id.hasPrefix("region-"), let regionCode else { return nil }
        return "Region-" + (regionCode == "TW" ? "CN" : regionCode)
    }
}

/// 离线名称解析。短英文按词匹配，避免 IN、AI、US 等缩写误命中普通单词。
enum PolicyIconCatalog {
    static let services: [PolicyIconSpec] = {
        guard let url = Bundle.main.url(forResource: "PolicyIconCatalog", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let entries = try? JSONDecoder().decode([PolicyIconSpec].self, from: data)
        else { return [] }
        return entries
    }()

    static let fallback = PolicyIconSpec(
        id: "custom", title: "自定义策略", category: "其他", aliases: [], symbol: "square.stack.3d.up")

    static let regions: [PolicyIconSpec] = {
        let chinese = Locale(identifier: "zh_Hans")
        let english = Locale(identifier: "en_US")
        let extra: [String: [String]] = [
            "HK": ["香港", "Hong Kong", "HongKong", "港区"],
            "TW": ["台湾", "Taiwan", "台灣", "台区"],
            "MO": ["澳门", "澳門", "Macau", "Macao"],
            "US": ["美国", "美國", "美区", "USA", "United States", "America"],
            "GB": ["英国", "英國", "UK", "United Kingdom", "Britain"],
            "JP": ["日本", "日区", "Japan", "东京", "大阪"],
            "KR": ["韩国", "韓國", "South Korea", "Korea", "首尔"],
            "SG": ["新加坡", "狮城", "Singapore"],
            "CN": ["中国", "中國", "China", "中国大陆"],
        ]
        // ISO 代码本身也可匹配，冷门地区不需要等下一版补图标。
        return Locale.Region.isoRegions.filter { $0.identifier.count == 2 }.map { region in
            let code = region.identifier
            let title = chinese.localizedString(forRegionCode: code) ?? code
            let aliases = [code, title, english.localizedString(forRegionCode: code) ?? code] + (extra[code] ?? [])
            return PolicyIconSpec(id: "region-" + code, title: title, category: "国家与地区", aliases: aliases, regionCode: code)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }()

    static let continents: [PolicyIconSpec] = [
        .init(id: "continent-EU", title: "欧洲", category: "国家与地区", aliases: ["EU", "Europe", "欧洲", "歐洲"], regionCode: "EU"),
        .init(id: "continent-AS", title: "亚洲", category: "国家与地区", aliases: ["Asia", "亚洲", "亞洲"], regionCode: "AS"),
        .init(id: "continent-NA", title: "北美洲", category: "国家与地区", aliases: ["North America", "北美"], regionCode: "NA"),
        .init(id: "continent-SA", title: "南美洲", category: "国家与地区", aliases: ["South America", "南美"], regionCode: "SA"),
        .init(id: "continent-AF", title: "非洲", category: "国家与地区", aliases: ["Africa", "非洲"], regionCode: "AF"),
        .init(id: "continent-OC", title: "大洋洲", category: "国家与地区", aliases: ["Oceania", "大洋洲"], regionCode: "OC"),
    ]

    private struct Alias {
        let value: String
        let spec: PolicyIconSpec
        let pattern: NSRegularExpression?

        init(_ value: String, spec: PolicyIconSpec) {
            self.value = value.lowercased()
            self.spec = spec
            let hasCJK = value.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
            pattern =
                hasCJK
                ? nil
                : try? NSRegularExpression(
                    pattern: "(?<![a-z0-9])" + NSRegularExpression.escapedPattern(for: self.value) + "(?![a-z0-9])")
        }

        func matches(_ name: String) -> Bool {
            if let pattern {
                return pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
            }
            return name.contains(value)
        }
    }

    /// 正则仅构造一次；同长名称按目录顺序稳定匹配，详细品牌名优先于通用分类。
    private static let aliases: [Alias] = {
        var result: [Alias] = []
        for spec in services + continents + regions {
            for value in spec.aliases where !value.isEmpty {
                result.append(Alias(value, spec: spec))
            }
        }
        let ordered = result.enumerated().sorted { left, right in
            if left.element.value.count == right.element.value.count {
                return left.offset < right.offset
            }
            return left.element.value.count > right.element.value.count
        }
        return ordered.map { $0.element }
    }()

    private final class CachedSpec {
        let value: PolicyIconSpec
        init(_ value: PolicyIconSpec) { self.value = value }
    }

    // 只缓存展示结果，限制容量；轮询刷新列表时不重复遍历别名正则。
    private static let cache: NSCache<NSString, CachedSpec> = {
        let cache = NSCache<NSString, CachedSpec>()
        cache.countLimit = 512
        return cache
    }()

    static func resolve(name: String, iconURL: String? = nil, groupType: String? = nil) -> PolicyIconSpec {
        let key = ([name, iconURL ?? "", groupType ?? ""] as NSArray).description as NSString
        if let cached = cache.object(forKey: key) { return cached.value }
        let spec = resolveUncached(name: name, iconURL: iconURL, groupType: groupType)
        cache.setObject(CachedSpec(spec), forKey: key)
        return spec
    }

    private static func resolveUncached(name: String, iconURL: String? = nil, groupType: String? = nil) -> PolicyIconSpec {
        let normalized = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // 先精确匹配完整名称，避免 DIRECT、REJECT-DROP 等内置行为被地区提示覆盖。
        if let exact = aliases.first(where: { $0.value == normalized }) { return exact.spec }
        if let semantic = aliases.first(where: { $0.matches(normalized) }) { return semantic.spec }
        if let code = flagCode(in: name), let region = regions.first(where: { $0.regionCode == code }) { return region }
        // 自定义组可以沿用已知图标文件名的语义，但不下载和混用外部图片。
        if let iconURL, let url = URL(string: iconURL) {
            let filename = url.deletingPathExtension().lastPathComponent.lowercased().replacingOccurrences(of: "_", with: " ")
            if let known = aliases.first(where: { $0.matches(filename) }) { return known.spec }
        }
        let typeIDs = [
            "selector": "select", "select": "select", "urltest": "auto", "url-test": "auto",
            "fallback": "fallback", "loadbalance": "balance", "load-balance": "balance", "relay": "relay", "smart": "smart",
        ]
        if let groupType, let id = typeIDs[groupType.lowercased()], let spec = services.first(where: { $0.id == id }) { return spec }
        return fallback
    }

    private static func flagCode(in name: String) -> String? {
        let values = Array(name.unicodeScalars)
        for index in values.indices.dropLast() {
            let pair = [values[index].value, values[index + 1].value]
            if pair.allSatisfy({ (0x1F1E6...0x1F1FF).contains($0) }) {
                return String(String.UnicodeScalarView(pair.compactMap { UnicodeScalar($0 - 0x1F1E6 + 65) }))
            }
        }
        return nil
    }

    /// 只去除标题前缀的装饰 emoji；保留纯 emoji 组名以及所有真实路由键。
    static func displayName(_ name: String) -> String {
        let trimmed = name.drop { character in
            character.isWhitespace || character.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }
        }
        return trimmed.isEmpty ? name : String(trimmed)
    }
}
