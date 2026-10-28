import SwiftUI

/// 按实际能力组织 F50 原生页面；原厂会话、系统统计和维护动作分别处理。
struct UFIDetailView: View {
    typealias Section = UFIDetailSection

    let section: Section
    @Environment(DeviceStore.self) private var devices
    @Environment(ManagementStore.self) private var manager
    @Environment(DeviceStatusStore.self) private var status
    @Environment(\.scenePhase) private var scenePhase
    @State private var password = ""
    @State private var revision = 0
    @State private var loading = false
    @State private var loaded = false
    @State private var credentialWarning: String?
    @State private var error: String?
    @State private var notice: String?
    @State private var clients: [LANClient] = []
    @State private var messages: [SMSMessage] = []
    @State private var messageStorage: UFISMSStorage?
    @State private var messageStorageError: String?
    @State private var factory = JSONObject()
    @State private var hardware: UFIHardwareDetails?
    @State private var access: UFIClientAccess?
    @State private var accessError: String?
    @State private var accessAction: UFIClientAccess.Entry?
    @State private var shouldBlock = false
    @State private var query = ""
    @State private var unreadOnly = false
    @State private var mailbox = UFIMailbox.all
    @State private var page = 0
    @State private var hasMore = false
    @State private var selectedMessage: SMSMessage?
    @State private var confirmReboot = false
    @State private var composing = false
    @State private var requestedRoaming: Bool?
    @State private var radio = false
    @State private var advanced: UFIAdvancedSettingsView.Kind?

