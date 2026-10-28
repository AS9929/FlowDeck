import SwiftUI

/// 短信筛选和列表展示。输入与选择由父级持有，重新读取不会破坏本地筛选。
struct UFIInboxSection: View {
    let messages: [SMSMessage]
    let messageStorage: UFISMSStorage?
    let messageStorageError: String?
    let busy: Bool
    let readOnly: Bool
    let hasMore: Bool
    @Binding var query: String
    @Binding var unreadOnly: Bool
    @Binding var mailbox: UFIMailbox
    let onCompose: () -> Void
    let onSelect: (SMSMessage) -> Void
    let onLoadMore: () -> Void
    private var filteredMessages: [SMSMessage] {
        messages.filter {
            mailbox.contains($0) && (!unreadOnly || $0.unread)
                && (query.isEmpty || $0.number.localizedCaseInsensitiveContains(query)
                    || $0.content.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button("写短信", systemImage: "square.and.pencil") { onCompose() }
                .disabled(busy || readOnly)
            Picker("消息分类", selection: $mailbox) {
                ForEach(UFIMailbox.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.menu)
            UFISearchField(placeholder: "搜索号码或内容", query: $query)
            Toggle("仅看未读", isOn: $unreadOnly)
            Text("已读取 \(messages.count) 条 · \(messages.filter(\.unread).count) 条未读")
                .font(.subheadline).foregroundStyle(.secondary)
            if let messageStorage {
                Text(messageStorage.summary).font(.caption).foregroundStyle(.secondary)
            }
            if let messageStorageError {
                Text(messageStorageError).font(.footnote).foregroundStyle(.orange)
            }
            if filteredMessages.isEmpty {
                ContentUnavailableView {
                    Label(messages.isEmpty ? "设备未返回短信" : "没有匹配的短信", systemImage: "tray")
                } description: {
                    Text(
                        messages.isEmpty
                            ? "这里只显示当前 F50 保存的短信。可在原厂网页核对消息记录，然后下拉重新读取。"
                            : "尝试切换消息分类、关闭未读筛选或清除搜索。")
                }
            } else {
                GlassSection {
                    ForEach(filteredMessages) { message in
                        if message.id != filteredMessages.first?.id { Divider() }
                        Button {
                            onSelect(message)
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(spacing: 8) {
                                    if message.unread { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
                                    Text(message.number).font(.headline)
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right").font(.caption)
                                }
                                Text(message.content).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                Text(UFIMailbox.status(message) + " · " + message.date).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                        }.buttonStyle(.plain)
                    }
                }
            }
            if hasMore {
                Button("加载更多短信", systemImage: "arrow.down") { onLoadMore() }.disabled(busy)
            }
            Text("按已读取的消息筛选分类，加载更多可查看更早记录。读取不会自动标记已读；发送失败不会自动重发。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

}
