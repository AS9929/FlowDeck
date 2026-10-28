import SwiftUI

struct RulesView: View {
    @Environment(PolicyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var searchIndex: [Int: String] = [:]
    @State private var rules: [MihomoRule] = []
    @State private var error: String?
    @State private var query = ""

    var body: some View {
        DetailListShell(title: "分流规则") { ruleList }
    }

    private var ruleList: some View {
        let visible = filtered
        return List {
            SearchRow(text: $query, prompt: "按内容或策略筛选").headerRow()
            if let error {
                Text(error).foregroundStyle(.orange).font(.footnote.weight(.medium)).listRowBackground(Color.clear)
            }
            Text("自上而下匹配，命中即停 · \(visible.count) / \(rules.count) 条")
                .font(.footnote.weight(.medium)).foregroundStyle(.secondary).headerRow()
            ForEach(visible) { rule in
                Section {
                    HStack(spacing: 10) {
                        Text("\(rule.id + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.type.lowercased() == "match" ? "其余全部" : rule.payload)
                                .font(.subheadline.monospaced())
                                .fixedSize(horizontal: false, vertical: true)
                            PolicyPill(name: rule.proxy)
                            Text(rule.type).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .listRowBackground(GlassListBackground())
                    .listRowSeparator(.hidden)
                }
            }
            Text(visible.isEmpty ? "没有符合条件的规则" : "规则来自设备上正在运行的配置，只读。")
                .font(.footnote.weight(.medium)).foregroundStyle(.secondary).headerRow()
        }
        .listSectionSpacing(10)
        .contentMargins(.top, 8, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .task { await load() }
        .refreshable { await load() }
    }

    private var filtered: [MihomoRule] {
        let q = query.lowercased()
        guard !q.isEmpty else { return rules }
        return rules.filter { searchIndex[$0.id]?.contains(q) == true }
    }

    private func load() async {
        do {
            let loaded = try await store.client.rules()
            searchIndex = Dictionary(
                uniqueKeysWithValues: loaded.map {
                    ($0.id, [$0.payload, $0.proxy, $0.type].joined(separator: "\n").lowercased())
                })
            rules = loaded
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct PolicyPill: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.caption.weight(.medium))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .foregroundStyle(foreground)
    }

    private var foreground: Color {
        switch name {
        case "DIRECT": return .secondary
        case "REJECT", "REJECT-DROP": return .red
        default: return .accentColor
        }
    }

    private var background: Color { foreground.opacity(0.14) }
}

/// 最近请求：每 2 秒刷新一次，可筛选、可断开单个连接。
struct ConnectionsView: View {
    @Environment(AppRouter.self) private var router
    var embedded = false
    var active = true
    @Environment(PolicyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var list: [MihomoConnection] = []
    @State private var filter: Filter = .all
    @State private var error: String?
    @State private var detail: MihomoConnection?
    @State private var query = ""
    @State private var sourceIP = ""
    @State private var paused = false
    @State private var updatedAt: Date?
    @State private var closing = false
    @State private var pendingConnections: [MihomoConnection] = []
    @State private var confirmClose = false
    @State private var closeNotice: String?
    @Environment(ManagementStore.self) private var manager
    @Environment(DeviceStore.self) private var devices

    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部"
        case proxy = "代理"
        case direct = "直连"
        case reject = "拦截"
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if embedded {
                connectionList
            } else {
                DetailListShell(title: "实时连接") { connectionList }
            }
        }
        .appPush(item: $detail) { conn in
            ConnectionDetail(
                conn: conn,
                onClose: {
                    close(conn)
                    detail = nil
                },
                onPolicy: { name in
                    detail = nil
                    if !embedded { dismiss() }
                    store.revealGroup = name
                }
            )

        }
        .confirmationDialog("断开所选连接？", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("断开这 \(pendingConnections.count) 条连接", role: .destructive) { closeSnapshot() }
        } message: {
            Text("只处理打开确认框时匹配筛选的连接。后续新建连接不受影响，客户端可能自动重连。")
        }
    }

    private var filterTitle: String {
        let kind = filter == .all ? "全部连接" : "\(filter.rawValue)连接"
        return sourceIP.isEmpty ? kind : sourceIP
    }

    private var connectionList: some View {
        let visible = filtered
        return List {
            connectionToolbar(visible: visible)
                .buttonStyle(.borderless)
                .headerRow()
            if let error {
                Text(error).foregroundStyle(.orange).font(.footnote.weight(.medium)).listRowBackground(Color.clear)
            }
            if let closeNotice {
                Text(closeNotice).font(.footnote.weight(.medium)).foregroundStyle(.secondary).listRowBackground(Color.clear)
            }
            if closing { ProgressView("正在断开所选连接…").listRowBackground(Color.clear) }
            SearchRow(text: $query, prompt: "搜索域名、IP 或策略").headerRow()
            ForEach(visible) { conn in
                Section {
                    Button {
                        detail = conn
                    } label: {
                        row(conn)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(GlassListBackground())
                    .listRowSeparator(.hidden)
                    .swipeActions {
                        Button(role: .destructive) {
                            close(conn)
                        } label: {
                            Label("断开", systemImage: "xmark")
                        }
                    }
                }
            }
            if visible.isEmpty && error == nil {
                Text("没有符合条件的请求").foregroundStyle(.secondary).font(.footnote.weight(.medium)).listRowBackground(Color.clear)
            }
        }
        .listSectionSpacing(10)
        .contentMargins(.top, 8, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .onChange(of: devices.clientRevision) { _, _ in
            // 暂停保留的快照也必须按设备隔离，不能把上一台设备的请求带到新设备。
            list = []
            detail = nil
            sourceIP = ""
            pendingConnections = []
            confirmClose = false
            closeNotice = nil
            updatedAt = nil
            error = nil
        }
        .task(id: "\(active && detail == nil && !paused)-\(devices.clientRevision)") {
            // 查看请求详情时暂停底层刷新，避免列表变化影响弹层焦点和阅读位置。
            guard active && detail == nil && !paused else { return }
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// 以实际可用宽度选择排布，显示缩放、长 IP 和暂停提示都不能挤掉筛选名称。
    private func connectionToolbar(visible: [MihomoConnection]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    connectionFilter(count: visible.count).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 4)
                    connectionActions(visible: visible).fixedSize()
                }
                VStack(alignment: .leading, spacing: 10) {
                    connectionFilter(count: visible.count)
                    connectionActions(visible: visible)
                }
            }
            if paused {
                Text("已暂停").font(.caption.weight(.semibold)).foregroundStyle(.orange)
            }
        }
    }

    private func connectionFilter(count: Int) -> some View {
        Menu {
            Picker("连接类型", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("来源设备", selection: $sourceIP) {
                Text("所有设备").tag("")
                ForEach(Array(Set(list.map { $0.metadata.sourceIP })).sorted(), id: \.self) { Text($0).tag($0) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(filterTitle).fixedSize(horizontal: false, vertical: true)
                Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .glassSurface(in: Capsule(), interactive: true)
        }
        .accessibilityLabel("筛选连接，当前\(filterTitle)，\(count) 条")
    }

    private func connectionActions(visible: [MihomoConnection]) -> some View {
        HStack(spacing: 0) {
            Button {
                paused.toggle()
            } label: {
                Image(systemName: paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 42, height: 40)
            }
            .accessibilityLabel(paused ? "恢复实时刷新" : "暂停实时刷新")
            Menu {
                Button("断开筛选结果", systemImage: "xmark.circle", role: .destructive) {
                    pendingConnections = visible
                    confirmClose = true
                }.disabled(visible.isEmpty || closing || devices.readOnly || manager.working)
                Button("刷新列表", systemImage: "arrow.clockwise") { Task { await load() } }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 42, height: 40)
            }
            .accessibilityLabel("连接操作")
            Button {
                router.sheet = .logs
            } label: {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 42, height: 40)
            }
            .accessibilityLabel("实时日志")
        }
        .foregroundStyle(.primary)
        .glassSurface(in: Capsule(), interactive: true)
    }

    private func row(_ c: MihomoConnection) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(c.target).font(.subheadline.monospaced()).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(c.download), countStyle: .binary))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(c.metadata.network.uppercased())
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                Text(c.metadata.sourceIP).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            }
            Text(c.chainText)
                .font(.caption.weight(.medium))
                .foregroundStyle(c.kind == .reject ? .red : c.kind == .direct ? .secondary : .accentColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .contentShape(Rectangle())
    }

    private var filtered: [MihomoConnection] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return list.filter { connection in
            let matchesKind: Bool
            switch filter {
            case .all: matchesKind = true
            case .proxy: matchesKind = connection.kind == .proxy
            case .direct: matchesKind = connection.kind == .direct
            case .reject: matchesKind = connection.kind == .reject
            }
            return matchesKind && (sourceIP.isEmpty || connection.metadata.sourceIP == sourceIP)
                && (term.isEmpty
                    || [connection.target, connection.metadata.sourceIP, connection.chainText]
                        .contains { $0.localizedCaseInsensitiveContains(term) })
        }
    }