    private var busy: Bool { loading || manager.working }
    var body: some View {
        DetailSheet(title: section.title, closeDisabled: busy) {
            DeviceDetailSummary(symbol: section.symbol, title: section.title, subtitle: section.subtitle)
            if loading { ProgressView("正在读取…").frame(maxWidth: .infinity) }
            if let credentialWarning {
                Text(credentialWarning).font(.footnote).foregroundStyle(.orange)
            }
            if let error { Text(error).font(.footnote.weight(.medium)).foregroundStyle(.orange) }
            if let notice { Label(notice, systemImage: "checkmark.circle").font(.footnote) }
            if loaded {
                switch section {
                case .clients:
                    UFIClientListSection(
                        clients: clients, access: access, accessError: accessError,
                        busy: busy, readOnly: devices.readOnly, query: $query
                    ) { entry, blocked in
                        shouldBlock = blocked
                        accessAction = entry
                    }
                case .messages:
                    UFIInboxSection(
                        messages: messages, messageStorage: messageStorage,
                        messageStorageError: messageStorageError, busy: busy,
                        readOnly: devices.readOnly, hasMore: hasMore,
                        query: $query, unreadOnly: $unreadOnly, mailbox: $mailbox,
                        onCompose: { composing = true }, onSelect: { selectedMessage = $0 },
                        onLoadMore: { Task { await load(more: true) } }
                    )
                case .cellular:
                    UFICellularDetailSection(
                        factory: factory, busy: busy, readOnly: devices.readOnly,
                        onAdvanced: { advanced = $0 }, onRadio: { radio = true },
                        onRoaming: { requestedRoaming = $0 }
                    )
                case .hardware: UFIHardwareDetailSection(hardware: hardware, onUSB: { advanced = .usb })
                case .maintenance: maintenance
                }
            }
            if section.needsFactory {
                GlassSection("原厂后台连接") {
                    SecureField("原厂网页登录密码", text: $password).textContentType(.password)
                    Button(loaded ? "重新读取" : "验证并读取", systemImage: "arrow.clockwise") {
                        Task { await load() }
                    }
                    .disabled(busy || password.isEmpty)
                } footer: {
                    Text("与 UFI 口令、Wi-Fi 密码不同。验证后保存在本机钥匙串，供原厂功能共用。")
                }
                .disabled(busy)
            } else {
                Button("刷新状态", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(busy)
            }
        }
        .task(id: devices.clientRevision) { await reloadDevice() }
        .refreshable { if !busy { await load() } }
        .appPush(item: $selectedMessage) { message in
            UFIMessageDetailView(
                message: message, unread: messages.first { $0.id == message.id }?.unread == true,
                password: password, busy: busy, readOnly: devices.readOnly, error: error,
                onMarkRead: { Task { await markRead(message) } },
                onDelete: { Task { await delete(message) } }
            )
        }
        .appPush(isPresented: $radio) { UFIRadioView() }
        .appPush(item: $advanced) { UFIAdvancedSettingsView(kind: $0) }
        .appModal(isPresented: $composing) { UFISMSComposerView(password: password) }
        .confirmationDialog(
            shouldBlock ? "阻止此设备连接 Wi-Fi？" : "解除阻止？",
            isPresented: Binding(
                get: { accessAction != nil }, set: { if !$0 { accessAction = nil } }
            ), titleVisibility: .visible
        ) {
            if let target = accessAction {
                Button(shouldBlock ? "加入黑名单" : "解除阻止", role: shouldBlock ? .destructive : nil) {
                    Task { await changeAccess(target, blocked: shouldBlock) }
                }
            }
        } message: {
            Text("只修改所选终端，保留原有白名单和过滤策略。可在黑名单中解除阻止。")
        }
        .confirmationDialog(
            "修改数据漫游？",
            isPresented: Binding(
                get: { requestedRoaming != nil }, set: { if !$0 { requestedRoaming = nil } }
            ), titleVisibility: .visible
        ) {
            if let enabled = requestedRoaming {
                Button(enabled ? "允许漫游" : "关闭漫游") { Task { await changeRoaming(enabled) } }
            }
        } message: {
            Text("允许漫游可能产生额外流量费用，设置会保留当前连接方式。")
        }
        .confirmationDialog("重启 F50？", isPresented: $confirmReboot, titleVisibility: .visible) {
            Button("重启设备", role: .destructive) { Task { await reboot() } }
        } message: {
            Text("热点、USB 网络和代理会暂时断开。请保持供电，重新连接热点后可回到 App 检查。")
        }
        .opacity(section == .messages && scenePhase != .active ? 0 : 1)
        .accessibilityHidden(section == .messages && scenePhase != .active)
    }

    /// 新会话开始时清除旧原厂数据和弹窗；旧请求通过修订检查丢弃。
    private func reloadDevice() async {
        revision = devices.clientRevision
        credentialWarning = nil
        loaded = false
        loading = false
        clients = []
        access = nil
        accessError = nil
        accessAction = nil
        messages = []
        messageStorage = nil
        messageStorageError = nil
        mailbox = .all
        unreadOnly = false
        factory = JSONObject()
        hardware = nil
        page = 0
        hasMore = false
        selectedMessage = nil
        confirmReboot = false
        composing = false
        requestedRoaming = nil
        advanced = nil
        radio = false
        error = nil
        notice = nil
        password = devices.current.map { devices.factoryPassword(for: $0) } ?? ""
        if !section.needsFactory || !password.isEmpty { await load() }
    }

    private var maintenance: some View {
        VStack(spacing: 20) {
            GlassSection("Mihomo 配置") {
                Button {
                    Task { await checkConfiguration() }
                } label: {
                    SettingsRow("校验当前配置", symbol: "checkmark.shield", subtitle: "只校验，不重启代理")
                }.disabled(busy)
            }
            GlassSection("设备恢复") {
                Button {
                    confirmReboot = true
                } label: {
                    SettingsRow("重启 F50", symbol: "arrow.clockwise", subtitle: "断网后等待设备恢复并验证身份")
                }.disabled(busy || devices.readOnly)
            }
            if manager.operationTitle == "重启 F50" { ManagementProgress() }
        }
    }

    private func markRead(_ message: SMSMessage) async {
        let expected = revision
        let currentPassword = password
        let messagePage = (messages.firstIndex { $0.id == message.id } ?? 0) / 20
        await manager.run("F50 短信标记已读") {
            let api = try await manager.verifiedService(
                (any UFIMessagesService).self, devices: devices, revision: expected, capability: .factoryControl)
            let confirmed = try await UFIFactoryOperations.markRead(
                message, page: messagePage, password: currentPassword, api: api)
            guard expected == devices.clientRevision else { throw ManagementError.deviceChanged }
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index] = confirmed
            }
        }
    }

    private func changeAccess(_ entry: UFIClientAccess.Entry, blocked: Bool) async {
        guard let access else { return }
        let expected = revision
        let currentPassword = password
        accessAction = nil
        await manager.run(blocked ? "阻止 F50 接入设备" : "解除 F50 设备阻止") {
            let api = try await manager.verifiedService(
                (any UFIDeviceService).self, devices: devices, revision: expected, capability: .factoryControl)
            try await api.setClientBlocked(
                mac: entry.mac, name: entry.name, blocked: blocked,
                replacing: access, password: currentPassword)
        }
        guard expected == devices.clientRevision else { return }
        let failure = manager.error
        await load()
        error = failure ?? error
    }

    private func changeRoaming(_ enabled: Bool) async {
        let expected = revision
        let currentPassword = password
        requestedRoaming = nil
        await manager.run("F50 数据漫游") {
            let api = try await manager.verifiedService(
                (any UFIDeviceService).self, devices: devices, revision: expected, capability: .factoryControl)
            try await api.setRoaming(enabled, password: currentPassword)
        }
        guard expected == devices.clientRevision else { return }
        let failure = manager.error
        await load()
        error = failure ?? error
    }

    private func delete(_ message: SMSMessage) async {
        let expected = revision
        let currentPassword = password
        await manager.run("删除 F50 短信") {
            let api = try await manager.verifiedService(
                (any UFIDeviceService).self, devices: devices, revision: expected, capability: .factoryControl)
            try await api.deleteMessage(id: message.id, password: currentPassword)
        }
        guard expected == devices.clientRevision else { return }
        error = manager.error
        if error == nil {
            selectedMessage = nil
            await load()
        }
    }

    private func client() throws -> any UFIDeviceService {
        try DeviceServiceContext(devices, revision: revision).service((any UFIDeviceService).self)
    }

    /// 切换设备后旧响应不进入新页面；分页保留已读取短信且按 id 去重。
    private func load(more: Bool = false) async {
        guard !loading else { return }
        let currentRevision = revision
        loading = true
        defer { if currentRevision == revision { loading = false } }
        do {
            let context = try DeviceServiceContext(devices, revision: currentRevision)
            let reader = UFIFactoryReadService(context: context, password: password)
            let api = try context.service((any UFIDeviceService).self)
            if section.needsFactory {
                credentialWarning = try await reader.authenticate()
            } else {
                credentialWarning = nil
            }
            try context.validate()
            switch section {
            case .clients:
                let result = try await reader.clients()
                try context.validate()
                clients = result.clients
                access = result.access
                accessError = result.accessError
            case .messages:
                let next = more ? page + 1 : 0
                let result = try await reader.messages(page: next, includeStorage: !more)
                try context.validate()
                messages = more ? messages + result.messages.filter { item in !messages.contains { $0.id == item.id } } : result.messages
                page = next
                hasMore = result.messages.count == 20 && next < 99
                if !more {
                    messageStorage = result.storage
                    messageStorageError = result.storageError
                }
            case .cellular:
                let value = try await api.factoryDetails(password: password)
                guard currentRevision == devices.clientRevision else { return }
                factory = value
                await status.refreshSnapshot()
            case .hardware:
                let value = try await api.hardwareDetails()
                guard currentRevision == devices.clientRevision else { return }
                hardware = value
            case .maintenance: break
            }
            guard currentRevision == devices.clientRevision else { return }
            loaded = true
            error = nil
        } catch {
            guard currentRevision == devices.clientRevision else { return }
            self.error = error.localizedDescription
        }
    }

    /// 校验响应只更新发起请求的设备页面，避免切换设备后显示旧结果。
    private func checkConfiguration() async {
        guard !busy else { return }
        let expectedRevision = revision
        loading = true
        notice = nil
        error = nil
        defer {
            if expectedRevision == devices.clientRevision { loading = false }
        }
        do {
            let result = try await client().checkConfig()
            guard expectedRevision == devices.clientRevision else { return }
            notice = result.ok ? "当前配置校验通过" : nil
            error = result.ok ? nil : "当前配置校验失败，请在 Mihomo 网页检查。"
        } catch {
            guard expectedRevision == devices.clientRevision else { return }
            self.error = error.localizedDescription
        }
    }

    /// POST 至多一次。设备重启可能先断开响应，仍通过身份和启动时长验证，绝不据此重发。
    private func reboot() async {
        let expectedRevision = revision
        let currentPassword = password
        notice = nil
        error = nil
        await manager.run("重启 F50") {
            let api = try await manager.verifiedService(
                (any UFIDeviceService).self, devices: devices, revision: expectedRevision, capability: .factoryControl)
            try await UFIFactoryOperations.reboot(api: api, password: currentPassword) {
                guard expectedRevision == devices.clientRevision else { throw ManagementError.deviceChanged }
            }
            notice = "设备已重新启动，身份与运行时长已确认"
            await status.refreshSnapshot()
        }
    }

}
