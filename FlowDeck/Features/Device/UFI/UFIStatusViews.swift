import SwiftUI

/// F50 蜂窝摘要：实际读数与新鲜度分开呈现，蜂窝注册不代表代理出口已验证。
struct UFICellularSummary: View {
    @Environment(DeviceStatusStore.self) private var status
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let snapshot = status.snapshot
            let state = OverviewNetworkState(
                connected: snapshot?.connected, updatedAt: status.snapshotAt,
                error: status.snapshotError, now: context.date)
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    FeatureIcon(symbol: "antenna.radiowaves.left.and.right")
                    VStack(alignment: .leading, spacing: 5) {
                        Text(snapshot?.operatorName ?? "蜂窝网络")
                            .font(.headline.weight(.bold))
                        HStack(spacing: 5) {
                            Circle()
                                .fill(state.isConnected ? Color.green : .secondary)
                                .frame(width: 6, height: 6)
                                .accessibilityHidden(true)
                            Text(
                                snapshot?.cellularStatusError != nil && status.snapshotError == nil
                                    ? "蜂窝状态未读取" : state.title
                            )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                UFIAdaptiveMetrics {
                    UFIMetricTile(
                        title: "网络制式", symbol: "network", value: snapshot?.networkType ?? "—")
                    UFIMetricTile(
                        title: snapshot?.isNR == true ? "5G 信号" : "LTE 信号",
                        symbol: "cellularbars", value: snapshot?.rsrp.map { "\(Int($0))" } ?? "—", unit: "dBm")
                }
                if let bars = snapshot?.signalBars {
                    HStack(spacing: 10) {
                        HStack(alignment: .bottom, spacing: 3) {
                            ForEach(0..<5) { index in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(index < bars ? Color.accentColor : Color.primary.opacity(0.1))
                                    .frame(width: 5, height: CGFloat(6 + index * 3))
                            }
                        }
                        .accessibilityHidden(true)
                        Text("信号\(snapshot?.signalQuality ?? "未读取")")
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                    .animation(AppMotion.workspace(reduceMotion: reduceMotion), value: bars)
                }
                if let error = status.snapshotError ?? snapshot?.cellularStatusError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .glassCard()
    }
}

/// 系统指标复用于总览与设备页；内存条显示已用比例，不使用估算的电池或温度。
struct UFISystemSummary: View {
    @Environment(DeviceStatusStore.self) private var status
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let heading =
                typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 8))
            heading {
                HStack(spacing: 8) {
                    Image(systemName: "cpu").foregroundStyle(Color.accentColor)
                    Text("系统运行").font(.headline.weight(.bold))
                }
                if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                Text("UFI-TOOLS").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            UFIAdaptiveMetrics {
                UFIMetricTile(
                    title: "已运行", symbol: "clock",
                    value: status.snapshot?.uptime.map { "\($0 / 3600)h \(($0 % 3600) / 60)m" } ?? "—",
                    spokenValue: status.snapshot?.uptime.map { "\($0 / 3600) 小时 \(($0 % 3600) / 60) 分钟" })
                UFIMetricTile(
                    title: "可用内存", symbol: "memorychip",
                    value: status.snapshot?.memAvailKB.map { String($0 / 1024) } ?? "—", unit: "MB")
            }
            if let available = status.snapshot?.memAvailKB, let total = status.snapshot?.memTotalKB,
                total > 0, available >= 0, available <= total
            {
                let used = Double(total - available) / Double(total)
                VStack(alignment: .leading, spacing: 7) {
                    ProgressView(value: used)
                        .tint(.accentColor)
                        .animation(AppMotion.workspace(reduceMotion: reduceMotion), value: used)
                        .accessibilityLabel("已用内存")
                        .accessibilityValue("\(Int(used * 100))%")
                    Text("已用 \(Int(used * 100))% · 总计 \(total / 1024) MB")
                        .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            if status.snapshotError != nil {
                Text("显示上次数据，等待重新连接")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(18)
        .glassCard()
    }
}

/// 数据块只使用轻染色底，不在同一卡片内部重复添加玻璃或模糊。
private struct UFIMetricTile: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    let symbol: String
    let value: String
    var unit = ""
    var spokenValue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: symbol).foregroundStyle(Color.accentColor).accessibilityHidden(true)
                Text(title).foregroundStyle(.secondary)
            }
            .font(.caption.weight(.semibold))
            Text("\(Text(value).font(.system(.title3, design: .rounded, weight: .bold)))\(unit.isEmpty ? "" : " \(unit)")")
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                .minimumScaleFactor(0.75)
                .contentTransition(reduceMotion ? .identity : .numericText())
                .animation(AppMotion.workspace(reduceMotion: reduceMotion), value: value)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(spokenValue ?? "\(value) \(unit)")
    }
}

/// 常规及放大显示保留双列；辅助功能字号使用整行宽度，避免压缩阅读字号。
private struct UFIAdaptiveMetrics<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ViewBuilder let content: () -> Content

    var body: some View {
        let layout =
            typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
        layout { content() }
    }
}

/// F50 服务摘要不将进程存在等同于控制 API 或代理出口可用。
struct UFIServiceSummary: View {
    @Environment(DeviceStatusStore.self) private var status
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DeviceDetailSummary(
                symbol: "power",
                title: status.service.map { $0.running ? "Mihomo 运行中" : "Mihomo 已停止" } ?? "等待服务状态",
                subtitle: "为连接此设备的客户端提供规则分流")
            UFIAdaptiveMetrics {
                UFIMetricTile(
                    title: "控制 API", symbol: "point.3.connected.trianglepath.dotted",
                    value: status.service.map { $0.apiReachable ? "可访问" : "未连接" } ?? "—")
                UFIMetricTile(
                    title: "开机自启", symbol: "arrow.clockwise.circle",
                    value: status.service.map { $0.autostart ? "已开启" : "已关闭" } ?? "—")
            }
        }
        .animation(AppMotion.workspace(reduceMotion: reduceMotion), value: status.service?.running)
        .padding(18)
        .glassCard()
    }
}
