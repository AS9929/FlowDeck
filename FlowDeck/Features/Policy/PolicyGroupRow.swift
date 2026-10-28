import SwiftUI

/// 策略组卡片：标题与预览是同一张卡。展开时整张卡随布局长高、圆角跟着下移，预览内容淡入；
/// 收起时内容先淡出，卡片再收回。动画由点按时的 withAnimation 驱动，批量展开和返回页面不播放。
struct PolicyGroupRow: View {
    @Environment(PolicyStore.self) private var store
    private let initialGroup: MihomoProxy
    var showAll = false
    var onShowAll: ((String) -> Void)?

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var query = ""
    @State private var pendingTimeout: String?
    @State private var closeExisting = false

    init(group: MihomoProxy, showAll: Bool = false, onShowAll: ((String) -> Void)? = nil) {
        initialGroup = group
        self.showAll = showAll
        self.onShowAll = onShowAll
    }

    // 导航目的页会保留入栈快照；选中态必须订阅 Store 中的当前组，不能继续读取旧的 now。
    // 快照仅用于切换设备或出栈期间当前组已移除时保持转场内容稳定。
    private var group: MihomoProxy { store.proxies[initialGroup.name] ?? initialGroup }

    private var isOpen: Bool { store.expanded.contains(group.name) }
    private var options: [String] { group.all ?? [] }
    private static let cardShape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    var body: some View {
        Group {
            if showAll {
                ScrollView { optionsContent(showAll: true).padding(.top, 12) }
                    .background(AppBackground())
                    .navigationTitle(group.name)
                    .navigationBarTitleDisplayMode(.inline)
            } else {
                VStack(spacing: 0) {
                    header
                    if isOpen {
                        Divider().padding(.horizontal, 16)
                            .transition(.opacity)
                        optionsContent(showAll: false)
                            .padding(.top, 12)
                            .transition(Self.contentTransition(reduceMotion: reduceMotion))
                    }
                }
                // 玻璃只做背景并随卡片尺寸变化；内容用同一圆角裁切，长高过程中底部始终是圆角而不是直边。
                .background { Color.clear.glassCard(cornerRadius: 22) }
                .clipShape(Self.cardShape)
                .contentShape(Self.cardShape)
            }
        }
        .confirmationDialog(
            "这个节点上次测速超时", isPresented: Binding(get: { pendingTimeout != nil }, set: { if !$0 { pendingTimeout = nil } }), titleVisibility: .visible
        ) {
            Button("仍然切换") { if let o = pendingTimeout { choose(o) } }
            Button("先重新测速") { Task { await store.test(group: group.name) } }
        }
    }

