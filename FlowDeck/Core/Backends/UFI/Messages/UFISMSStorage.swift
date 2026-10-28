import Foundation

/// 原厂短信存储计数。字段缺失不是零，SIM 中存在记录时须明确提示当前列表的边界。
struct UFISMSStorage {
    let received: Int
    let sent: Int
    let drafts: Int
    let sim: Int

    init(_ object: JSONObject) throws {
        func count(_ key: String) throws -> Int {
            guard let raw = object.string(key), let value = Int(raw), (0...100_000).contains(value) else {
                throw ManagementError.unconfirmed("设备未提供完整短信存储数量。")
            }
            return value
        }
        received = try count("sms_nv_rev_total")
        sent = try count("sms_nv_send_total")
        drafts = try count("sms_nv_draftbox_total")
        sim = try count("sms_sim_rev_total") + count("sms_sim_send_total") + count("sms_sim_draftbox_total")
    }

    var summary: String {
        "设备存储：收件 \(received) · 发件 \(sent) · 草稿 \(drafts) · SIM \(sim)"
    }

    func listWarning(loadedCount: Int) -> String? {
        if loadedCount == 0, received + sent + drafts > 0 {
            return "设备存储中有短信，但列表未返回记录。请重新读取或到原厂网页核对，不能按空收件箱处理。"
        }
        if sim > 0 {
            return "SIM 卡中还有 \(sim) 条短信，当前列表仅包含设备存储；SIM 记录请在原厂网页查看。"
        }
        return nil
    }
}
