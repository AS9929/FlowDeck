import Foundation

/// 作者 UFI 前端提供的模式值；UI 展示含义与实际提交值分别保存。
enum UFINetworkMode: String, CaseIterable, Identifiable {
    case automatic = "WL_AND_5G"
    case nsa = "LTE_AND_5G"
    case sa = "Only_5G"
    case lteAndWCDMA = "WCDMA_AND_LTE"
    case lte = "Only_LTE"
    case wcdma = "Only_WCDMA"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "5G / 4G / 3G 自动"
        case .nsa: return "5G NSA"
        case .sa: return "5G SA"
        case .lteAndWCDMA: return "4G / 3G"
        case .lte: return "仅 4G"
        case .wcdma: return "仅 3G"
        }
    }
}

/// F50 B09 的 SIM 操作。PIN/PUK 不缓存，不推测密码，也不自动重试。
enum UFIPINOperation: String, CaseIterable, Identifiable {
    case enable, disable, change, unlock, unblock

    var id: String { rawValue }
    var title: String {
        switch self {
        case .enable: return "启用 PIN 锁"
        case .disable: return "关闭 PIN 锁"
        case .change: return "修改 PIN"
        case .unlock: return "解锁 SIM"
        case .unblock: return "使用 PUK 解锁"
        }
    }

    var needsNewPIN: Bool { self == .change || self == .unblock }

    func form(pin: String, newPIN: String, puk: String) throws -> [String: String] {
        func valid(_ value: String, length: ClosedRange<Int>) -> Bool {
            length.contains(value.count) && value.utf8.allSatisfy { (48...57).contains($0) }
        }
        guard self == .unblock || valid(pin, length: 4...8),
            !needsNewPIN || valid(newPIN, length: 4...8),
            self != .unblock || valid(puk, length: 8...8)
        else { throw ManagementError.invalid("PIN 须为 4–8 位数字，PUK 须为 8 位数字。") }
        switch self {
        case .enable: return ["goformId": "ENABLE_PIN", "OldPinNumber": pin]
        case .disable: return ["goformId": "DISABLE_PIN", "OldPinNumber": pin]
        case .change: return ["goformId": "ENABLE_PIN", "OldPinNumber": pin, "NewPinNumber": newPIN]
        case .unlock: return ["goformId": "ENTER_PIN", "PinNumber": pin]
        case .unblock: return ["goformId": "ENTER_PUK", "PUKNumber": puk, "PinNumber": newPIN]
        }
    }
}

/// 对应 APN_PROC_EX。保留 IPv4/IPv6 各自的认证和 DNS 字段，避免编辑时覆盖隐藏属性。
struct UFIAPNProfile: Identifiable, Equatable, Sendable, Codable {
    let index: Int
    var name: String
    var protocolType: String
    var ipv4: [String]
    var ipv6: [String]
    var id: Int { index }
    var apn: String {
        get { (protocolType == "IPv6" ? ipv6 : ipv4)[1] }
        set {
            ipv4[1] = newValue
            ipv6[1] = newValue
        }
    }

    static func draft(index: Int) -> Self {
        var fields = Array(repeating: "", count: 13)
        fields[4] = "none"
        fields[10] = "auto"
        return Self(index: index, name: "", protocolType: "IPv4v6", ipv4: fields, ipv6: fields)
    }

    func form() throws -> [String: String] {
        guard (0..<20).contains(index), ipv4.count == 13, ipv6.count == 13,
            (1...32).contains(name.utf8.count), !name.contains("($)"), !name.contains("||"),
            !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            ["IP", "IPv6", "IPv4v6"].contains(protocolType)
        else { throw ManagementError.invalid("APN 名称或协议无效。") }
        var result = [
            "goformId": "APN_PROC_EX", "apn_action": "save", "apn_mode": "manual",
            "index": String(index), "profile_name": name, "pdp_type": protocolType,
            "wan_dial": "*99#", "apn_select": "manual", "pdp_select": "auto", "pdp_addr": "",
        ]
        for (fields, prefix) in [(ipv4, ""), (ipv6, "ipv6_")] {
            if protocolType == "IP" && !prefix.isEmpty || protocolType == "IPv6" && prefix.isEmpty { continue }
            guard (1...100).contains(fields[1].utf8.count),
                fields[1].range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil,
                ["none", "pap", "chap"].contains(fields[4].lowercased()),
                ["auto", "manual"].contains(fields[10]),
                fields.allSatisfy({ !$0.contains("($)") && !$0.contains("||") })
            else { throw ManagementError.invalid("APN、认证方式或 DNS 配置无效，请重新读取。") }
            for (key, offset) in [
                ("wan_apn", 1), ("ppp_auth_mode", 4), ("ppp_username", 5),
                ("ppp_passwd", 6), ("dns_mode", 10), ("prefer_dns_manual", 11), ("standby_dns_manual", 12),
            ] {
                result[prefix + key] = fields[offset]
            }
        }
        return result
    }
}

/// 严格识别原厂槽位，默认 APN 只允许选择，不允许覆盖或删除。
struct UFIAPNState: Equatable, Sendable, Codable {
    let mode: String
    let currentIndex: Int?
    let presetCount: Int
    let profiles: [UFIAPNProfile]