    /// 展开：内容稍晚淡入并从上方 6 pt 落下。收起：内容留在原位、由收回的圆角裁切，同时较慢淡出，
    /// 不会出现内容先消失、只剩一张空玻璃再收回的情况。
    static func contentTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: -6)).animation(.easeOut(duration: 0.24).delay(0.06)),
            removal: .opacity.animation(.easeIn(duration: 0.26)))
    }

    /// 弹簧时长与系统列表展开接近；减少动态效果时只做淡入淡出。
    static func disclosureAnimation(opening: Bool, reduceMotion: Bool) -> Animation {
        if reduceMotion { return .easeInOut(duration: 0.2) }
        return opening ? .spring(duration: 0.42, bounce: 0.1) : .spring(duration: 0.34, bounce: 0)
    }

    private var header: some View {
        Button {
            withAnimation(Self.disclosureAnimation(opening: !isOpen, reduceMotion: reduceMotion)) {
                store.toggleExpanded(group.name)
            }
        } label: {
            HStack(spacing: 12) {
                GroupIcon(name: group.name, iconURL: group.icon, size: 36, groupType: group.type)
                VStack(alignment: .leading, spacing: 5) {
                    Text(PolicyIconCatalog.displayName(group.name))
                        .font(.body.weight(.bold))
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    Text(group.now.map { PolicyStore.shortName($0) } ?? "尚未选择出口")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                        .contentTransition(.opacity)
                    if typeSize.isAccessibilitySize {
                        DelayBadge(delay: store.delay(of: group.name), testing: store.testing.contains(group.name))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !typeSize.isAccessibilitySize {
                    DelayBadge(delay: store.delay(of: group.name), testing: store.testing.contains(group.name))
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 12)
            }
            .padding(16)
            .frame(minHeight: 76)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(store.favoriteGroups.contains(group.name) ? "取消收藏" : "收藏策略组", systemImage: "star") {
                if store.favoriteGroups.contains(group.name) { store.favoriteGroups.remove(group.name) } else { store.favoriteGroups.insert(group.name) }
            }
        }
        .accessibilityLabel("\(group.name)，当前 \(group.now ?? "无")")
        .accessibilityValue(isOpen ? "已展开" : "已收起")
        .accessibilityHint(isOpen ? "收起" : "展开选择")
    }

    /// 摘要与操作合成一行：选项数、超时数、测速时间在左，排序和测速是两个小按钮。
    private var summaryBar: some View {
        let timeouts = options.filter { store.delay(of: $0) == 0 }.count
        let nodeCount = options.filter { !(store.proxies[$0]?.isGroup ?? true) }.count
        var parts = ["\(options.count) 个选项"]
        if timeouts > 0 { parts.append("\(timeouts) 个超时") }
        if let date = store.testedAt[group.name] { parts.append("测速于 " + date.formatted(date: .omitted, time: .shortened)) }
        let sorted = store.sortByDelay.contains(group.name)
        let testable = options.contains { store.delay(of: $0) != nil || !(store.proxies[$0]?.isBuiltin ?? true) }
        let layout =
            typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            Text(parts.joined(separator: " · "))
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !typeSize.isAccessibilitySize { Spacer(minLength: 4) }
            HStack(spacing: 8) {
                if nodeCount > 6 {
                    Button {
                        if sorted { store.sortByDelay.remove(group.name) } else { store.sortByDelay.insert(group.name) }
                    } label: {
                        Label("按延迟", systemImage: "arrow.up.arrow.down")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10).frame(minHeight: 30)
                            .foregroundStyle(sorted ? Color.accentColor : .secondary)
                            .background(sorted ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(sorted ? "已开启" : "已关闭")
                }
                if testable {
                    Button {
                        Task { await store.test(group: group.name) }
                    } label: {
                        Group {
                            if store.testing.contains(group.name) {
                                ProgressView().controlSize(.mini)
                            } else {
                                Label("测速", systemImage: "bolt.fill")
                            }
                        }
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10).frame(minHeight: 30)
                        .foregroundStyle(Color.accentColor)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(store.testing.contains(group.name))
                    .accessibilityLabel("测速 \(group.name)")
                }
            }
        }
        .frame(minHeight: 32)
    }

    @ViewBuilder
    private func optionsContent(showAll: Bool) -> some View {
        VStack(spacing: 10) {
            summaryBar
            if showAll && options.count > 8 {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("在 \(group.name) 中搜索", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                    }
                }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
            }
            if showAll {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(visibleOptions, id: \.self) { option in
                        optionTile(option)
                    }
                }
            } else {
                // 预览最多 8 项，用确定尺寸的普通网格，展开时不需要懒加载补测。
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    let preview = previewOptions
                    let columnCount = typeSize.isAccessibilitySize ? 1 : 2
                    ForEach(Array(stride(from: 0, to: preview.count, by: columnCount)), id: \.self) { index in
                        GridRow {
                            optionTile(preview[index])
                            if columnCount == 2 {
                                if index + 1 < preview.count {
                                    optionTile(preview[index + 1])
                                } else {
                                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                                }
                            }
                        }
                    }
                }
            }
            if !showAll && options.count > 8 {
                Button {
                    query = ""
                    onShowAll?(group.name)
                } label: {
                    HStack {
                        Text("查看全部 \(options.count) 个选项")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if showAll && group.isSelectable {
                Toggle("切换时断开本组旧连接", isOn: $closeExisting)
                    .font(.caption.weight(.medium))
            }
            if store.selecting.contains(group.name) {
                ProgressView("正在切换并确认…").font(.caption.weight(.medium))
            }
            if !group.isSelectable {
                Text(group.type == "URLTest" ? "自动选择由延迟决定，不能手动指定。" : "这个组由策略自动决定，不能手动指定。")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if options.count == 1 {
                Text("只有一个选项。").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, showAll || options.count > 8 ? 4 : 12)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: typeSize.isAccessibilitySize ? 1 : 2)
    }

    private func optionTile(_ option: String) -> some View {
        ProxyTile(
            option: option, selected: group.now == option, enabled: group.isSelectable && !store.selecting.contains(group.name),
            testing: store.testing.contains(group.name)
        ) {
            if store.delay(of: option) == 0 {
                pendingTimeout = option
            } else {
                choose(option)
            }
        } closeAndChoose: {
            Task { await store.select(group: group.name, option: option, closeExisting: true) }
        }
        .frame(maxWidth: .infinity)
    }

    /// 预览始终包含当前选择，避免长组展开后找不到正在使用的节点。
    private var previewOptions: [String] {
        // 选择页的搜索只影响该页，不能让背后的预览随输入改变高度或选项。
        let ordered =
            store.sortByDelay.contains(group.name)
            ? options.sorted { rank(store.delay(of: $0)) < rank(store.delay(of: $1)) }
            : options
        var preview = Array(ordered.prefix(8))
        if let current = group.now, !preview.contains(current), options.contains(current) {
            if preview.count == 8 { preview.removeLast() }
            preview.append(current)
        }
        return preview
    }

    private var visibleOptions: [String] {
        var list = options
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty { list = list.filter { $0.lowercased().contains(q) } }
        if store.sortByDelay.contains(group.name) {
            list.sort { rank(store.delay(of: $0)) < rank(store.delay(of: $1)) }
        }
        return list
    }

    private func rank(_ d: Int?) -> Int {
        guard let d else { return 100_000 }
        return d == 0 ? 99_999 : d
    }

    private func choose(_ option: String) {
        guard option != group.now else { return }
        Task { await store.select(group: group.name, option: option, closeExisting: closeExisting) }
    }
}

/// 节点或子策略组的方块。
struct ProxyTile: View {
    @Environment(PolicyStore.self) private var store
    let option: String
    let selected: Bool
    let enabled: Bool
    let testing: Bool
    let choose: () -> Void
    let closeAndChoose: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    /// 两行固定结构：名称一行，来源与延迟一行，网格里每格等高；辅助字号下允许换行。
    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(selected ? .semibold : .medium))
                        .foregroundStyle(titleColor)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(subtitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    Spacer(minLength: 0)
                    DelayBadge(delay: store.delay(of: option), testing: testing && store.delay(of: option) != nil)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
        .contextMenu {
            if enabled && !selected {
                Button {
                    choose()
                } label: {
                    Label("切换", systemImage: "checkmark")
                }
                Button {
                    closeAndChoose()
                } label: {
                    Label("切换并断开旧连接", systemImage: "bolt.horizontal")
                }
            }
            Button {
                UIPasteboard.general.setItems(
                    [["public.utf8-plain-text": option]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
            } label: {
                Label("拷贝名称", systemImage: "doc.on.doc")
            }
        }
        .accessibilityIdentifier("proxyOption." + option)
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var proxy: MihomoProxy? { store.proxies[option] }

    private var title: String {
        switch option {
        case "DIRECT": return "DIRECT"
        case "REJECT": return "REJECT"
        default:
            if proxy?.isGroup == true {
                return PolicyIconCatalog.displayName(option)
            }
            return PolicyStore.shortName(option)
        }
    }

    private var subtitle: String {
        switch option {
        case "DIRECT": return "不经过代理"
        case "REJECT": return "直接拒绝"
        default:
            if proxy?.isGroup == true {
                return store.resolve(option).map { PolicyStore.shortName($0.name) } ?? ""
            }
            if let r = option.range(of: " | ") { return String(option[..<r.lowerBound]) }
            return proxy?.type ?? ""
        }
    }

    private var titleColor: Color {
        if selected { return .accentColor }
        if option == "REJECT" { return .red }
        if option == "DIRECT" { return .secondary }
        return .primary
    }
}

struct PressScaleStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(AppMotion.feedback(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}
