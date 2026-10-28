import Foundation

/// F50 原厂数据解析。空列表和接口缺失分开处理，防止把认证失败显示为“没有设备/短信”。
enum UFIDeviceParser {
    static func clients(_ object: JSONObject) throws -> [LANClient] {
        guard let wireless = object.raw["station_list"] as? [[String: Any]],
            let wired = object.raw["lan_station_list"] as? [[String: Any]]
        else {
            throw ManagementError.unconfirmed("未获得完整接入列表，请验证原厂后台后重试。")
        }
        var result: [LANClient] = []
        var seen = Set<String>()
        for (items, interface) in [(wireless, "Wi-Fi"), (wired, "USB / 有线")] {
            for item in items {
                let value = JSONObject(item)
                guard let mac = value.string("mac_addr")?.uppercased(),
                    mac.range(of: "^[0-9A-F]{2}(:[0-9A-F]{2}){5}$", options: .regularExpression) != nil
                else {
                    throw ManagementError.unconfirmed("接入列表包含无效设备信息，请刷新重试。")
                }
                guard seen.insert(mac).inserted else { continue }
                result.append(
                    LANClient(
                        hostname: value.string("hostname").flatMap { $0.isEmpty ? nil : $0 } ?? "未命名设备",
                        ip: value.string("ip_addr") ?? "—", mac: mac, interface: interface,
                        signal: nil, rateKbps: nil, accessTime: nil))
            }
        }
        return result
    }

    static func messages(_ object: JSONObject) throws -> [SMSMessage] {
        guard let rows = object.raw["messages"] as? [[String: Any]] else {
            throw ManagementError.unconfirmed("短信接口未返回消息列表，请验证原厂后台后重试。")
        }
        var seen = Set<Int>()
        return try rows.map { row in
            let value = JSONObject(row)
            guard let rawID = value.string("id"), let id = Int(rawID), id >= 0,
                seen.insert(id).inserted, let number = value.string("number"),
                let tag = value.string("tag"), ["0", "1", "2", "3", "4"].contains(tag),
                let encoded = value.string("content"), let data = Data(base64Encoded: encoded),
                let content = String(data: data, encoding: .utf8)
            else {
                throw ManagementError.unconfirmed("短信格式无法识别，未将异常内容当成空列表。")
            }
            return SMSMessage(
                id: id, number: number, date: dateLabel(value.string("date") ?? ""),
                content: content, tag: tag)
        }
    }

    /// 固件日期是 yy,MM,dd,HH,mm,ss,+zone；展示设备记录，不擅自套手机时区。
    static func dateLabel(_ raw: String) -> String {
        let parts = raw.split(separator: ",").map(String.init)
        guard parts.count >= 6, parts.prefix(6).allSatisfy({ Int($0) != nil }) else {
            return raw.isEmpty ? "时间未提供" : raw
        }
        let year = parts[0].count == 2 ? "20" + parts[0] : parts[0]
        return "\(year)-\(parts[1])-\(parts[2]) \(parts[3]):\(parts[4]):\(parts[5])"
    }
}

/// 仅开放有原厂协议证据的动作；发送短信、恢复出厂等另有流程，不通过任意字典透传。
enum UFIFactoryAction: Sendable, Equatable {
    case markMessageRead(Int)
    case reboot

    func form() throws -> [String: String] {
        var fields = ["isTest": "false"]
        switch self {
        case .markMessageRead(let id):
            guard id >= 0 else { throw ManagementError.invalid("短信编号无效。") }
            fields["goformId"] = "SET_MSG_READ"
            fields["msg_id"] = "\(id);"
            fields["tag"] = "0"
        case .reboot:
            fields["goformId"] = "REBOOT_DEVICE"
        }
        return fields
    }
}

/// Android 系统统计不冒充 U60 原厂流量计数；单位在模型处统一校验。
struct UFIHardwareDetails: Sendable {
    let version: String?
    let cpuTemperature: Double?
    let cpuUsage: Double?
    let memoryUsage: Double?
    let availableStorage: Int64?
    let totalStorage: Int64?
    let dailyBytes: Int64?
    let monthlyBytes: Int64?
    let usbSpeedMbps: Int?

    init(system: JSONObject, usb: JSONObject?) {
        version = system.string("app_ver")
        cpuTemperature = system.double("cpu_temp").flatMap { (-20...150).contains($0) ? $0 : nil }
        cpuUsage = system.double("cpu_usage").flatMap { (0...100).contains($0) ? $0 : nil }
        memoryUsage = system.double("mem_usage").flatMap { (0...100).contains($0) ? $0 : nil }
        func bytes(_ key: String) -> Int64? {
            guard let text = system.string(key), let value = Int64(text), value >= 0 else { return nil }
            return value
        }
        availableStorage = bytes("internal_available_storage")
        totalStorage = bytes("internal_total_storage")
        dailyBytes = bytes("daily_data")
        monthlyBytes = bytes("monthly_data")
        usbSpeedMbps = usb?.string("maxSpeed").flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
    }
}
