import Darwin
import SwiftUI

/// 只枚举本机 IPv4，用于防止误封当前管理手机，不读取 Wi-Fi 名称或定位信息。
enum LocalAddresses {
    static func ipv4() -> Set<String> {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else {
            return []
        }
        defer {
            freeifaddrs(head)
        }
        var result = Set<String>()
        var cursor = head
        while let item = cursor {
            defer {
                cursor = item.pointee.ifa_next
            }
            guard let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.insert(String(cString: buffer))
            }
        }
        return result
    }
}

struct ClientsView: View {
    @Environment(DeviceStatusStore.self) private var status
    @Environment(DeviceStore.self) private var devices
    @Environment(ManagementStore.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @State private var selected: LANClient?
    @State private var blocked: Set<String> = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        DetailSheet(title: "接入设备") {
            if loading {
                ProgressView("读取客户端…")
            }
            if let error {
                Text(error).foregroundStyle(.orange)
            }
            GlassSection {
                ForEach(status.clients) { client in
                    Button {
                        selected = client
                    } label: {
                        HStack {
                            FeatureIcon(symbol: client.interface == "Ethernet" ? "cable.connector" : "wifi")
                            VStack(alignment: .leading, spacing: 4) {
                                Text(note(client).ifEmpty(client.hostname))
                                Text("\(client.ip) · \(client.interface)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if blocked.contains(client.mac.uppercased()) {
                                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                            }
                            Image(systemName: "chevron.right").font(.caption.weight(.medium))
                        }
                    }.foregroundStyle(.primary)
                }
                if !loading && status.clients.isEmpty {
                    Text("没有接入设备").foregroundStyle(.secondary)
                }
                Button("刷新列表") {
                    Task {
                        await load()
                    }
                }
            }
            if !blocked.isEmpty {
                GlassSection("已阻止的 Wi-Fi 设备") {
                    ForEach(blocked.sorted(), id: \.self) { mac in
                        HStack {
                            Text(mac).font(.caption.monospaced())
                            Spacer()
                            Button("解除") {
                                Task {
                                    await manager.run("解除 Wi-Fi 阻止") {
                                        let api = try await manager.verifiedAPI(devices)
                                        try await api.setClientBlocked(mac: mac, blocked: false)
                                    }
                                    await load()
                                }
                            }
                        }
                    }
                }.disabled(manager.working)
            }
            GlassSection("已阻止的设备") {
                if blocked.isEmpty { Text("没有已阻止设备").font(.footnote.weight(.medium)).foregroundStyle(.secondary) }
                ForEach(blocked.sorted(), id: \.self) { mac in
                    HStack {
                        Text(mac).font(.caption.monospaced())
                        Spacer()
                        Button("解除阻止") {
                            Task {
                                await manager.run("解除设备阻止") {
                                    let api = try await manager.verifiedAPI(devices)
                                    try await api.setClientBlocked(mac: mac, blocked: false)
                                }
                                await load()
                            }
                        }.disabled(manager.working || devices.readOnly)
                    }
                }
            }
            ManagementProgress()
        }
        .task {
            await load()
        }
        .appPush(
            item: $selected, onDismiss: { Task { await load() } },
            content: { client in
                ClientDetailView(client: client, blocked: blocked.contains(client.mac.uppercased()))
            })
    }

    private func note(_ client: LANClient) -> String {
        UserDefaults.standard.string(forKey: "client.note.\(devices.storageID).\(client.mac.uppercased())") ?? ""
    }

    private func load() async {
        loading = true
        error = nil
        defer {
            loading = false
        }
        await status.loadClients()
        do {
            blocked = try await devices.webClient.blockedClients()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ClientDetailView: View {
    let client: LANClient
    @State var blocked: Bool
    @Environment(DeviceStore.self) private var devices
    @Environment(ManagementStore.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var confirm = false
    private var ownDevice: Bool {
        devices.demoMode ? client.hostname == "iPhone" : LocalAddresses.ipv4().contains(client.ip)
    }

    var body: some View {
        DetailSheet(title: client.hostname) {
            ManagementProgress()
            GlassSection("设备详情") {
                LabeledContent("IP 地址", value: client.ip)
                LabeledContent("MAC", value: client.mac)
                LabeledContent("接口", value: client.interface)
                LabeledContent("接入时长", value: client.accessTime ?? "未知")
                if let signal = client.signal {
                    LabeledContent("信号", value: "\(signal) dBm")
                }
                if let rate = client.rateKbps {
                    LabeledContent("连接速率", value: "\(rate / 1000) Mbps")
                }
                if ownDevice {
                    Label("本机 · 已保护", systemImage: "iphone")
                }
            }
            GlassSection("本机备注") {
                TextField("例如：客厅电视", text: $note)
                Button("保存备注") {
                    UserDefaults.standard.set(String(note.prefix(60)), forKey: "client.note.\(devices.storageID).\(client.mac.uppercased())")
                    dismiss()
                }
            }
            GlassSection {
                Button(blocked ? "允许 Wi-Fi 接入" : "阻止 Wi-Fi 接入", role: blocked ? nil : .destructive) {
                    confirm = true
                }
                .disabled(ownDevice || client.interface == "Ethernet" || manager.working || (!devices.demoMode && LocalAddresses.ipv4().isEmpty))
            } footer: {
                Text(ownDevice ? "禁止阻止当前管理手机，避免失去管理连接。" : "阻止针对当前 MAC 的双频 Wi-Fi 接入；使用私有地址的设备更换 MAC 后需重新设置。有线接入不使用 Wi-Fi 黑名单。")
            }
        }
        .onAppear {
            note = UserDefaults.standard.string(forKey: "client.note.\(devices.storageID).\(client.mac.uppercased())") ?? ""
        }
        .confirmationDialog(blocked ? "允许此设备重新接入？" : "阻止此设备的 Wi-Fi 接入？", isPresented: $confirm, titleVisibility: .visible) {
            Button(blocked ? "允许接入" : "阻止接入", role: blocked ? nil : .destructive) {
                Task {
                    await manager.run("更新接入权限") {
                        let api = try await manager.verifiedAPI(devices)
                        guard !ownDevice else {
                            throw ManagementError.invalid("不能阻止当前管理手机。")
                        }
                        try await api.setClientBlocked(mac: client.mac, blocked: !blocked)
                        blocked.toggle()
                        await manager.setStage("接入权限已回读确认", progress: 1)
                    }
                }
            }
        }
    }
}

/// 收件箱仅展示摘要；完整内容和已读操作进入独立详情，避免长短信占满列表。
struct SMSView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(DeviceStatusStore.self) private var status
    @Environment(DeviceStore.self) private var devices
    @Environment(ManagementStore.self) private var manager
    @State private var composing = false
    @State private var loading = false
    @State private var selected: SMSMessage?
    @State private var query = ""
    @State private var unreadOnly = false

    private var messages: [SMSMessage] {
        status.messages.filter {
            (!unreadOnly || $0.unread)
                && (query.isEmpty || $0.number.localizedCaseInsensitiveContains(query)
                    || $0.content.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        DetailSheet(
            title: "短信", primaryTitle: "写短信", primaryDisabled: devices.readOnly,
            onPrimary: { composing = true }
        ) {
            HStack {
                Text("\(status.messages.count) 条短信 · \(status.unreadCount) 条未读")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Toggle("仅看未读", isOn: $unreadOnly)
                    Button("刷新", systemImage: "arrow.clockwise") { Task { await refresh() } }
                    Button("全部标为已读", systemImage: "envelope.open") { markAllRead() }
                        .disabled(status.unreadCount == 0 || manager.working || devices.readOnly)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease").frame(width: 44, height: 44)
                }
                .accessibilityLabel("短信筛选与操作")
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索号码或内容", text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if !query.isEmpty {
                    Button("清除", systemImage: "xmark.circle.fill") { query = "" }.labelStyle(.iconOnly)
                }
            }
            .padding(12).background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            if loading { ProgressView("读取短信…") }
            if let notice = status.notice { Text(notice).font(.footnote.weight(.medium)).foregroundStyle(.orange) }
            if manager.operationTitle == "标记已读" { ManagementProgress() }
            if !messages.isEmpty {
                GlassSection {
                    LazyVStack(spacing: 0) {
                        ForEach(messages) { message in
                            if message.id != messages.first?.id { Divider().padding(.vertical, 12) }
                            Button {
                                selected = message
                            } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        if message.unread {
                                            Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                                        }
                                        Text(message.number).font(.headline).foregroundStyle(.primary)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 4)
                                        Image(systemName: "chevron.right").font(.caption.weight(.medium)).foregroundStyle(.tertiary)
                                    }
                                    Text(message.content).font(.subheadline.weight(.medium)).foregroundStyle(.secondary).lineLimit(2)
                                    Text(message.date).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(message.number)，\(message.unread ? "未读" : "已读")，\(message.content)")
                        }
                    }
                }
            } else if !loading {
                ContentUnavailableView(
                    query.isEmpty && !unreadOnly ? "没有短信" : "没有匹配的短信",
                    systemImage: "tray", description: Text("可调整筛选，或下拉重新读取。"))
            }
        }
        .opacity(scenePhase == .active ? 1 : 0)
        .accessibilityHidden(scenePhase != .active)
        .task { await refresh() }
        .refreshable { await refresh() }
        .appModal(isPresented: $composing) { SMSComposerView() }
        .appPush(item: $selected) { message in SMSDetailView(message: message) }
    }

    private func refresh() async {
        loading = true
        status.notice = nil
        await status.loadMessages()
        loading = false
    }

    private func markAllRead() {
        Task {
            await manager.run("标记已读") {
                let api = try await manager.verifiedAPI(devices)
                for message in status.messages where message.unread {
                    try await api.markSMSRead(id: message.id)
                }
                await status.loadMessages()
                guard status.unreadCount == 0 else {
                    throw ManagementError.unconfirmed("部分短信仍未标记，请刷新检查。")
                }
            }
        }
    }
}

/// 阅读不自动写入路由器；用户可显式标为已读，失败时保留原状态。
private struct SMSDetailView: View {
    @Environment(\.scenePhase) private var scenePhase
    let message: SMSMessage
    @Environment(DeviceStatusStore.self) private var status
    @Environment(DeviceStore.self) private var devices
    @State private var marking = false

    private var current: SMSMessage { status.messages.first { $0.id == message.id } ?? message }

    var body: some View {
        DetailSheet(title: "短信详情") {
            DeviceDetailSummary(
                symbol: current.unread ? "envelope.badge" : "envelope.open",
                title: current.number, subtitle: current.date)
            GlassSection {
                Text(current.content).font(.body.weight(.medium)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Label(current.unread ? "未读" : "已读", systemImage: current.unread ? "circle.fill" : "checkmark.circle")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if current.unread {
                    Button("标为已读") {
                        Task {
                            marking = true
                            await status.markRead(current)
                            marking = false
                        }
                    }
                    .disabled(marking || devices.readOnly)
                }
            }
            if let notice = status.notice { Text(notice).font(.footnote.weight(.medium)).foregroundStyle(.orange) }
        }
        .opacity(scenePhase == .active ? 1 : 0)
        .accessibilityHidden(scenePhase != .active)
    }
}

struct SMSComposerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(DeviceStore.self) private var devices
    @Environment(DeviceStatusStore.self) private var status
    @Environment(ManagementStore.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @State private var number = ""
    @State private var message = ""
    @State private var confirm = false
    @State private var sent = false
    @State private var submitted = false

    var body: some View {
        DetailSheet(
            title: "发送短信",
            doneTitle: "关闭",
            closeDisabled: manager.working,
            primaryTitle: sent ? "已发送" : "发送",
            primaryDisabled: number.isEmpty || message.isEmpty || message.utf16.count > 70 || manager.working || submitted,
            onPrimary: { confirm = true }
        ) {
            ManagementProgress()
            GlassSection {
                FormField("收件人") { TextField("收件人号码", text: $number) }.keyboardType(.phonePad)
                FormField("短信内容") {
                    TextEditor(text: $message)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 160)
                        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                }
                Text("\(message.utf16.count) / 70 UTF-16 单元").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            .disabled(sent)
            Text("使用设备 SIM 卡发送，可能产生短信费用。当前支持单条 Unicode 短信；提交后若状态不明，请先检查发件箱，避免重复发送。")
                .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
        }
        .interactiveDismissDisabled(manager.working)
        .confirmationDialog("发送给 \(number)？", isPresented: $confirm, titleVisibility: .visible) {
            Button("确认发送") {
                Task {
                    await manager.run("发送短信") {
                        let api = try await manager.verifiedAPI(devices)
                        try SMSValidation.validate(number: number, message: message)
                        submitted = true
                        try await api.sendSMS(number: number, message: message)
                        sent = true
                        await status.loadMessages()
                        await manager.setStage(devices.demoMode ? "演示：短信发送成功" : "设备已确认发送成功", progress: 1)
                    }
                }
            }
        }
    }
}
