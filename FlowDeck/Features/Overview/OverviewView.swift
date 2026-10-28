import SwiftUI

/// 首页以默认连接路径和代理控制为主区，分别呈现核心速率、无线信号、电量与蜂窝用量。
/// 路径示意不充当出口探测结果；设备未返回的新鲜数据不显示为已联网。
struct OverviewView: View {
    @Environment(PolicyStore.self) private var store
    @Environment(DeviceStore.self) private var devices
    @Environment(DeviceStatusStore.self) private var status
    @Environment(ManagementStore.self) private var manager
    @Environment(AppRouter.self) private var router
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var traffic = TrafficMonitor()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if showsOnboarding {
                    if devices.current != nil,
                        let issue = devices.accessIssue(for: .mihomo)
                    {
                        DeviceAccessNotice(issue: issue)
                    } else {
                        onboarding
                    }
                } else {
                    // 沿用独立的背景玻璃，文字与控件不参与材质合成。
                    TimelineView(.periodic(from: .now, by: 5)) { context in
                        let state = networkState(at: context.date)
                        VStack(alignment: .leading, spacing: 18) {
                            header(state)
                            OverviewConnectionCard(state: state, traffic: traffic)
                        }
                    }
                    if devices.usesUFI {
                        ufiMetrics
                    } else {
                        gauges
                    }
                    shortcuts
                    footnote
                }
            }
            .padding(.horizontal, AppTheme.pageInset)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(AppBackground())
        .navigationTitle("总览")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { DeviceContextToolbar() }
        .refreshable { await refresh() }
        .visibleDeviceTask(tab: 0, enabled: devices.mihomoAvailable) {
            await traffic.run(store.client)
        }
        .visibleDeviceTask(tab: 0, enabled: devices.webAvailable) {
            await status.poll()
        }
    }

    /// Debug 预览只绕过接入引导，仍由现有演示客户端提供数据，不创建设备或凭据。
    private var showsOnboarding: Bool {
        !devices.demoMode && !devices.mihomoAvailable
    }

    // MARK: 接入引导

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: "wifi.router").font(.system(size: 48, weight: .regular)).foregroundStyle(Color.accentColor)
            Text("接入你的随身网络")
                .font(.largeTitle.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("连接已部署的设备，集中管理网络状态与 Mihomo。")
                .font(.body.weight(.medium)).foregroundStyle(.secondary)
            NavigationLink {
                DeviceOnboardingView().appDetailDestination()
            } label: {
                Label("接入我的设备", systemImage: "plus.circle.fill")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            Text("支持 WebSSH + Mihomo、UFI-TOOLS + Mihomo。首次安装请在电脑上完成，再回到 App 接入。")
                .font(.subheadline.weight(.medium)).foregroundStyle(.secondary).lineSpacing(10)
            Button("先体验演示", systemImage: "play.rectangle") {
                devices.demoMode = true
            }
            .buttonStyle(.bordered)
            Text("接入前不会读取或修改设备。演示使用示例数据，可随时在设置中退出。")
                .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 20)
    }

    // MARK: 设备与网络状态

    private func networkState(at now: Date) -> OverviewNetworkState {
        OverviewNetworkState(
            connected: status.snapshot?.connected, updatedAt: status.snapshotAt,
            error: status.snapshotError, now: now, managementAvailable: devices.webAvailable)
    }

    /// 设备名作为页面大标题；正常时副标题只给网络事实，异常时换成状态标题并给出处理入口。
    private func header(_ state: OverviewNetworkState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(devices.demoMode ? "演示设备" : devices.current?.name ?? "总览")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .lineLimit(1).minimumScaleFactor(0.7)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(state.isConnected ? Color.green : state.needsAttention ? Color.orange : Color.secondary)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(
                    status.snapshot?.cellularStatusError != nil && status.snapshotError == nil
                        ? "UFI-TOOLS · 蜂窝状态未读取" : state.subtitle(cellular: cellularSummary)
                )
                .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if state.needsAttention, let detail = state.detail {
                Text(detail).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            if state.needsAttention && !devices.usesUFI {
                Button {
                    router.sheet = .diagnostics
                } label: {
                    Label("检查网络连接", systemImage: "stethoscope")
                        .font(AppTypography.compactTitle).frame(minHeight: 44)
                }
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private var gauges: some View {
        let snapshot = status.snapshot
        let day = snapshot?.dayRx.map { $0 + (snapshot?.dayTx ?? 0) }
        let month = snapshot?.monthRx.map { $0 + (snapshot?.monthTx ?? 0) }
        let layout =
            typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
        return layout {
            OverviewMetricTile(title: "无线信号") {
                Image("FlowCellular")
                    .resizable().scaledToFit()
                    .frame(width: 28, height: 28)
                    .foregroundStyle(snapshot?.rsrp == nil ? Color.secondary : Color.accentColor)
                    .frame(height: 32)
                    .accessibilityHidden(true)
                Text(snapshot?.signalQuality ?? "—")
                    .font(.headline).fixedSize(horizontal: false, vertical: true)
                Text(snapshot?.rsrp.map { String(format: "%.0f dBm", $0) } ?? "未读取")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            OverviewMetricTile(title: snapshot?.charging == true ? "正在充电" : "设备电量") {
                BatteryChargeGlyph(battery: snapshot?.battery, charging: snapshot?.charging == true)
                    .frame(height: 32)
                Text(snapshot?.battery.map { "\($0)%" } ?? "—")
                    .font(.headline.weight(.bold)).monospacedDigit()
                Text(snapshot?.batteryTemp.map { String(format: "%.0f °C", $0) } ?? "温度未知")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            OverviewMetricTile(title: "今日蜂窝") {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(height: 32)
                    .accessibilityHidden(true)
                Text(day.map { OverviewGauge.short($0) + " " + OverviewGauge.unit($0) } ?? "—")
                    .font(.headline.weight(.bold)).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                Text(month.map { "本月 " + OverviewGauge.short($0) + " " + OverviewGauge.unit($0) } ?? "本月未读取")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 入口

    private var ufiMetrics: some View {
        UFISystemSummary()
    }

    private var shortcuts: some View {
        VStack(spacing: 0) {
            if devices.usesUFI {
                shortcut("Wi-Fi", symbol: "wifi", value: "双频网络", destination: .wifi)
                Divider().padding(.leading, 50)
                shortcut("接入设备", symbol: "person.2", value: "查看", destination: .clients)
                Divider().padding(.leading, 50)
                shortcut("连接与凭据", symbol: "key", value: "UFI-TOOLS", destination: .pairing)
                Divider().padding(.leading, 50)
                shortcut("代理服务", symbol: "power", value: "管理", destination: .service)
            } else {
                shortcut("Wi-Fi", symbol: "wifi", value: status.snapshot?.ssid24 ?? status.snapshot?.ssid5 ?? "—", destination: .wifi)
                Divider().padding(.leading, 50)
                shortcut("接入设备", symbol: "person.2", value: status.snapshot?.clientsTotal.map { "\($0) 台" } ?? "—", destination: .clients)
                Divider().padding(.leading, 50)
                shortcut("网络诊断", symbol: "stethoscope", value: "检查", destination: .diagnostics)
            }
        }
        .glassCard(cornerRadius: 22)
    }

    private func shortcut(_ title: String, symbol: String, value: String, destination: ManagementDestination) -> some View {
        Button {
            router.sheet = destination
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.accentColor).frame(width: 26)
                    Text(title).font(AppTypography.compactTitle).foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    if !typeSize.isAccessibilitySize {
                        Text(value).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                }
                if typeSize.isAccessibilitySize {
                    Text(value).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footnote: some View {
        VStack(spacing: 6) {
            if devices.readOnly {
                Label("只读模式 · 设备写入已锁定", systemImage: "lock.shield").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            if let date = status.snapshotAt {
                Text("设备数据更新于 " + date.formatted(date: .omitted, time: .shortened))
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var cellularSummary: String {
        [status.snapshot?.operatorName, status.snapshot?.networkType, status.snapshot?.bandLabel]
            .compactMap { $0 }.joined(separator: " · ").ifEmpty("等待设备返回网络信息")
    }

    private func refresh() async {
        if devices.mihomoAvailable { await store.refresh() }
        if devices.webAvailable {
            await status.refreshSnapshot()
            await status.refreshService()
        }
    }
}
