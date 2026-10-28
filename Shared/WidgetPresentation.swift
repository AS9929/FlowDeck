import SwiftUI
import WidgetKit

/// 组件与 App 内外观预览共用同一视图；不在渲染时读取钥匙串或发起网络请求。
struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    var actionError: String? = nil
}

struct WidgetBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        LinearGradient(
            colors: scheme == .dark
                ? [Color(red: 0.06, green: 0.18, blue: 0.23), Color(red: 0.11, green: 0.10, blue: 0.22)]
                : [Color(red: 0.85, green: 0.96, blue: 0.97), Color(red: 0.91, green: 0.91, blue: 1)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct WidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry
    var previewFamily: WidgetFamily? = nil

    private var issue: String? { entry.actionError ?? entry.snapshot?.connectionMessage }

    var body: some View {
        // Widget 的物理槽位不会随字体增长；保持可读的固定排版，完整数据同时提供给 VoiceOver。
        content.dynamicTypeSize(.large)
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = entry.snapshot {
            switch previewFamily ?? family {
            case .accessoryCircular:
                Gauge(value: Double(snapshot.battery ?? 0), in: 0...100) {
                    Image(systemName: issue != nil ? "exclamationmark" : snapshot.isStale(at: entry.date) ? "clock" : "battery.75percent")
                } currentValueLabel: {
                    Text(snapshot.battery.map(String.init) ?? "—")
                }
                .gaugeStyle(.accessoryCircular)
                .accessibilityLabel("设备电量 \(snapshot.battery.map(String.init) ?? "未知")，\(snapshot.statusText(at: entry.date))")
            case .accessoryInline:
                Text("\(snapshot.statusText(at: entry.date)) · \(exitText(snapshot))")
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    Text(exitText(snapshot)).font(.headline).lineLimit(1)
                    Text("\(snapshot.mode) · 电量 \(snapshot.battery.map { "\($0)%" } ?? "—")").font(.caption)
                    Text(issue == nil ? snapshot.statusText(at: entry.date) : "操作未完成，请打开 App").font(.caption2)
                }
            case .systemMedium: medium(snapshot)
            case .systemLarge: large(snapshot)
            default: small(snapshot)
            }
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        // 锁屏组件可用面积很小，不能沿用主屏幕的三行说明。
        switch previewFamily ?? family {
        case .accessoryCircular:
            Image(systemName: "wifi.router").accessibilityLabel("设备尚无设备数据，打开 App 连接")
        case .accessoryInline:
            Text("等待设备数据")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text("设备尚未连接").font(.headline)
                Text("打开 App 读取状态").font(.caption)
            }
        default:
            VStack(alignment: .leading, spacing: 8) {
                Label(AppBrand.name, systemImage: "wifi.router").font(.headline)
                Text("等待设备数据").font(.subheadline.weight(.semibold))
                Text("轻点打开 App，连接并读取设备状态。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func exitText(_ snapshot: WidgetSnapshot) -> String {
        if snapshot.proxyRunning == false { return "代理已停止" }
        if snapshot.mode == "直连" { return "直接连接" }
        return snapshot.exitName ?? "尚未读取节点"
    }

    private func header(_ snapshot: WidgetSnapshot) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "wifi.router").widgetAccentable()
            Text(snapshot.deviceName).lineLimit(2).minimumScaleFactor(0.85)
            Spacer(minLength: 2)
            Text(issue == nil ? snapshot.statusText(at: entry.date) : "待检查")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).fixedSize()
        }.font(.caption2.weight(.semibold))
    }

    private func node(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(exitText(snapshot)).font(.system(.headline, design: .rounded)).lineLimit(2).minimumScaleFactor(0.85)
            HStack(spacing: 5) {
                Text(snapshot.mode)
                if let delay = snapshot.delay, snapshot.proxyRunning != false, snapshot.mode != "直连" {
                    Text("·")
                    Text(delay == 0 ? "上次测试超时" : "\(delay) ms")
                }
            }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func footer(_ snapshot: WidgetSnapshot) -> some View {
        HStack {
            if let issue {
                Text(issue).lineLimit(1)
            } else if snapshot.updatedAt == .distantPast {
                Text("尚未读取")
            } else {
                Text("更新于")
                Text(snapshot.updatedAt, style: .time)
            }
        }.font(.system(size: 10)).foregroundStyle(.secondary)
    }

    private func small(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(snapshot.deviceName)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(2).minimumScaleFactor(0.9)
            Text(exitText(snapshot))
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .lineLimit(2).minimumScaleFactor(0.8)
            HStack(spacing: 4) {
                Text(snapshot.mode)
                if let delay = snapshot.delay, snapshot.proxyRunning != false, snapshot.mode != "直连" {
                    Text(delay == 0 ? "· 超时" : "· \(delay) ms")
                }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            // 小号组件不把电量、用量挤在同一行，100% 与大流量都能完整显示。
            HStack(spacing: 5) {
                Image(systemName: snapshot.charging ? "bolt.batteryblock" : "battery.75percent")
                Text(snapshot.battery.map { "\($0)%" } ?? "—")
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, weight: .medium)).monospacedDigit().fixedSize(horizontal: false, vertical: true)
            Text("今日 " + bytes(snapshot.todayBytes))
                .font(.system(size: 11)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            HStack(spacing: 4) {
                if issue != nil {
                    Text("连接待检查")
                } else if snapshot.isStale(at: entry.date) {
                    Text("待刷新")
                } else if snapshot.demo {
                    Text("演示")
                } else {
                    Text("更新")
                }
                if snapshot.updatedAt != .distantPast { Text(snapshot.updatedAt, style: .time) }
            }
            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func medium(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            header(snapshot)
            HStack(alignment: .top, spacing: 16) {
                Link(destination: AppIdentity.url(for: "policy")) { node(snapshot).frame(maxWidth: .infinity, alignment: .leading) }
                    .tint(.primary)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(bytes(snapshot.todayBytes)).font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text("今日蜂窝 · \(snapshot.clients.map(String.init) ?? "—") 台接入").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            HStack {
                footer(snapshot)
                Spacer(minLength: 4)
                actions
            }
        }
    }

    private func large(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header(snapshot)
            Link(destination: AppIdentity.url(for: "policy")) { node(snapshot) }.tint(.primary)
            Divider()
            HStack {
                metric("今日蜂窝", bytes(snapshot.todayBytes), symbol: "arrow.up.arrow.down")
                metric("设备电量", snapshot.battery.map { "\($0)%" } ?? "—", symbol: "battery.75percent")
            }
            HStack {
                metric("信号强度", snapshot.rsrp.map { "\($0) dBm" } ?? "—", symbol: "antenna.radiowaves.left.and.right")
                metric("接入设备", snapshot.clients.map { "\($0) 台" } ?? "—", symbol: "person.2")
            }
            Spacer(minLength: 0)
            HStack {
                footer(snapshot)
                Spacer()
                actions
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button(intent: U60DirectActionIntent(action: .refresh)) { Image(systemName: "arrow.clockwise") }
                .accessibilityLabel("刷新设备状态")
            Link(destination: AppIdentity.url(for: "policy")) { Image(systemName: "point.3.connected.trianglepath.dotted") }
                .accessibilityLabel("选择代理节点")
            Link(destination: AppIdentity.url(for: "service")) { Image(systemName: "power") }
                .accessibilityLabel("管理代理服务")
        }
        .font(.system(size: 17)).buttonStyle(.plain)
    }

    private func metric(_ title: String, _ value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .rounded, weight: .medium)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bytes(_ value: Int64?) -> String {
        value.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .binary) } ?? "—"
    }
}
