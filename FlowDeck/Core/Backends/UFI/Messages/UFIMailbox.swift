import Foundation

/// 原厂 tags=10 返回全部设备短信；tag 2 为已发、3 为发送失败、4 为草稿。
/// 仅在已加载页中筛选，避免伪装成服务端已完整搜索。
enum UFIMailbox: String, CaseIterable, Identifiable {
    case all, inbox, sent, failed, drafts
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "全部消息"
        case .inbox: "收件箱"
        case .sent: "已发送"
        case .failed: "发送失败"
        case .drafts: "草稿"
        }
    }

    func contains(_ message: SMSMessage) -> Bool {
        switch self {
        case .all: true
        case .inbox: ["0", "1"].contains(message.tag)
        case .sent: message.tag == "2"
        case .failed: message.tag == "3"
        case .drafts: message.tag == "4"
        }
    }

    static func status(_ message: SMSMessage) -> String {
        switch message.tag {
        case "0": "已读"
        case "1": "未读"
        case "2": "已发送"
        case "3": "发送失败"
        case "4": "草稿"
        default: "状态未知"
        }
    }
}
