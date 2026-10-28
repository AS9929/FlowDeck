import Foundation

/// 对 JSONSerialization 结果的宽松读取。原厂 ubus 返回的数字经常是字符串，这里统一兼容。
struct JSONObject: @unchecked Sendable {
    let raw: [String: Any]

    init(_ raw: [String: Any] = [:]) { self.raw = raw }

    init?(data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        raw = obj
    }

    func string(_ key: String) -> String? {
        switch raw[key] {
        case let s as String: return s.isEmpty ? nil : s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    func double(_ key: String) -> Double? {
        if let n = raw[key] as? NSNumber { return n.doubleValue }
        return string(key).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    func int(_ key: String) -> Int? { double(key).map { Int($0) } }
    func int64(_ key: String) -> Int64? { double(key).map { Int64($0) } }

    func bool(_ key: String) -> Bool? {
        switch raw[key] {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return s == "1" || s.lowercased() == "true"
        default: return nil
        }
    }

    func object(_ key: String) -> JSONObject? {
        (raw[key] as? [String: Any]).map(JSONObject.init)
    }

    func array(_ key: String) -> [JSONObject] {
        (raw[key] as? [[String: Any]])?.map(JSONObject.init) ?? []
    }

    func strings(_ key: String) -> [String] {
        (raw[key] as? [Any])?.compactMap { $0 as? String } ?? []
    }
}

enum WebSSHError: LocalizedError, Equatable {
    case notConfigured
    case loginFailed(String)
    case unauthorized
    case forbidden(String)
    case api(Int, String)
    case ubus(String)
    case wrongPath
    case unreachable(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "还没有填写 WebSSH 密码。"
        case .loginFailed(let m): return "WebSSH 登录失败：\(m)"
        case .unauthorized: return "WebSSH 登录已失效。"
        case .forbidden(let m): return "WebSSH 拒绝了请求：\(m)"
        case .api(_, let m): return m
        case .ubus(let m): return "原厂接口调用失败：\(m)"
        case .wrongPath: return "WebSSH 没有这个接口，可能版本不同。"
        case .unreachable(let m): return "连不上 WebSSH：\(m)"
        case .invalidResponse: return "WebSSH 返回了无法识别的数据。"
        }
    }
}

/// `GET /api/mihomo/status`
struct MihomoServiceStatus: Sendable, Equatable {
    var running: Bool
    var pid: Int?
    var startTime: String?
    var binaryExists: Bool
    var binaryVersion: String?
    var apiReachable: Bool
    var autostart: Bool
    var missingFiles: [String]

    init(_ o: JSONObject) {
        running = o.bool("running") ?? false
        pid = o.int("pid").flatMap { $0 > 0 ? $0 : nil }
        startTime = o.string("start_time")
        binaryExists = o.bool("binary_exists") ?? false
        binaryVersion = o.string("binary_version")
        apiReachable = o.bool("api_reachable") ?? false
        autostart = o.bool("autostart_enabled") ?? false
        missingFiles = o.array("files").filter { $0.bool("exists") == false }.compactMap { $0.string("desc") ?? $0.string("name") }
    }

    init(running: Bool, pid: Int?, startTime: String?, binaryVersion: String?, apiReachable: Bool, autostart: Bool, missingFiles: [String] = []) {
        self.running = running
        self.pid = pid
        self.startTime = startTime
        self.binaryExists = binaryVersion != nil
        self.binaryVersion = binaryVersion
        self.apiReachable = apiReachable
        self.autostart = autostart
        self.missingFiles = missingFiles
    }
}

enum ProxyAction: String, Sendable {
    case start, stop, restart
    case reloadIPSet = "reload-ipset"

    var title: String {
        switch self {
        case .start: return "启动代理"
        case .stop: return "停用代理"
        case .restart: return "重启代理核心"
        case .reloadIPSet: return "重新加载 IP 段"
        }
    }
}

/// `GET /api/mihomo/data/update/status`
struct DataUpdateStatus: Sendable, Equatable {
    var state: String
    var message: String
    var fileName: String?
    var fileIndex: Int
    var fileTotal: Int
    var percent: Int

    init(_ o: JSONObject) {
        state = o.string("state") ?? "idle"
        message = o.string("msg") ?? ""
        fileName = o.string("file_name")
        fileIndex = o.int("file_index") ?? 0
        fileTotal = o.int("file_total") ?? 0
        percent = o.int("percent") ?? 0
    }

    init(state: String, message: String, fileName: String? = nil, fileIndex: Int = 0, fileTotal: Int = 0, percent: Int = 0) {
        self.state = state
        self.message = message
        self.fileName = fileName
        self.fileIndex = fileIndex
        self.fileTotal = fileTotal
        self.percent = percent
    }

    var isRunning: Bool { state == "downloading" }
}

struct DataVersion: Sendable {
    var local: String?
    var remote: String?
    var hasUpdate: Bool
}

struct ConfigCheckResult: Sendable, Hashable {
    var ok: Bool
    var message: String
    var output: String
}

/// 设备状态快照；由 WebSSH / ubus 或 UFI-TOOLS / goform 适配器提供，缺失能力保留 nil。
struct DeviceSnapshot: Sendable, Equatable, Codable {
    // 蜂窝
    var operatorName: String?
    var networkType: String?
    var signalBars: Int?
    var rsrp: Double?
    var rsrq: Double?
    var sinr: Double?
    var band: String?
    var pci: String?
    var channel: String?
    var netSelect: String?
    var wanIPv4: String?
    var connected: Bool?
    /// 可选蜂窝接口失败不影响身份与系统状态；用于明确区分未读取与未联网。
    var cellularStatusError: String?
    // 流量（字节）
    var rxSpeed: Int64 = 0
    var txSpeed: Int64 = 0
    var dayRx: Int64?
    var dayTx: Int64?
    var monthRx: Int64?
    var monthTx: Int64?
    // 电池与系统
    var battery: Int?
    var charging = false
    var batteryTemp: Double?
    var uptime: Int?
    var cpuTemp: Double?
    var memTotalKB: Int64?
    var memAvailKB: Int64?
    // 标识（默认在界面上遮挡）
    var identitySerial: String?
    var imei: String?
    var iccid: String?
    var imsi: String?
    var msisdn: String?
    // 型号与版本
    var model: String?
    var marketName: String?
    var firmware: String?
    var integrateVersion: String?
    var hardware: String?
    // Wi-Fi 与客户端
    var ssid24: String?
    var ssid5: String?
    var radio24On: Bool?
    var radio5On: Bool?
    var clientsTotal: Int?
    var clientsWifi: Int?
    var clientsLan: Int?

    /// Android F50 使用硬件序列号，U60 沿用原有 IMEI 指纹，避免破坏已绑定记录。
    var identityFingerprint: String? {
        if model == "MU300", let identitySerial, !identitySerial.isEmpty {
            return DeviceIdentity.digest(Data("ufi|MU300|\(identitySerial)".utf8))
        }
        return DeviceIdentity.fingerprint(model: model, imei: imei)
    }

    /// 当前读数来自 5G NR（否则是 4G LTE）。
    var isNR = false

    var bandLabel: String? {
        guard let band, !band.isEmpty else { return nil }
        if band.first?.isLetter == true { return band }
        return (isNR ? "n" : "B") + band
    }

    var signalQuality: String {
        guard let rsrp else { return "—" }
        if rsrp >= -90 { return "很好" }
        if rsrp >= -105 { return "良好" }
        if rsrp >= -115 { return "一般" }
        return "较弱"
    }
}

extension DeviceSnapshot {
    /// 把一组 ubus 结果拼成快照。键是请求时的服务名。
    init(
        netinfo n: JSONObject?, traffic t: JSONObject?, device d: JSONObject?, cpuTemp c: JSONObject?,
        mdm m: JSONObject?, sim s: JSONObject?, common cc: JSONObject?, wlan w: JSONObject?,
        users u: JSONObject?, wan: JSONObject?
    ) {
        if let n {
            operatorName = n.string("network_provider_fullname") ?? Self.operatorName(code: n.string("network_provider"))
            networkType = n.string("network_type")
            signalBars = n.int("signalbar")
            netSelect = n.string("net_select")
            let nrRSRP = n.double("nr5g_rsrp")
            if let nrRSRP {
                isNR = true
                rsrp = nrRSRP
                rsrq = n.double("nr5g_rsrq")
                sinr = n.double("nr5g_snr")
                band = n.string("nr5g_action_band")
                pci = n.string("nr5g_pci")
                channel = n.string("nr5g_action_channel")
            } else {
                rsrp = n.double("lte_rsrp")
                rsrq = n.double("lte_rsrq")
                sinr = n.double("lte_snr")
                band = n.string("lte_band")
                pci = n.string("lte_pci")
                channel = n.string("lte_action_channel")
            }
        }
        if let t {
            rxSpeed = t.int64("real_rx_speed") ?? 0
            txSpeed = t.int64("real_tx_speed") ?? 0
            dayRx = t.int64("day_rx_bytes")
            dayTx = t.int64("day_tx_bytes")
            monthRx = t.int64("month_rx_bytes")
            monthTx = t.int64("month_tx_bytes")
        }
        if let d {
            battery = d.int("bat_percent")
            charging = d.string("bat_charger_connect") == "1"
            batteryTemp = d.double("bat_temperature")
            uptime = d.int("device_uptime")
            if let mem = d.object("meminfo") {
                memTotalKB = mem.int64("total")
                memAvailKB = mem.int64("avaliable") ?? mem.int64("available") ?? mem.int64("free")
            }
        }
        cpuTemp = c?.double("cpuss_temp")
        if let v = m?.object("values") {
            imei = v.string("imei")
            msisdn = v.string("msisdn")
        }
        if let s {
            iccid = s.string("sim_iccid")
            imsi = s.string("sim_imsi")
            msisdn = msisdn ?? s.string("msisdn")
        }
        if let v = cc?.object("values") {
            model = v.string("model_name")
            marketName = v.string("device_market_name")
            firmware = v.string("wa_inner_version")
            integrateVersion = v.string("integrate_version")
            hardware = v.string("hardware_version")
        }
        if let w {
            ssid24 = w.string("main2g_ssid")
            ssid5 = w.string("main5g_ssid")
            radio24On = w.string("radio2_disabled").map { $0 != "1" }
            radio5On = w.string("radio5_disabled").map { $0 != "1" }
        }
        if let u {
            clientsTotal = u.int("access_total_num")
            clientsWifi = u.int("wireless_num")
            clientsLan = u.int("lan_num")
        }
        if let wan {
            wanIPv4 = wan.string("ipv4_address")
            connected = wan.string("connect_status").map { $0.lowercased().contains("connected") && !$0.lowercased().contains("disconnected") }
        }
    }

    static func operatorName(code: String?) -> String? {
        switch code?.uppercased() {
        case "CMCC": return "中国移动"
        case "CUCC", "UNICOM": return "中国联通"
        case "CT": return "中国电信"
        case "CBN": return "中国广电"
        default: return code
        }
    }
}

/// 局域网客户端：原厂的接入列表加上 iwinfo 的信号与速率。
struct LANClient: Identifiable, Sendable, Equatable {
    var id: String { mac }
    var hostname: String
    var ip: String
    var mac: String
    var interface: String
    var signal: Int?
    var rateKbps: Int?
    var accessTime: String?
}

struct SMSMessage: Identifiable, Sendable, Equatable {
    var id: Int
    var number: String
    var date: String
    var content: String
    var tag: String

    /// 原厂短信库里 tag 为 1 表示未读，标记已读时改为 0。
    var unread: Bool { tag == "1" }
}

struct WifiRadioSettings: Sendable, Equatable {
    var txPower: String
    var country: String
}

/// 原厂网络模式取值与显示名（取值来自 WebSSH network_settings.go）。
enum NetworkMode: String, CaseIterable, Identifiable, Sendable {
    case auto = "WL_AND_5G"
    case sa = "Only_5G"
    case nsa = "LTE_AND_5G"
    case lte3g = "WCDMA_AND_LTE"
    case lteOnly = "Only_LTE"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "5G / 4G / 3G 自动"
        case .sa: return "仅 5G SA"
        case .nsa: return "5G NSA"
        case .lte3g: return "4G / 3G"
        case .lteOnly: return "仅 4G"
        }
    }

    static let lteBands = [1, 2, 3, 4, 5, 7, 8, 18, 19, 20, 26, 28, 29, 32, 34, 38, 39, 40, 41, 42, 43, 48, 66, 71]
    static let nrBands = [1, 2, 3, 5, 7, 8, 18, 20, 26, 28, 29, 38, 40, 41, 48, 66, 71, 75, 77, 78, 79]
}

enum Masking {
    /// 只保留最后 4 位。
    static func tail(_ s: String?, keep: Int = 4) -> String {
        guard let s, !s.isEmpty else { return "—" }
        guard s.count > keep else { return s }
        return String(repeating: "•", count: min(8, s.count - keep)) + s.suffix(keep)
    }
}
