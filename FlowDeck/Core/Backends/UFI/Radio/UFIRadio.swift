import Foundation

/// 射频能力接口与传输分离。每次只改变一类设置，避免 LTE 成功、NR 失败的半完成事务。
protocol UFIRadioAPI: Sendable {
    func radioState(password: String) async throws -> UFIRadioState
    func setRadioBands(
        _ bands: Set<Int>, technology: UFIRadioTechnology,
        replacing: UFIRadioState, password: String) async throws
    func setRadioCell(_ cell: UFILockedCell?, replacing: UFIRadioState, password: String) async throws
}

enum UFIRadioTechnology: String, CaseIterable, Identifiable, Codable, Sendable {
    case lte, nr
    var id: String { rawValue }
    var title: String { self == .lte ? "4G LTE" : "5G NR" }
    var prefix: String { self == .lte ? "B" : "n" }
    var field: String { self == .lte ? "lte_band_lock" : "nr_band_lock" }
    var formID: String { self == .lte ? "LTE_BAND_LOCK" : "NR_BAND_LOCK" }
    var rat: Int { self == .lte ? 12 : 16 }
}

/// B09 的 CELL_LOCK 使用 RAT 12/16；频点是 EARFCN/NR-ARFCN，不是 MHz。
struct UFILockedCell: Codable, Equatable, Sendable, Identifiable {
    let technology: UFIRadioTechnology
    let pci: Int
    let frequency: Int
    var id: String { "\(technology.rawValue):\(frequency):\(pci)" }

    func form() throws -> [String: String] {
        let maximumPCI = technology == .lte ? 503 : 1007
        let maximumFrequency = technology == .lte ? 262_143 : 3_279_165
        guard (0...maximumPCI).contains(pci), (0...maximumFrequency).contains(frequency) else {
            throw ManagementError.invalid("PCI 或频点超出所选制式范围。频点须填写 ARFCN，而非 MHz。")
        }
        return [
            "goformId": "CELL_LOCK", "rat": String(technology.rat),
            "pci": String(pci), "earfcn": String(frequency),
        ]
    }
}

struct UFIRadioState: Equatable, Sendable {
    let lte: Set<Int>
    let nr: Set<Int>
    let supportedNR: Set<Int>?
    let cells: [UFILockedCell]

    // UFI-TOOLS 4.1.5 自带 bandTable 的 F50 LTE 选项；仅 B09 适配器使用，不泛化到其他型号。
    static let lteOptions: Set<Int> = [1, 3, 5, 8, 34, 38, 39, 40, 41]

    init(_ object: JSONObject, supportedNR: Set<Int>?) throws {
        lte = try Self.bands(object.raw["lte_band_lock"])
        nr = try Self.bands(object.raw["nr_band_lock"])
        self.supportedNR = supportedNR
        guard let rows = object.raw["locked_cell_info"] as? [[String: Any]] else {
            throw ManagementError.unsupported("设备未提供小区锁定状态，暂不开放射频修改。")
        }
        cells = try rows.map { row in
            let item = JSONObject(row)
            guard let rat = item.string("rat").flatMap(Int.init), [12, 16].contains(rat),
                let pci = item.string("pci").flatMap(Int.init), let frequency = item.string("earfcn").flatMap(Int.init)
            else {
                throw ManagementError.unsupported("小区锁定数据无法识别，请在设备网页核对。")
            }
            let cell = UFILockedCell(technology: rat == 12 ? .lte : .nr, pci: pci, frequency: frequency)
            _ = try cell.form()
            return cell
        }
        guard Set(cells.map(\.id)).count == cells.count else {
            throw ManagementError.unconfirmed("锁定小区包含重复项，请刷新。")
        }
    }

    /// 空字符串是此接口的自动选择；缺失键、错误类型及未知格式绝不能当作自动。
    static func bands(_ value: Any?) throws -> Set<Int> {
        guard let text = value as? String else {
            throw ManagementError.unsupported("设备未返回频段锁定字段。")
        }
        if text.isEmpty { return [] }
        let pieces = text.split(separator: ",", omittingEmptySubsequences: false)
        let numbers = pieces.compactMap { piece -> Int? in
            guard !piece.isEmpty, piece.utf8.allSatisfy({ (48...57).contains($0) }),
                let number = Int(piece), (1...1024).contains(number)
            else { return nil }
            return number
        }
        guard numbers.count == pieces.count, Set(numbers).count == numbers.count else {
            throw ManagementError.unsupported("频段格式无法安全解析，未生成默认值。")
        }
        return Set(numbers)
    }

    func selected(_ technology: UFIRadioTechnology) -> Set<Int> { technology == .lte ? lte : nr }

    func bandForm(_ bands: Set<Int>, technology: UFIRadioTechnology) throws -> [String: String] {
        // 即使支持列表暂时不可用，恢复自动也不需要猜测任何频段。
        if !bands.isEmpty {
            guard let supported = technology == .lte ? Self.lteOptions : supportedNR,
                bands.isSubset(of: supported)
            else {
                throw ManagementError.unsupported("所选频段不在已确认的支持列表内。")
            }
        }
        return ["goformId": technology.formID, technology.field: bands.sorted().map(String.init).joined(separator: ",")]
    }
}
