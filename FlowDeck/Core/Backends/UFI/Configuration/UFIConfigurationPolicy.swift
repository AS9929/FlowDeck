import Foundation

/// 保留 F50 插件依赖的网络与管理配置。此处只划分顶层文本，不冒充完整 YAML 解析器。
/// 非常规 YAML（多文档、顶层流式映射、锚点）拒绝写入，最终语义由设备核心校验。
enum UFIConfigurationPolicy {
    private static let editable: Set<String> = ["proxies", "proxy-groups", "proxy-providers", "rules", "rule-providers"]

    static func validate(original: String, candidate: String) throws {
        // 回滚原文或无变化保存不需要重新解释已有的非常规语法。
        if original == candidate { return }
        let before = try sections(original)
        let after = try sections(candidate)
        let protected = Set(before.keys).union(after.keys).subtracting(editable)
        guard protected.allSatisfy({ before[$0] == after[$0] }) else {
            throw ManagementError.invalid("F50 导入须保留原配置的管理端口、Secret、DNS 和透明代理参数。请在现有配置中更新节点、策略组及规则。")
        }
    }

    private static func sections(_ text: String) throws -> [String: String] {
        var sections: [String: String] = [:]
        var current: String?
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#") || trimmed.isEmpty {
                if let current { sections[current, default: ""] += line + "\n" }
                continue
            }
            guard trimmed != "---", trimmed != "...", !trimmed.hasPrefix("%"),
                line.range(of: "(^|[ :\\[,\\{])[*&][A-Za-z0-9_]", options: .regularExpression) == nil
            else {
                throw unsupportedSyntax()
            }
            if let first = line.first, !first.isWhitespace, first != "-" {
                guard let colon = line.firstIndex(of: ":") else { throw unsupportedSyntax() }
                let key = String(line[..<colon])
                guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
                    sections[key] == nil
                else { throw unsupportedSyntax() }
                current = key
                sections[key] = ""
            }
            guard let current else { throw unsupportedSyntax() }
            sections[current, default: ""] += line + "\n"
        }
        guard !sections.isEmpty else { throw unsupportedSyntax() }
        return sections
    }

    private static func unsupportedSyntax() -> ManagementError {
        .invalid("当前 YAML 含无法安全比较的顶层格式、重复键或锚点。请保留设备原配置结构后再编辑。")
    }
}
