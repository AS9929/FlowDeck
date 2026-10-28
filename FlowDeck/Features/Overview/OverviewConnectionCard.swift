import SwiftUI

/// 首页连接卡拥有代理确认交互；流量订阅仍由父页面持有，抽取不会重建采样任务。
struct OverviewConnectionCard: View {
    @Environment(PolicyStore.self) private var store
    @Environment(DeviceStore.self) private var devices
    @Environment(DeviceStatusStore.self) private var status
    @Environment(ManagementStore.self) private var manager
    @Environment(AppRouter.self) private var router
    @Environment(\.dynamicTypeSize) private var typeSize
    let state: OverviewNetworkState
    let traffic: TrafficMonitor
    @State private var confirmStop = false

    private var serviceRunning: Bool? { status.service?.running }

    /// 光点跟随实际吞吐：代理运行、非直连、设备正常，且最近 5 秒有真实采样。它表达“流量在走”，不代替出口探测。
    private func flowing(_ state: OverviewNetworkState) -> Bool {
        guard !state.needsAttention, serviceRunning == true, store.mode != .direct, traffic.hasFreshSample else { return false }
        if case .failed = store.state { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            flowHeading
            FlowPath(
                nodes: [
                    .init(asset: "FlowPhone", title: "本机"),
                    .init(asset: "TabDevice", title: devices.current?.model ?? "设备"),
                    .init(asset: "FlowCellular", title: "蜂窝"),
                    .init(asset: "FlowGlobe", title: exitRegion, emphasized: true),
                ],
                flowing: flowing(state),
                attention: state.needsAttention
            )
            Button {
                router.openProxy()
            } label: {
                let layout =
                    typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                    : AnyLayout(HStackLayout(spacing: 12))
                layout {
                    if typeSize.isAccessibilitySize {
                        HStack(spacing: 10) {
                            exitIcon
                            Spacer(minLength: 4)
                            exitChevron
                        }
                    } else {
                        exitIcon
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(exitTitle)
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        if typeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 5) { exitMetadata }
                        } else {
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) { exitMetadata }
                                VStack(alignment: .leading, spacing: 5) { exitMetadata }
                            }
                        }
                    }
                    if !typeSize.isAccessibilitySize {
                        Spacer(minLength: 4)
                        exitChevron
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("打开 Mihomo 选择常用策略或节点")
            Divider()
            serviceControl
            if let busy = status.busy {
                ProgressView(busy).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            } else if let notice = status.notice {
                Text(notice).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if case .failed(let message) = store.state {
                Label(message, systemImage: "exclamationmark.circle").font(.caption.weight(.medium)).foregroundStyle(.orange)
            }
        }
        .padding(18)
        .glassCard()
        .confirmationDialog("停用后所有接入设备将直接连接蜂窝网络", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("确认停用", role: .destructive) { control(.stop) }
        }
    }

    @ViewBuilder
    private var exitIcon: some View {
        if let exit = store.exitNode, store.mode != .direct, serviceRunning != false {
            GroupIcon(name: exit.name, size: 40)
        } else {
            FeatureIcon(symbol: store.mode == .direct ? "arrow.right" : "power")
        }
    }

