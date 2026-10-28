import Foundation

/// 配置文本差异摘要，不解析 YAML 语义，也不把节点凭据写入日志。
struct ConfigurationDifference: Sendable {
    let inserted: Int
    let removed: Int
    let changedSections: [String]

    init(before: String, after: String) {
        let oldLines = before.components(separatedBy: .newlines)
        let newLines = after.components(separatedBy: .newlines)
        let difference = newLines.difference(from: oldLines)
        inserted = difference.insertions.count
        removed = difference.removals.count
        let old = Self.sections(oldLines)
        let new = Self.sections(newLines)
        changedSections = Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }.sorted()
    }

    private static func sections(_ lines: [String]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var key = "文件头"
        for line in lines {
            if let first = line.first, !first.isWhitespace, first != "#", first != "-", let colon = line.firstIndex(of: ":") {
                let candidate = String(line[..<colon])
                if candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) { key = candidate }
            }
            result[key, default: []].append(line)
        }
        return result
    }
}
