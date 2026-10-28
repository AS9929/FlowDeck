import SwiftUI

/// F50 原生状态与已适配的管理入口；其他功能保留明确的网页入口。
struct UFIDeviceView: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(DeviceStatusStore.self) private var status

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var refreshing = false
    @State private var information = false
    @State private var detail: UFIDetailView.Section?

    var body: some View {
        GlassSheet {
            UFICellularSummary()
            UFISystemSummary()
            refreshStatus
            GlassSection("网络与接入") {
                DestinationRow(
                    "Wi-Fi", symbol: "wifi", subtitle: "双频名称、密码与网络分享", destination: .wifi)
                Divider()
                DestinationRow("接入设备", symbol: "person.2", subtitle: "Wi-Fi 与 USB 接入列表", destination: .clients)
                Divider()
                detailRow(.cellular)
            }
            GlassSection("短信与系统") {
                DestinationRow("短信", symbol: "message", subtitle: "收件、发件、草稿与搜索", destination: .sms)
                Divider()
                detailRow(.hardware)
                Divider()
                DestinationRow(
                    "代理服务", symbol: "power", subtitle: "运行状态、启停与开机自启", destination: .service)
                Divider()
                Button {
                    information = true
                } label: {
                    SettingsRow("本机信息", symbol: "info.circle", subtitle: "型号、固件与管理地址")
                }
            }
            GlassSection("维护与连接") {
                NavigationLink {
                    UFIServiceUpdatesView().appDetailDestination()
                } label: {
                    SettingsRow("UFI-TOOLS 更新", symbol: "shippingbox", subtitle: "安装包、版本校验与恢复")
                }
                Divider()
                NavigationLink {
                    UFIForwardingView().appDetailDestination()
                } label: {
                    SettingsRow("短信自动转发", symbol: "arrowshape.turn.up.right", subtitle: "邮件、钉钉与过滤规则")
                }
                Divider()
                NavigationLink {
                    UFISettingsBackupView().appDetailDestination()
                } label: {
                    SettingsRow(
                        "设置备份", symbol: "externaldrive.badge.checkmark",
                        subtitle: "加密保存 Wi-Fi、APN 与 Mihomo")
                }
                Divider()
                detailRow(.maintenance)
                Divider()
                DestinationRow(
                    "连接与凭据", symbol: "key", subtitle: "UFI 口令与 Mihomo Secret", destination: .pairing)
            }
            GlassSection("网页管理") {
                UFIWebLinks()
            }
        }
        .nativeSettingsPage(title: "设备", inline: true)
        .toolbar { DeviceContextToolbar() }
        .appPush(item: $detail) { UFIDetailView(section: $0) }
        .appPush(isPresented: $information) { UFISystemInformationView() }
        .visibleDeviceTask(tab: 2, enabled: devices.webAvailable) {
            await status.poll()
        }
        .refreshable { await refresh() }
    }

    private func detailRow(_ section: UFIDetailView.Section) -> some View {
        Button {
            detail = section
        } label: {
            SettingsRow(section.title, symbol: section.symbol, subtitle: section.subtitle)
        }
    }

    private var refreshStatus: some View {
        HStack(spacing: 8) {
            if let date = status.snapshotAt {
                Text("更新于 " + date.formatted(date: .omitted, time: .standard))
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                Task { await refresh() }
            } label: {
                HStack(spacing: 5) {
                    if refreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(refreshing ? "刷新中" : "刷新")
                }
                .font(.caption.weight(.semibold))
                .frame(minHeight: 44)
            }
            .disabled(refreshing)
            .animation(AppMotion.feedback(reduceMotion: reduceMotion), value: refreshing)
        }
        .padding(.horizontal, 4)
    }

    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        await status.refreshSnapshot()
        guard !Task.isCancelled else { return }
        await status.refreshService()
    }

}

