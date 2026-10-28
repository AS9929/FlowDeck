import SwiftUI

/// 外观选择即时保存并由 App 根视图统一应用，子页面无需重复覆盖主题。
struct AppearanceSettingsView: View {
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue
    @State private var icons = AppIconController.shared
    @State private var showAppIcons = false
    @State private var showPolicyIcons = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        DetailSheet(title: "外观与图标") {
            GlassSection("主题模式") {
                ForEach(AppAppearance.allCases) { option in
                    if option != .system {
                        Divider()
                    }
                    appearanceRow(option)
                }
            }
            GlassSection("图标") {
                Button {
                    showAppIcons = true
                } label: {
                    SettingsRow(
                        "App 图标", symbol: "app.badge",
                        subtitle: "选择主屏幕上的驭流图标",
                        value: icons.current?.title ?? "系统图标"
                    )
                }
                Divider()
                Button {
                    showPolicyIcons = true
                } label: {
                    SettingsRow(
                        "策略图标", symbol: "square.grid.3x3",
                        subtitle: "浏览 Mihomo 策略图标与适配类型"
                    )
                }
            }
        }
        .appPush(isPresented: $showAppIcons) { AppIconSettingsView() }
        .appPush(isPresented: $showPolicyIcons) { PolicyIconGalleryView() }
        .onAppear { icons.refresh() }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                icons.refresh()
            }
        }
    }

    private func appearanceRow(_ option: AppAppearance) -> some View {
        let selected = AppAppearance.resolve(appearance) == option
        return Button {
            appearance = option.rawValue
        } label: {
            let layout =
                typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(spacing: 14))
            layout {
                HStack {
                    Image(systemName: option.symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                    if typeSize.isAccessibilitySize {
                        Spacer()
                        selectionMark(selected)
                    }
                }
                .fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: false)
                VStack(alignment: .leading, spacing: 5) {
                    Text(option.title)
                        .font(AppTypography.rowTitle)
                        .foregroundStyle(.primary)
                    Text(option.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                if !typeSize.isAccessibilitySize {
                    selectionMark(selected)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(option.title)
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("appearance.\(option.rawValue)")
    }

    private func selectionMark(_ selected: Bool) -> some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.4))
            .font(.system(size: 20, weight: .semibold))
    }
}

/// 图标切换调用系统接口；显示真实完成状态，并允许失败后重试。
struct AppIconSettingsView: View {
    @State private var icons = AppIconController.shared
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        DetailSheet(title: "App 图标") {
            Text("为主屏幕选一个喜欢的样子")
                .font(AppTypography.sectionTitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 145 : 96), spacing: 14)],
                spacing: 16
            ) {
                ForEach(AppIconOption.allCases) { icon in
                    iconChoice(icon)
                }
            }
            if !icons.isSupported {
                Label("当前系统不支持切换 App 图标。", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            if icons.failed {
                Label("图标未能切换，请重新选择后再试。", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
            Text("仅更改 App 图标；主题模式与设备设置保持不变。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { icons.refresh() }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                icons.refresh()
            }
        }
    }

    private func iconChoice(_ icon: AppIconOption) -> some View {
        let selected = icons.current == icon
        return Button {
            icons.select(icon)
        } label: {
            VStack(spacing: 12) {
                AppBrandIcon(size: 76, icon: icon)
                Text(icon.title)
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Group {
                    if icons.pending == icon {
                        ProgressView()
                    } else {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.4))
                    }
                }
                .frame(height: 24)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(
                Color.accentColor.opacity(selected ? 0.12 : 0.04),
                in: RoundedRectangle(cornerRadius: 22)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(Color.accentColor.opacity(selected ? 0.5 : 0.12), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .disabled(!icons.isSupported || icons.pending != nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(icon.title)
        .accessibilityValue(icons.pending == icon ? "正在切换" : selected ? "已选择" : "未选择")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("appIcon.\(icon.rawValue)")
    }
}
