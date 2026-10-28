import SwiftUI

/// 设置首页只呈现偏好入口和当前状态；运行模式的开关与说明在独立详情中管理。
struct AppSettingsView: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showSystem = false
    @State private var showAbout = false
    @State private var showAppearance = false
    @State private var showUsage = false
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue

    var body: some View {
        DetailSheet(title: "App 设置") {
            GlassSection {
                Button {
                    showUsage = true
                } label: {
                    PreferenceEntry(
                        title: "使用模式", symbol: "slider.horizontal.3",
                        subtitle: modeSummary,
                        value: devices.demoMode ? "演示" : devices.current == nil ? "未接入" : "设备"
                    )
                }
            }
            GlassSection("偏好设置") {
                Button {
                    showAppearance = true
                } label: {
                    PreferenceEntry(
                        title: "外观与图标", symbol: "circle.lefthalf.filled",
                        value: AppAppearance.resolve(appearance).title
                    )
                }
                entryDivider
                Button {
                    showSystem = true
                } label: {
                    PreferenceEntry(title: "小组件与快捷指令", symbol: "square.grid.2x2")
                }
            }
            GlassSection("信息") {
                Button {
                    showAbout = true
                } label: {
                    PreferenceEntry(title: "关于\(AppBrand.name)", symbol: "info.circle")
                }
            }
            SettingsBrandFooter()
                .padding(.top, 28)
                .padding(.bottom, 12)
        }
        .appPush(isPresented: $showUsage) { UsageSettingsView() }
        .appPush(isPresented: $showSystem) { SystemEntrancesView() }
        .appPush(isPresented: $showAbout) { AboutView() }
        .appPush(isPresented: $showAppearance) { AppearanceSettingsView() }
    }

    private var modeSummary: String {
        if devices.demoMode {
            return "示例数据 · 不连接设备"
        }
        if devices.current == nil { return "接入设备后开始管理" }
        return devices.readOnly ? "只读保护已开启" : "管理 \(devices.current?.name ?? "当前设备")"
    }

    private var entryDivider: some View {
        Divider().padding(.leading, typeSize.isAccessibilitySize ? 0 : 48)
    }
}

/// 此页使用统一的紧凑导航行；状态靠右，大字号时改为纵向，避免挤压标题。
private struct PreferenceEntry: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    let symbol: String
    var subtitle: String?
    var value: String?

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        FeatureIcon(symbol: symbol)
                        Spacer()
                        chevron
                    }
                    labels
                    if let value {
                        valueLabel(value)
                    }
                }
            } else {
                HStack(spacing: 12) {
                    FeatureIcon(symbol: symbol)
                    labels
                    if let value {
                        valueLabel(value).fixedSize()
                    }
                    chevron
                }
            }
        }
        .frame(minHeight: 46)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(AppTypography.rowTitle)
                .foregroundStyle(.primary)
            if let subtitle {
                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    private func valueLabel(_ value: String) -> some View {
        Text(value)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
    }
}

/// 沿用原有运行模式与写入保护规则，只调整信息组织；模式切换仍由 DeviceStore 重建客户端。
private struct UsageSettingsView: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(DeviceStatusStore.self) private var status
    @Environment(ManagementStore.self) private var manager
    @State private var showDevices = false

    private var working: Bool { manager.working || status.busy != nil || DeviceOperationGate.active != nil }

    var body: some View {
        @Bindable var devices = devices
        return DetailSheet(title: "使用模式") {
            GlassSection("操作保护") {
                UsageModeToggle(
                    title: "只读模式", symbol: "lock.shield",
                    explanation: "只查看状态，阻止对设备的写入操作。",
                    isOn: $devices.readOnly
                )
                .disabled(working)
            }
            GlassSection("数据来源") {
                UsageModeToggle(
                    title: "演示模式", symbol: "play.rectangle",
                    explanation: "使用示例数据体验功能，操作不会发送到真实设备。",
                    isOn: $devices.demoMode
                )
                .disabled(working)
                if !devices.isConfigured && devices.demoMode {
                    Divider()
                    Text("关闭演示后回到设备接入引导，也可以先添加并验证自己的设备。")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        showDevices = true
                    } label: {
                        PreferenceEntry(title: "我的设备", symbol: "plus.circle")
                    }
                }
            }
            if working {
                Label("设备操作进行中，完成后可切换模式。", systemImage: "clock")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .appPush(isPresented: $showDevices) { DeviceLibraryView() }
    }
}

/// 标题保持主色，开关不挤压说明；辅助字号使用上下布局以保留完整内容。
private struct UsageModeToggle: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    let symbol: String
    let explanation: String
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let layout =
                typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(spacing: 12))
            layout {
                HStack(spacing: 12) {
                    FeatureIcon(symbol: symbol)
                    Text(title)
                        .font(AppTypography.rowTitle)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Toggle(title, isOn: $isOn)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(title)
            }
            Text(explanation)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 设置页以品牌页尾收尾；跟随内容滚动，避免大字号时与设置项重叠。
private struct SettingsBrandFooter: View {
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        return "Version \(version) · Build \(build)"
    }

    var body: some View {
        VStack(spacing: 6) {
            AppBrandIcon(size: 72)
                .padding(.bottom, 8)
            Text("\(AppBrand.name) · \(AppBrand.englishName)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(version)
                .font(.caption2)
            Text("© 2026 \(AppBrand.englishName). All rights reserved.")
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