    private var exitChevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
    }

    /// 常规与放大显示保持同行；辅助功能大字号保留纵向布局，不以截断换取同行。
    private var flowHeading: some View {
        let layout =
            typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            liveRate
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            exitCheckButton
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
        }
    }

    private var exitCheckButton: some View {
        Button {
            router.sheet = devices.usesUFI ? .service : .diagnostics
        } label: {
            HStack(spacing: 4) {
                Image(systemName: devices.usesUFI ? "power" : "stethoscope")
                    .accessibilityHidden(true)
                Text(devices.usesUFI ? "代理服务" : "检测出口")
            }
            .font(.caption.weight(.semibold))
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private var exitMetadata: some View {
        if store.mode != .direct, serviceRunning != false, let delay = store.exitNode?.lastDelay {
            DelayBadge(delay: delay)
        }
        Text(exitDetail)
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 开关独占布局空间，不覆盖节点按钮。辅助字号改为纵向排列，保留完整的状态和模式。
    private var serviceControl: some View {
        let layout =
            typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        return layout {
            VStack(alignment: .leading, spacing: 4) {
                Text("代理服务").font(AppTypography.compactTitle)
                Text(serviceDescription).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !typeSize.isAccessibilitySize {
                Spacer(minLength: 8)
            }
            serviceToggle
        }
    }

    private var serviceDescription: String {
        if devices.readOnly {
            return "只读模式 · 无法修改"
        }
        if status.serviceError != nil || serviceRunning == nil {
            return "状态待确认"
        }
        return serviceRunning == true ? "运行中" : "已停用"
    }

    /// 开关只负责启停，停用前确认；节点与策略仍只在代理页选择。
    private var serviceToggle: some View {
        Toggle(
            "代理服务",
            isOn: Binding(
                get: { serviceRunning == true },
                set: { enabled in
                    if enabled { control(.start) } else { confirmStop = true }
                })
        )
        .labelsHidden()
        .tint(.green)
        .disabled(serviceRunning == nil || devices.readOnly || manager.working || status.busy != nil || !devices.webAvailable)
        .accessibilityLabel("代理服务")
        .accessibilityValue(serviceDescription)
    }

    private func control(_ action: ProxyAction) {
        Task { await manager.controlProxyService(action, status: status, devices: devices) }
    }

    private var exitRegion: String {
        guard store.mode != .direct, serviceRunning != false, let exit = store.exitNode else { return "出口" }
        let spec = PolicyIconCatalog.resolve(name: exit.name, iconURL: nil, groupType: nil)
        return spec.regionCode != nil ? spec.title : "出口"
    }

    private var exitTitle: String {
        if case .failed = store.state { return "代理控制未连接" }
        if store.mode == .direct { return "直接连接" }
        if serviceRunning == false { return "代理已停用" }
        return store.exitNode.map { PolicyStore.shortName($0.name) } ?? (store.primaryGroup == nil ? "选择常用策略组" : "未选择代理节点")
    }

    private var exitDetail: String {
        if status.serviceError != nil { return "服务状态待确认" }
        if store.mode == .direct { return "所有请求绕过代理" }
        if serviceRunning == false { return "接入设备直接走蜂窝" }
        if store.mode == .rule {
            return store.primaryGroup.map { "常用策略 · " + $0 } ?? "Mihomo → 更多 → 常用策略组"
        }
        return store.mode.title
    }

    // MARK: 实时速率

    /// 速率直接放进路径卡：与光点同源（Mihomo /traffic 采样），不再单独占一块、也不画曲线。
    private var liveRate: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Group {
                if traffic.hasFreshSample {
                    HStack(spacing: 8) {
                        rateValue("arrow.down", traffic.downText, traffic.downUnit, emphasized: true)
                        rateValue("arrow.up", traffic.upText, traffic.upUnit, emphasized: false)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("下载 \(traffic.downText) \(traffic.downUnit)，上传 \(traffic.upText) \(traffic.upUnit)")
                } else {
                    Text(traffic.updatedAt == nil ? "等待流量数据" : "流量连接中断")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .help(traffic.caption(at: context.date))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(minHeight: 32)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private func rateValue(_ symbol: String, _ value: String, _ unit: String, emphasized: Bool) -> some View {
        let arrow = Text(Image(systemName: symbol))
            .foregroundColor(emphasized ? .accentColor : .secondary)
        let number = Text(value).foregroundColor(emphasized ? .primary : .secondary)
        let suffix = Text(unit).font(.caption2.weight(.bold)).foregroundColor(.secondary)
        // 单个 Text 按完整读数缩放，单位不会比数值先被挤成省略号。
        return Text("\(arrow) \(number) \(suffix)")
            .font(.system(.subheadline, design: .rounded, weight: .bold))
            .monospacedDigit()
            .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            .minimumScaleFactor(0.65)
            .contentTransition(.numericText())
    }

    // MARK: 设备指标

}