    init(_ object: JSONObject) throws {
        guard let mode = object.string("apn_mode"), ["auto", "manual"].contains(mode),
            let count = object.int("default_APN_size"), (0...20).contains(count)
        else { throw ManagementError.unsupported("未识别 F50 APN 槽位信息，未启用编辑。") }
        self.mode = mode
        presetCount = count
        currentIndex = object.string("Current_index").flatMap(Int.init)
        profiles = try (0..<20).compactMap { index in
            // 空字符串表示可用槽位；JSONObject.string 会折叠空值，此处必须检查原始字段。
            guard let raw = object.raw["APN_config\(index)"] as? String else {
                throw ManagementError.unconfirmed("APN 列表不完整，请重新读取。")
            }
            guard !raw.isEmpty else { return nil }
            let ipv4 = raw.components(separatedBy: "($)")
            let ipv6Raw = object.string("ipv6_APN_config\(index)") ?? ""
            let ipv6 = ipv6Raw.isEmpty ? Array(repeating: "", count: 13) : ipv6Raw.components(separatedBy: "($)")
            guard ipv4.count == 13, ipv6.count == 13 else {
                throw ManagementError.unsupported("APN 字段结构不匹配，未启用编辑。")
            }
            return UFIAPNProfile(index: index, name: ipv4[0], protocolType: ipv4[7], ipv4: ipv4, ipv6: ipv6)
        }
    }

    var freeIndex: Int? { (presetCount..<20).first { index in !profiles.contains { $0.index == index } } }
}

/// 发送时采用原厂 UNICODE 编码；不支持的非 BMP 字符明确拒绝，避免静默损坏内容。
enum UFISMSComposer {
    static func form(number: String, text: String, date: Date = Date(), timeZone: TimeZone = .current) throws -> [String: String] {
        guard number.range(of: "^\\+?[0-9]{3,20}$", options: .regularExpression) != nil,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            text.utf16.count <= 500, text.unicodeScalars.allSatisfy({ $0.value <= 0xFFFF && $0.value != 0 })
        else { throw ManagementError.invalid("请填写有效号码及 1–500 字短信；F50 当前不支持发送 emoji 等扩展字符。") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yy;MM;dd;HH;mm;ss;"
        let hours = Double(timeZone.secondsFromGMT(for: date)) / 3600
        let zone = hours >= 0 ? "+\(hours.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US_POSIX"))))" : String(hours)
        return [
            "goformId": "SEND_SMS", "Number": number, "ID": "-1", "encode_type": "UNICODE",
            "MessageBody": text.utf16.map { String(format: "%04X", $0) }.joined(),
            "sms_time": formatter.string(from: date) + zone,
        ]
    }
}

/// APN 含运营商认证密码，仅存本机钥匙串；恢复为草稿后仍须确认提交。
struct UFIAPNBackup: Codable {
    let state: UFIAPNState
    let date: Date

    func save(deviceID: String) throws {
        let encoded = try JSONEncoder().encode(self).base64EncodedString()
        try KeychainStore.setChecked(encoded, account: "ufi.apn.backup." + deviceID)
    }

    static func clear(deviceID: String) throws {
        try KeychainStore.setChecked("", account: "ufi.apn.backup." + deviceID)
    }

    static func load(deviceID: String) throws -> Self? {
        guard let text = KeychainStore.get(account: "ufi.apn.backup." + deviceID) else { return nil }
        guard let data = Data(base64Encoded: text) else {
            throw ManagementError.unconfirmed("本机 APN 副本无法读取。")
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

/// F50 双芯片共用访问控制表。仅编辑已启用的黑名单，保留白名单和名称原始字段。
struct UFIClientAccess: Equatable, Sendable {
    struct Entry: Identifiable, Equatable, Sendable {
        let mac: String
        let name: String
        var id: String { mac.uppercased() }
    }

    let fields: [String: String]
    let blocked: [Entry]
    var canEdit: Bool { fields["AclMode"] == "2" }

    init(_ object: JSONObject) throws {
        var fields: [String: String] = [:]
        for key in ["AclMode", "WhiteMacList", "WhiteNameList", "BlackMacList", "BlackNameList"] {
            guard let value = object.raw[key] as? String else {
                throw ManagementError.unconfirmed("未获得完整访问控制表。")
            }
            fields[key] = value
        }
        func parts(_ value: String) throws -> [String] {
            if value.isEmpty { return [] }
            guard value.hasSuffix(";") else { throw ManagementError.unsupported("访问控制表格式无法识别。") }
            return String(value.dropLast()).components(separatedBy: ";")
        }
        let macs = try parts(fields["BlackMacList"]!)
        let names = try parts(fields["BlackNameList"]!)
        guard macs.count == names.count, macs.count <= 31,
            Set(macs.map { $0.uppercased() }).count == macs.count,
            macs.allSatisfy({ $0.range(of: "^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$", options: .regularExpression) != nil })
        else { throw ManagementError.unsupported("黑名单内容不完整，未启用编辑。") }
        self.fields = fields
        blocked = zip(macs, names).map { Entry(mac: $0, name: $1) }
    }

    func changing(mac: String, name: String, blocked shouldBlock: Bool) throws -> Self {
        guard canEdit else {
            throw ManagementError.unsupported("当前使用白名单或未启用过滤，请在原厂网页确认策略后再编辑。")
        }
        guard mac.range(of: "^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$", options: .regularExpression) != nil,
            !name.contains(";"), !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw ManagementError.invalid("设备名称或 MAC 格式不适用于访问控制表。") }
        var entries = blocked.filter { $0.mac.caseInsensitiveCompare(mac) != .orderedSame }
        if shouldBlock { entries.append(Entry(mac: mac, name: name)) }
        guard entries.count <= 31 else { throw ManagementError.invalid("黑名单已达到原厂页面的 31 台上限。") }
        var updated = fields
        updated["BlackMacList"] = entries.map { $0.mac + ";" }.joined()
        updated["BlackNameList"] = entries.map { $0.name + ";" }.joined()
        return try Self(JSONObject(updated))
    }
}