    private func load() async {
        let revision = devices.clientRevision
        let client = store.client
        do {
            let snapshot = try await client.connections().connections
            let result = await Task.detached(priority: .utility) {
                snapshot.sorted { ($0.start ?? "") > ($1.start ?? "") }
            }.value
            guard !Task.isCancelled, revision == devices.clientRevision else { return }
            list = result
            updatedAt = Date()
            error = nil
        } catch {
            guard !Task.isCancelled, revision == devices.clientRevision else { return }
            self.error = "读取失败，列表保留最后快照。" + error.localizedDescription
        }
    }

    private func closeSnapshot() {
        let selected = pendingConnections
        let revision = devices.clientRevision
        let client = store.client
        closing = true
        closeNotice = nil
        Task {
            defer { closing = false }
            var completed = 0
            var closedIDs: Set<String> = []
            defer { list.removeAll { closedIDs.contains($0.id) } }
            do {
                let lease = try DeviceOperationGate.begin("断开连接")
                defer { DeviceOperationGate.end(lease) }
                _ = try await manager.verifiedAPI(devices, capability: .mihomo)
                for connection in selected {
                    guard revision == devices.clientRevision else { throw ManagementError.deviceChanged }
                    try await client.closeConnection(id: connection.id)
                    guard revision == devices.clientRevision else { throw ManagementError.deviceChanged }
                    completed += 1
                    closedIDs.insert(connection.id)
                }
                closeNotice = "已完成 \(completed) 条连接的断开请求"
            } catch {
                guard revision == devices.clientRevision else { return }
                closeNotice = "已处理 \(completed) / \(selected.count) 条。" + error.localizedDescription
            }
            await load()
        }
    }

