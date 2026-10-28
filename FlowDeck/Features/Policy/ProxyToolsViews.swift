import SwiftUI

/// 运行设置只暴露可回读验证的选项。缺失字段表示当前核心未提供，不显示伪造的默认开关。
struct RuntimeSettingsView: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(PolicyStore.self) private var policy
    @Environment(ManagementStore.self) private var manager
    @State private var operationStarted = false
    @State private var settings: JSONObject?
    @State private var error: String?

    var body: some View {
        DetailSheet(title: "运行设置", closeDisabled: manager.working) {
            DeviceDetailSummary(symbol: "slider.horizontal.3", title: "调整当前运行行为", subtitle: "立即生效，重启或重新加载配置后恢复 YAML 中的值。需要长期保留时，请编辑设备配置。")
            if operationStarted { ManagementProgress() }
            if let error {
                StatusBanner(title: "读取失败", message: error, tone: .warning) { Task { await load() } }
            }
            if let settings {
                GlassSection("代理行为") {
                    LabeledContent("出站模式") {
                        Picker("出站模式", selection: Binding(get: { policy.mode }, set: { value in Task { await policy.setMode(value) } })) {
                            ForEach(OutboundMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                        }.labelsHidden().pickerStyle(.menu)
                    }
                    if devices.usesUFI {
                        LabeledContent("IPv6 解析", value: "由部署配置管理")
                        Text("当前 F50 使用 IPv4 透明代理；IPv6 需与设备转发规则一并配置。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        runtimeToggle("IPv6 解析", field: "ipv6", change: RuntimeChange.ipv6)
                    }
                    runtimeToggle("域名嗅探", field: "sniffing", change: RuntimeChange.sniffing)
                    runtimeToggle("TCP 并发连接", field: "tcp-concurrent", change: RuntimeChange.tcpConcurrent)
                }
                .disabled(manager.working || devices.readOnly)
                if let level = settings.string("log-level") {
                    GlassSection("日志") {
                        LabeledContent("记录级别") {
                            Picker("记录级别", selection: Binding(get: { level }, set: { apply(.logLevel($0)) })) {
                                ForEach(["silent", "error", "warning", "info", "debug"], id: \.self) { Text($0).tag($0) }
                            }.labelsHidden().pickerStyle(.menu)
                        }
                    }.disabled(manager.working || devices.readOnly)
                }
                GlassSection("接管状态 · 只读") {
                    LabeledContent("局域网访问", value: settings.bool("allow-lan").map { $0 ? "开启" : "关闭" } ?? "未提供")
                    LabeledContent("混合代理端口", value: settings.int("mixed-port").map(String.init) ?? "未提供")
                    LabeledContent("TUN", value: settings.object("tun")?.bool("enable").map { $0 ? "开启" : "关闭" } ?? "未提供")
                    LabeledContent("协议栈", value: settings.object("tun")?.string("stack") ?? "未提供")
                } footer: {
                    Text("端口和 TUN 与设备的转发配置关联；需要调整时请通过完整配置导入。")
                }
            } else if error == nil {
                ProgressView("读取运行设置…")
            }
        }
        .task(id: devices.clientRevision) { await load() }
    }

    @ViewBuilder
    private func runtimeToggle(_ title: String, field: String, change: @escaping (Bool) -> RuntimeChange) -> some View {
        if let value = settings?.bool(field) {
            Toggle(title, isOn: Binding(get: { value }, set: { apply(change($0)) }))
        }
    }

    private func load() async {
        let revision = devices.clientRevision
        settings = nil
        error = nil
        do {
            let actual = try await policy.client.runtimeSettings()
            guard !Task.isCancelled, revision == devices.clientRevision else { return }
            settings = actual
            error = nil
        } catch {
            guard !Task.isCancelled, revision == devices.clientRevision else { return }
            self.error = error.localizedDescription
        }
    }

    private func apply(_ change: RuntimeChange) {
        if devices.usesUFI, case .ipv6 = change {
            return
        }
        operationStarted = true
        Task {
            await manager.run("应用运行设置") {
                _ = try await manager.verifiedAPI(devices, capability: .mihomo)
                let api = policy.client
                try await api.patchRuntime(change)
                let actual = try await api.runtimeSettings()
                settings = actual
                guard change.matches(actual) else { throw ManagementError.unconfirmed("核心未回读到预期值，请刷新后检查。") }
                await manager.setStage("运行设置已回读确认", progress: 1)
            }
        }
    }
}

/// 规则集：只列真正可更新的集合。Mihomo 为策略组自动生成的 Compatible 集合不展示；
/// 配置里有真实节点订阅时才出现订阅区，带用量、到期和健康检查。
struct ProviderLibraryView: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(PolicyStore.self) private var policy
    @Environment(ManagementStore.self) private var manager
    @State private var operationStarted = false
    @State private var items: [MihomoProvider] = []
    @State private var errors: [String] = []
    @State private var loading = false

    private var ruleSets: [MihomoProvider] { items.filter { $0.kind == .rules && $0.isUserFacing } }
    private var subscriptions: [MihomoProvider] { items.filter { $0.kind == .proxies && $0.isUserFacing } }
    private var blocked: Bool { manager.working || devices.readOnly }

    var body: some View {
        DetailSheet(title: "规则集", closeDisabled: manager.working) {
            summary
            if operationStarted { ManagementProgress() }
            ForEach(errors, id: \.self) { Text($0).font(.footnote.weight(.medium)).foregroundStyle(.orange) }
            if !subscriptions.isEmpty {
                GlassSection("节点订阅") {
                    ForEach(subscriptions) { provider in
                        if provider.id != subscriptions.first?.id { Divider() }
                        subscriptionRow(provider)
                    }
                }
            }
            GlassSection("规则集") {
                if ruleSets.isEmpty && !loading {
                    Text("当前配置没有引用规则集，分流规则直接写在配置里。")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                }
                ForEach(ruleSets) { provider in
                    if provider.id != ruleSets.first?.id { Divider() }
                    ruleSetRow(provider)
                }
            }
        }
        .task(id: devices.clientRevision) { await load() }
        .refreshable { await load() }
    }

    /// 一句话说清这页做什么，右边是唯一的主操作。
    private var summary: some View {
        let online = ruleSets.filter(\.isOnline)
        let latest = ruleSets.compactMap(\.updatedDate).max()
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(loading && items.isEmpty ? "正在读取…" : "\(ruleSets.count) 个规则集 · \(online.count) 个在线")
                    .font(.headline.weight(.bold))
                Text(latest.map { "最近更新 " + Self.relative($0) } ?? "在线规则集会按配置的间隔自动更新，这里可以手动立即更新。")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !online.isEmpty {
                Button {
                    updateAll(online)
                } label: {
                    Label("全部更新", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).frame(minHeight: 40)
                        .glassSurface(in: Capsule(), interactive: true, tint: .accentColor.opacity(0.15))
                }
                .buttonStyle(.plain)
                .disabled(blocked)
            }
        }
        .padding(.horizontal, 4)
    }

    private func ruleSetRow(_ provider: MihomoProvider) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(provider.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(provider.count.formatted()) 条 · \(provider.isOnline ? "在线" : "本地文件") · \(provider.updatedDate.map(Self.relative) ?? "未更新")")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            // 本地文件规则集随配置一起维护，手动重载意义不大，只给在线规则集放更新按钮。
            if provider.isOnline {
                Button {
                    update([provider])
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(Color.accentColor.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(blocked)
                .accessibilityLabel("更新 \(provider.name)")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func subscriptionRow(_ provider: MihomoProvider) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.name).font(.subheadline.weight(.semibold))
                    Text("\(provider.count) 个节点 · \(provider.updatedDate.map(Self.relative) ?? "未更新")")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Menu {
                    if provider.canUpdate {
                        Button("更新订阅", systemImage: "arrow.clockwise") { update([provider]) }
                    }
                    Button("检查节点健康", systemImage: "waveform.path.ecg") { healthCheck(provider) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 36, height: 36)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .disabled(blocked)
            }
            if let quota = provider.quota {
                VStack(alignment: .leading, spacing: 6) {
                    if quota.total > 0 {
                        ProgressView(value: min(Double(quota.used), Double(quota.total)), total: Double(quota.total))
                    }
                    HStack {
                        Text("已用 " + ByteCountFormatter.string(fromByteCount: quota.used, countStyle: .binary)
                            + (quota.total > 0 ? " / " + ByteCountFormatter.string(fromByteCount: quota.total, countStyle: .binary) : ""))
                        Spacer()
                        if let expiry = quota.expiry {
                            Text("到期 " + expiry.formatted(date: .abbreviated, time: .omitted))
                                .foregroundStyle(expiry < Date() ? Color.orange : Color.secondary)
                        }
                    }
                    .font(.caption.weight(.medium).monospacedDigit())
                }
            }
        }
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_Hans")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func load() async {
        let revision = devices.clientRevision
        loading = true
        var result: [MihomoProvider] = []
        var failures: [String] = []
        for kind in ProviderKind.allCases {
            do { result += try await policy.client.providers(kind) } catch { failures.append("\(kind.title)：\(error.localizedDescription)") }
        }
        guard !Task.isCancelled, revision == devices.clientRevision else { return }
        items = result
        errors = failures
        loading = false
    }

    private func healthCheck(_ provider: MihomoProvider) {
        operationStarted = true
        Task {
            await manager.run("检查订阅节点健康") {
                _ = try await manager.verifiedAPI(devices, capability: .mihomo)
                try await policy.client.healthCheckProvider(provider.name)
                await policy.refresh()
                await manager.setStage("健康检查完成，节点延迟已重新读取", progress: 1)
            }
        }
    }

    private func updateAll(_ providers: [MihomoProvider]) { update(providers) }

    /// 逐个更新并回读；任何一个失败都明确报告，不显示为全部成功。
    private func update(_ providers: [MihomoProvider]) {
        guard !providers.isEmpty else { return }
        operationStarted = true
        let title = providers.count == 1 ? "更新\(providers[0].name)" : "更新 \(providers.count) 个规则集"
        Task {
            await manager.run(title) {
                _ = try await manager.verifiedAPI(devices, capability: .mihomo)
                var failed: [String] = []
                for (index, provider) in providers.enumerated() {
                    await manager.setStage("正在更新 \(provider.name)", progress: Double(index) / Double(providers.count))
                    do { try await policy.client.updateProvider(provider.name, kind: provider.kind) } catch { failed.append(provider.name) }
                }
                await load()
                guard errors.isEmpty else { throw ManagementError.unconfirmed("更新接口已返回，但重新读取失败。") }
                guard failed.isEmpty else { throw ManagementError.unconfirmed("以下规则集更新失败：" + failed.joined(separator: "、")) }
                await policy.refresh()
                await manager.setStage(providers.count == 1 ? "已更新并重新读取" : "\(providers.count) 个规则集已更新", progress: 1)
            }
        }
    }
}