/// 长固件版本与地址放入独立详情，主页面保留当前状态及常用操作。
private struct UFISystemInformationView: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(DeviceStatusStore.self) private var status

    var body: some View {
        DetailSheet(title: "本机信息") {
            DeviceDetailSummary(
                symbol: "info.circle", title: devices.current?.name ?? "F50",
                subtitle: "UFI-TOOLS + Mihomo")
            GlassSection("型号与版本") {
                DeviceParameterRow(title: "设备型号", value: status.snapshot?.marketName)
                Divider()
                DeviceParameterRow(title: "内部型号", value: status.snapshot?.model)
                Divider()
                DeviceParameterRow(title: "原厂固件", value: status.snapshot?.firmware)
            }
            GlassSection("管理地址") {
                DeviceParameterRow(title: "UFI-TOOLS", value: devices.current?.webURL?.absoluteString)
                Divider()
                DeviceParameterRow(title: "Mihomo", value: devices.current?.mihomoURL?.absoluteString)
            }
        }
    }
}

/// 只拼接管理页面地址，不把 Secret 或密码加入 URL；箭头明确表示即将打开网页。
struct UFIWebLinks: View {
    @Environment(DeviceStore.self) private var devices

    var body: some View {
        if let url = devices.current?.webURL {
            Link(destination: url) {
                HStack(spacing: 10) {
                    SettingsRow(
                        "UFI-TOOLS 网页", symbol: "safari", subtitle: "短信、SIM 与插件",
                        disclosure: false)
                    Image(systemName: "arrow.up.right").font(.caption.weight(.semibold))
                }
            }
        }
        if let url = devices.current?.mihomoURL?.appendingPathComponent("ui/") {
            Link(destination: url) {
                HStack(spacing: 10) {
                    SettingsRow(
                        "Mihomo 网页面板", symbol: "network", subtitle: "配置文件与内核管理 · 首次连接需 Secret",
                        disclosure: false)
                    Image(systemName: "arrow.up.right").font(.caption.weight(.semibold))
                }
            }
        }
    }
}

struct UFIUnsupportedView: View {
    var body: some View {
        DetailSheet(title: "F50 接入范围") {
            DeviceDetailSummary(
                symbol: "wrench.and.screwdriver", title: "此项尚未适配 F50",
                subtitle: "此项原厂设置或文件操作可在设备网页中完成。")
            GlassSection("设备网页") { UFIWebLinks() }
        }
    }
}

/// F50 配置页仅暴露公共 Mihomo API 和受控服务入口，避免通过 shell 上传节点密钥。
struct UFIProxyConfigurationView: View {
    @State private var cache = false
    var body: some View {
        GlassSheet {
            DeviceDetailSummary(
                symbol: "slider.horizontal.3", title: "Mihomo 配置",
                subtitle: "运行参数、规则数据与设备上的配置文件")
            GlassSection("代理运行") {
                DestinationRow(
                    "运行设置", symbol: "slider.horizontal.3", subtitle: "当前核心的运行参数", destination: .runtime)
                Divider()
                DestinationRow("代理服务", symbol: "power", subtitle: "启动、停止与开机自启", destination: .service)
            }
            GlassSection("DNS 与缓存") {
                DestinationRow("DNS 查询", symbol: "network", destination: .dns)
                Divider()
                Button {
                    cache = true
                } label: {
                    SettingsRow("缓存管理", symbol: "arrow.triangle.2.circlepath", subtitle: "DNS 与 Fake-IP")
                }
            }
            GlassSection("规则与分流") {
                DestinationRow("规则集", symbol: "arrow.triangle.2.circlepath", destination: .providers)
                Divider()
                DestinationRow("分流规则", symbol: "list.bullet.rectangle", destination: .rules)
            }
            GlassSection("配置文件与版本") {
                UFIWebLinks()
            }
            Text("文件导入与内核升级请使用设备网页，保留 F50 的透明代理端口及 DNS 设置。")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .appPush(isPresented: $cache) { ProxyCacheView() }
    }
}
