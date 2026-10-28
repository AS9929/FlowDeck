import SwiftUI
import WidgetKit

/// 两种按任务区分的组件布局；只展示带采样时间的真实快照，不生成模拟趋势。
enum WidgetFocus: String, CaseIterable, Identifiable {
    case device, proxy
    var id: String { rawValue }
    var title: String { self == .device ? "设备仪表" : "代理出口" }
    var symbol: String { self == .device ? "wifi.router" : "arrow.triangle.branch" }
}

struct FocusedWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry
    let focus: WidgetFocus
    var previewFamily: WidgetFamily?

    private var medium: Bool { (previewFamily ?? family) == .systemMedium }
    private var accent: Color { focus == .device ? .cyan : .purple }

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                VStack(alignment: .leading, spacing: 6) {
                    Label(snapshot.deviceName, systemImage: focus.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.8)
                    HStack(alignment: .center, spacing: 14) {
                        if focus == .device {
                            battery(snapshot)
                        } else {
                            proxy(snapshot)
                        }
                        if medium {
                            Divider()
                            details(snapshot)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    HStack(spacing: 4) {
                        Text(snapshot.statusText(at: entry.date))
                        Spacer(minLength: 0)
                        Text(snapshot.updatedAt, style: .time).monospacedDigit()
                    }
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label(focus.title, systemImage: focus.symbol).font(.headline)
                    Text("打开 App 连接设备").font(.caption)
                }
            }
        }
        .dynamicTypeSize(.large)
    }

    private func battery(_ snapshot: WidgetSnapshot) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(accent.opacity(0.16), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: CGFloat(min(100, max(0, snapshot.battery ?? 0))) / 100)
                    .stroke(accent.gradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: snapshot.charging ? "bolt.fill" : "battery.75percent")
                    .font(.system(size: 18)).foregroundStyle(accent)
            }
            .frame(width: 42, height: 42)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.battery.map { "\($0)%" } ?? "—")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(snapshot.charging ? "正在充电" : "设备电量")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func proxy(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(snapshot.proxyRunning == false ? "代理已停止" : snapshot.mode == "直连" ? "直接连接" : snapshot.exitName ?? "节点未读取")
                .font(.system(size: medium ? 20 : 16, weight: .semibold, design: .rounded))
                .lineLimit(2).minimumScaleFactor(0.8)
            Label(snapshot.mode, systemImage: snapshot.mode == "直连" ? "arrow.up.right" : snapshot.mode == "全局" ? "globe" : "arrow.triangle.branch")
                .font(.system(size: 11)).foregroundStyle(accent)
            if !medium {
                Text(delay(snapshot)).font(.system(size: 11, weight: .medium)).monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func details(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if focus == .device {
                Label(snapshot.rsrp.map { "\($0) dBm" } ?? "信号未读取", systemImage: "antenna.radiowaves.left.and.right")
                Label(snapshot.clients.map { "\($0) 台接入" } ?? "接入未读取", systemImage: "person.2")
                Text(snapshot.todayBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .binary) + " · 今日" } ?? "用量未读取")
            } else {
                Text(delay(snapshot)).font(.system(size: 20, weight: .semibold, design: .rounded))
                Text("上次测试延迟").foregroundStyle(.secondary)
                Text(snapshot.proxyRunning.map { $0 ? "服务运行中" : "服务已停止" } ?? "服务未读取")
            }
        }
        .font(.system(size: 11)).monospacedDigit()
        .lineLimit(1).minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func delay(_ snapshot: WidgetSnapshot) -> String {
        guard snapshot.proxyRunning != false, snapshot.mode != "直连", let delay = snapshot.delay else { return "—" }
        return delay > 0 ? "\(delay) ms" : "超时"
    }
}