    private func close(_ conn: MihomoConnection) {
        let revision = devices.clientRevision
        let client = store.client
        Task {
            do {
                let lease = try DeviceOperationGate.begin("断开连接")
                defer { DeviceOperationGate.end(lease) }
                guard let authorize = store.authorizeWrite else {
                    throw ManagementError.invalid("写入授权尚未准备，请重新打开页面。")
                }
                try await authorize()
                guard revision == devices.clientRevision else { return }
                try await client.closeConnection(id: conn.id)
                guard revision == devices.clientRevision else { return }
                list.removeAll { $0.id == conn.id }
            } catch {
                guard revision == devices.clientRevision else { return }
                self.error = error.localizedDescription
            }
        }
    }
}

struct ConnectionDetail: View {
    @Environment(PolicyStore.self) private var store
    let conn: MihomoConnection
    let onClose: () -> Void
    let onPolicy: (String) -> Void

    var body: some View {
        DetailSheet(title: "请求详情") {
            DeviceDetailSummary(symbol: "point.3.connected.trianglepath.dotted", title: conn.target, subtitle: conn.metadata.network.uppercased() + " · 当前连接快照")
            GlassSection("流量") {
                LabeledContent("下载", value: ByteCountFormatter.string(fromByteCount: Int64(conn.download), countStyle: .binary))
                LabeledContent("上传", value: ByteCountFormatter.string(fromByteCount: Int64(conn.upload), countStyle: .binary))
            }
            GlassSection("路由信息") {
                DeviceParameterRow(title: "来源设备", value: conn.metadata.sourceIP)
                Divider()
                DeviceParameterRow(title: "命中规则", value: "\(conn.rule) \(conn.rulePayload)")
                Divider()
                DeviceParameterRow(title: "完整策略链", value: conn.chainText)
            }
            GlassSection("操作") {
                ForEach(conn.chains.reversed().filter { store.proxies[$0]?.isGroup == true && $0 != "GLOBAL" }, id: \.self) { name in
                    Button("修改策略 · \(name)", systemImage: "arrow.triangle.branch") { onPolicy(name) }
                }
                Button("断开这个连接", role: .destructive, action: onClose)
            }
        }
    }
}

struct SearchRow: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(.thinMaterial, in: Capsule())
    }
}
