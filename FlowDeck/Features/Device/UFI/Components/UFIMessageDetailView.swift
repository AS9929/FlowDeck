import SwiftUI

/// 单条短信页面只管理回复草稿与确认弹窗；删除、已读回读由上层固定会话执行。
struct UFIMessageDetailView: View {
    @Environment(ManagementStore.self) private var manager
    let message: SMSMessage
    let unread: Bool
    let password: String
    let busy: Bool
    let readOnly: Bool
    let error: String?
    let onMarkRead: () -> Void
    let onDelete: () -> Void
    @State private var replyNumber = ""
    @State private var replyText = ""
    @State private var composingReply = false
    @State private var confirmDelete = false
    var body: some View {
        DetailSheet(title: "短信详情", closeDisabled: busy) {
            GlassSection {
                Text(message.number).font(.title2.bold()).textSelection(.enabled)
                Text(UFIMailbox.status(message) + " · " + message.date).font(.caption).foregroundStyle(.secondary)
                Divider()
                Text(message.content).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            if unread {
                Button("标记为已读", systemImage: "envelope.open", action: onMarkRead)
                    .disabled(busy || readOnly)
            }
            if manager.operationTitle == "F50 短信标记已读" { ManagementProgress() }
            GlassSection("回复与转发") {
                Button("回复", systemImage: "arrowshape.turn.up.left") {
                    replyNumber = message.number
                    replyText = ""
                    composingReply = true
                }
                Button("编辑为新短信", systemImage: "square.and.pencil") {
                    replyNumber = message.number
                    replyText = message.content
                    composingReply = true
                }
                Button("转发", systemImage: "arrowshape.turn.up.right") {
                    replyNumber = ""
                    replyText = message.content
                    composingReply = true
                }
                Text("编辑或重发先创建新短信，原记录保留；确认后才发送。")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(busy || readOnly)
            Button("删除这条短信", systemImage: "trash", role: .destructive) { confirmDelete = true }
                .disabled(busy || readOnly)
            if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
        }
        .appModal(isPresented: $composingReply) {
            UFISMSComposerView(password: password, initialNumber: replyNumber, initialText: replyText)
        }
        .confirmationDialog("删除这条短信？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("永久删除", role: .destructive) { onDelete() }
        } message: {
            Text("短信将从 F50 消息记录移除，无法撤销。")
        }
    }

}