/// 日志按需连接，只保留最近 200 条，不落盘；停止、切设备和离开页面均取消读取。
struct ProxyLogsView: View {
    @Environment(PolicyStore.self) private var policy
    @Environment(DeviceStore.self) private var devices
    @State private var entries: [MihomoLog] = []
    @State private var level = "info"
    @State private var paused = false
    @State private var error: String?

    var body: some View {
        DetailListShell(title: "实时日志") {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        ViewThatFits(in: .horizontal) {
                            logControls
                            VStack(alignment: .leading, spacing: 12) {
                                levelPicker
                                pauseButton
                            }
                        }
                        Text("最近 \(entries.count) / 200 条 · 仅本次会话")
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .listRowBackground(GlassListBackground())
                    .listRowSeparator(.hidden)
                }
                if let error {
                    Text(error).font(.footnote.weight(.medium)).foregroundStyle(.orange).listRowBackground(Color.clear)
                }
                if entries.isEmpty {
                    ContentUnavailableView("等待日志", systemImage: "text.alignleft", description: Text("有新的网络活动时，核心会推送日志。"))
                        .listRowBackground(Color.clear)
                }
                Section {
                    ForEach(entries.reversed()) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.type.uppercased()).font(.caption2.weight(.semibold))
                                .foregroundStyle(entry.type == "error" ? Color.orange : Color.accentColor)
                            Text(entry.payload).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        .padding(.vertical, 5)
                        .listRowBackground(Color.primary.opacity(0.035))
                        .contextMenu {
                            Button("复制日志", systemImage: "doc.on.doc") { UIPasteboard.general.setItems([["public.utf8-plain-text": entry.payload]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)]) }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空", systemImage: "trash") { entries.removeAll() }
                        .disabled(entries.isEmpty)
                }
            }
        }
        .task(id: "\(devices.clientRevision)-\(level)-\(paused)") {
            guard !paused else { return }
            error = nil
            do {
                for try await entry in policy.client.logs(level: level) {
                    try Task.checkCancellation()
                    entries.append(entry)
                    if entries.count > 200 { entries.removeFirst(entries.count - 200) }
                }
                if !Task.isCancelled { error = "日志连接已结束，点击暂停后继续可重新连接。" }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
        .onChange(of: devices.clientRevision) { entries.removeAll() }
    }
    private var logControls: some View {
        HStack(spacing: 20) {
            levelPicker
            Spacer(minLength: 12)
            pauseButton
        }
    }

    private var levelPicker: some View {
        Picker("级别", selection: $level) {
            ForEach(["info", "warning", "error", "debug"], id: \.self) { Text($0).tag($0) }
        }
        .pickerStyle(.menu)
        .fixedSize()
    }

    private var pauseButton: some View {
        Button(paused ? "继续" : "暂停", systemImage: paused ? "play" : "pause") { paused.toggle() }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.borderless)
            .fixedSize()
    }

}

