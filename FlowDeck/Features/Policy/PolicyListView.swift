import SwiftUI

/// 代理页按配置顺序展示策略组，展开有限预览，完整节点在独立选择页呈现。
struct PolicyListView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(PolicyStore.self) private var store
    @Environment(DeviceStore.self) private var devices
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sheet: Sheet?
    @State private var query = ""
    @State private var favoritesOnly = false
    @State private var showsSearch = false
    @FocusState private var searchFocused: Bool

    private enum ScrollAnchor: Hashable {
        case top
        case group(String)
    }

    enum Sheet: String, Identifiable {
        case rules, connections
        var id: String { rawValue }
    }

    @State private var allOptions: String?
    @State private var section: WorkspaceSection = .strategy
    @Environment(AppRouter.self) private var router

    private enum WorkspaceSection: String, CaseIterable {
        case strategy = "策略"
        case activity = "连接"
        case configuration = "配置"
    }

    var body: some View {
        Group {
            ScrollViewReader { scroll in
                VStack(spacing: 0) {
                    // 显示缩放不一定改变 Dynamic Type；工作区独占一行，避免与设备入口、设置互相遮挡。
                    workspacePicker
                        .padding(.horizontal, AppTheme.pageInset)
                        .padding(.vertical, 10)

                    ZStack {
                        switch section {
                        case .strategy:
                            ScrollView {
                                // 长列表不共享玻璃形变容器，防止离屏复用与形变事务交叉导致空白表面。
                                LazyVStack(spacing: 12) {
                                    Color.clear.frame(height: 1).id(ScrollAnchor.top)
                                    strategyTools(scroll: scroll)
                                    if showsSearch {
                                        HStack(spacing: 8) {
                                            SearchRow(text: $query, prompt: "查找策略组或当前节点")
                                                .focused($searchFocused)
                                            Button("取消") {
                                                query = ""
                                                searchFocused = false
                                                withAnimation(AppMotion.workspace(reduceMotion: reduceMotion)) {
                                                    showsSearch = false
                                                }
                                            }
                                            .font(.subheadline.weight(.medium))
                                            .fixedSize()
                                            .frame(minHeight: 44)
                                        }
                                    }
                                    if favoritesOnly {
                                        HStack {
                                            Label("仅收藏", systemImage: "star.fill")
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                            Button("显示全部") { favoritesOnly = false }
                                        }
                                        .font(.footnote.weight(.medium))
                                        .frame(minHeight: 32)
                                    }
                                    content(scroll: scroll)
                                }
                                .padding(.horizontal, AppTheme.pageInset)
                                .padding(.bottom, 24)
                            }
                            .refreshable { await store.refresh() }
                            .task(id: showsSearch) {
                                guard showsSearch else { return }
                                await DisplayFrameBoundary.wait()
                                guard !Task.isCancelled else { return }
                                searchFocused = true
                            }
                            .task(id: store.revealGroup) {
                                guard let name = store.revealGroup else { return }
                                query = ""
                                favoritesOnly = false
                                showsSearch = false
                                searchFocused = false
                                store.hiddenGroups.remove(name)
                                store.setExpanded(store.expanded.union([name]))
                                await Task.yield()
                                scroll.scrollTo(ScrollAnchor.group(name), anchor: .top)
                                store.revealGroup = nil
                            }
                        case .activity:
                            ConnectionsView(embedded: true)
                        case .configuration:
                            ProxyConfigurationView()
                        }
                    }
                    .animation(AppMotion.workspace(reduceMotion: reduceMotion), value: section)
                }
                .background(AppBackground())
                .navigationTitle("Mihomo")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    DeviceContextToolbar()
                }
                .onChange(of: router.proxyNavigationID) {
                    section = .strategy
                }
                .onChange(of: store.revealGroup) {
                    if store.revealGroup != nil {
                        sheet = nil
                        section = .strategy
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .appPush(item: $sheet) { s in
            switch s {
            case .rules: RulesView()
            case .connections: ConnectionsView()
            }
        }
        .appPush(value: $allOptions) { name in
            if let group = store.proxies[name] {
                PolicyGroupRow(group: group, showAll: true)
            }
        }
    }

    @ViewBuilder
    private func content(scroll: ScrollViewProxy) -> some View {
        if case .failed(let msg) = store.state {
            StatusBanner(title: "读取失败", message: msg, tone: .warning) {
                Task { await store.refresh() }
            }
        }
        if store.proxies.isEmpty, store.state == .loading {
            ProgressView("正在读取策略组…").padding(.top, 60)
        } else if !store.proxies.isEmpty {
            if store.mode != .rule {
                Text(store.mode == .global ? "全局模式：所有流量走最上面的 GLOBAL" : "直连模式：策略组暂不生效")
                    .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            }
            if filteredGroups.isEmpty {
                Text(favoritesOnly ? "还没有匹配的收藏。长按策略组标题可收藏。" : "没有匹配的策略组")
                    .font(.footnote.weight(.medium)).foregroundStyle(.secondary).padding(.vertical)
            }
            ForEach(filteredGroups, id: \.name) { group in
                PolicyGroupRow(group: group, onShowAll: { allOptions = $0 })
                    .id(ScrollAnchor.group(group.name))
            }
        }
    }

    private var filteredGroups: [MihomoProxy] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = favoritesOnly ? store.orderedGroups.filter { store.favoriteGroups.contains($0.name) } : store.orderedGroups
        guard !term.isEmpty else { return groups }
        return groups.filter {
            $0.name.localizedCaseInsensitiveContains(term) || ($0.now?.localizedCaseInsensitiveContains(term) ?? false)
        }
    }

    /// 工作区下只保留模式与两个工具入口；低频筛选收进菜单，启用时提供明确的退出入口。
    private var workspacePicker: some View {
        Picker("Mihomo 工作区", selection: $section) {
            ForEach(WorkspaceSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    /// 常规字号并排显示模式和工具，辅助字号分行以保留完整的模式名称与点击区域。
    private func strategyTools(scroll: ScrollViewProxy) -> some View {
        let layout =
            typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            Menu {
                Picker("出站模式", selection: Binding(get: { store.mode }, set: { mode in Task { await store.setMode(mode) } })) {
                    ForEach(OutboundMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .disabled(devices.readOnly)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: store.mode.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(store.mode.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 40)
                .glassSurface(in: Capsule(), interactive: true)
            }
            .accessibilityLabel("出站模式，当前\(store.mode.title)")
            if !typeSize.isAccessibilitySize {
                Spacer(minLength: 4)
            }
            HStack(spacing: 0) {
                Button {
                    withAnimation(AppMotion.workspace(reduceMotion: reduceMotion)) {
                        showsSearch = true
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 40)
                }
                .accessibilityLabel("搜索策略组")
                menu(scroll: scroll)
            }
            .foregroundStyle(.primary)
            .glassSurface(in: Capsule(), interactive: true)
        }
        .padding(.top, 4)
    }

    private func menu(scroll: ScrollViewProxy) -> some View {
        Menu {
            Menu {
                Picker(
                    "常用策略组",
                    selection: Binding(
                        get: { store.preferredGroup ?? "" },
                        set: { store.setPreferredGroup($0.isEmpty ? nil : $0) }
                    )
                ) {
                    Text("自动识别").tag("")
                    ForEach(store.availablePrimaryGroups, id: \.name) { group in
                        Text(group.name).tag(group.name)
                    }
                    if let saved = store.preferredGroup, !store.availablePrimaryGroups.contains(where: { $0.name == saved }) {
                        Text(saved + "（配置中已不存在）").tag(saved)
                    }
                }
            } label: {
                Label("常用策略组", systemImage: "pin")
            }
            .accessibilityIdentifier("preferred-policy-group")
            Section("\(store.orderedGroups.count) 个策略组") {
                Toggle(isOn: $favoritesOnly) {
                    Label("只看收藏", systemImage: "star")
                }
                Button {
                    Task { await store.testAll() }
                } label: {
                    Label("测试常用组延迟", systemImage: "bolt")
                }
                Button {
                    router.sheet = .strategyVisibility
                } label: {
                    Label("自定义策略列表", systemImage: "line.3.horizontal.decrease")
                }
                Button {
                    // 全部展开可能插入数百个节点；即时布局避免整页弹跳。
                    section = .strategy
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        scroll.scrollTo(ScrollAnchor.top, anchor: .top)
                        if store.expanded.isEmpty {
                            store.setExpanded(Set(store.orderedGroups.map(\.name)))
                        } else {
                            store.setExpanded([])
                        }
                    }
                } label: {
                    Label(store.expanded.isEmpty ? "全部展开" : "全部收起", systemImage: "rectangle.expand.vertical")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .bold))
                .frame(width: 44, height: 40)
        }
        .accessibilityLabel("策略操作")
    }
}

/// 模式与默认策略摘要。规则模式下各请求仍可匹配不同策略组。
struct OutboundCapsule: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(PolicyStore.self) private var store
    @Environment(DeviceStore.self) private var devices

    var body: some View {
        Menu {
            Picker("出站模式", selection: Binding(get: { store.mode }, set: { mode in Task { await store.setMode(mode) } })) {
                ForEach(OutboundMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .disabled(devices.readOnly)
        } label: {
            let layout =
                typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(spacing: 8))
            layout {
                Text(store.mode.title)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.16), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                Text(store.exitNode.map { PolicyStore.shortName($0.name) } ?? (store.mode == .direct ? "直连" : "未读取到出口"))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                if let n = store.exitNode { DelayBadge(delay: n.lastDelay) }
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .glassCard(cornerRadius: 20)
        }
    }
}

struct LinkRow: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            FeatureIcon(symbol: symbol)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.medium))
                Text(subtitle).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

struct StatusBanner: View {
    enum Tone { case info, warning, error }
    let title: String
    let message: String
    var tone: Tone = .info
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: tone == .info ? "info.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(color)
                Text(message).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let action {
                Button("重试", action: action).font(.footnote.weight(.semibold))
            }
        }
        .padding(12)
        .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous), tint: color.opacity(0.08))
    }

    private var color: Color {
        switch tone {
        case .info: return .accentColor
        case .warning: return .orange
        case .error: return .red
        }
    }
}