/// 使用设备自身 DNS 查询；结果明确区分响应码、空答案与网络错误。
struct ProxyDNSView: View {
    @Environment(PolicyStore.self) private var policy
    @Environment(DeviceStore.self) private var devices
    @State private var domain = ""
    @State private var recordType = "A"
    @State private var result: JSONObject?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        DetailSheet(title: "DNS 查询") {
            DeviceDetailSummary(symbol: "network", title: "从设备解析域名", subtitle: "请求通过当前设备的 Mihomo DNS。结果包含记录内容和缓存有效时间。")
            GlassSection("查询条件") {
                FormField("域名") {
                    TextField("example.com", text: $domain).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                }
                LabeledContent("记录类型") {
                    Picker("记录类型", selection: $recordType) {
                        Text("A · IPv4").tag("A")
                        Text("AAAA · IPv6").tag("AAAA")
                        Text("CNAME · 别名").tag("CNAME")
                        Text("MX · 邮件").tag("MX")
                        Text("TXT · 文本").tag("TXT")
                        Text("NS · 名称服务器").tag("NS")
                        Text("HTTPS · 服务绑定").tag("HTTPS")
                    }.labelsHidden().pickerStyle(.menu)
                }
                Button(busy ? "正在查询…" : "通过设备查询") { Task { await query() } }
                    .disabled(busy || domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .disabled(busy)
            if let error { StatusBanner(title: "查询失败", message: error, tone: .warning) }
            if let result {
                GlassSection("查询结果") {
                    LabeledContent("响应码", value: result.int("Status").map(String.init) ?? "未知")
                    let answers = result.array("Answer")
                    if answers.isEmpty { Text("没有返回答案记录").foregroundStyle(.secondary) }
                    ForEach(answers.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(answers[index].string("data") ?? "—").font(.body.monospaced()).textSelection(.enabled)
                            Text("TTL \(answers[index].int("TTL") ?? 0) 秒").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func query() async {
        let revision = devices.clientRevision
        busy = true
        result = nil
        error = nil
        defer { busy = false }
        do {
            let response = try await policy.client.queryDNS(domain.trimmingCharacters(in: .whitespacesAndNewlines), type: recordType)
            guard revision == devices.clientRevision else { return }
            result = response
        } catch {
            guard revision == devices.clientRevision else { return }
            self.error = error.localizedDescription
        }
    }
}
