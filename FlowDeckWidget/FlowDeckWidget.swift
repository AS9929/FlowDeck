import SwiftUI
import WidgetKit

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { SnapshotEntry(date: Date(), snapshot: .placeholder) }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snapshot: WidgetSnapshot.load() ?? (context.isPreview ? .placeholder : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetSnapshot.load()
        let issue = UserDefaults(suiteName: WidgetSnapshot.appGroup)?.string(forKey: "widget.error")
        var entries = [SnapshotEntry(date: now, snapshot: snapshot, actionError: issue)]
        if let snapshot, snapshot.updatedAt.addingTimeInterval(120) > now {
            entries.append(SnapshotEntry(date: snapshot.updatedAt.addingTimeInterval(120), snapshot: snapshot, actionError: issue))
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
    }
}

/// 主屏幕与锁屏小组件：出口节点、延迟、电量、信号、今日蜂窝流量。点按打开 App。
struct U60StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "U60Status", provider: SnapshotProvider()) { entry in
            WidgetView(entry: entry)
                .containerBackground(for: .widget) { WidgetBackground() }
                .widgetURL(AppIdentity.url(for: "overview"))
        }
        .configurationDisplayName("设备总览")
        .description("当前出口、延迟、电量和今日蜂窝流量。展示最近采样时间；中号、大号支持刷新与管理入口。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct FlowDeckWidgetBundle: WidgetBundle {
    var body: some Widget {
        U60StatusWidget()
        DeviceGaugeWidget()
        ProxyExitWidget()
        U60RecoveryWidget()
        if #available(iOS 18.0, *) {
            U60ServiceControl()
            U60DiagnosticsControl()
            U60NextNodeControl()
            U60ModeControl()
        }
    }
}

/// 聚焦电量、蜂窝信号与接入情况，点按进入设备页。
struct DeviceGaugeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DeviceGauge", provider: SnapshotProvider()) { entry in
            FocusedWidgetView(entry: entry, focus: .device)
                .containerBackground(for: .widget) { WidgetBackground() }
                .widgetURL(AppIdentity.url(for: "device"))
        }
        .configurationDisplayName("设备仪表")
        .description("环形电量仪表，配合蜂窝信号、接入数量和今日用量。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// 聚焦当前出口与最近测试延迟，点按进入策略选择。
struct ProxyExitWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ProxyExit", provider: SnapshotProvider()) { entry in
            FocusedWidgetView(entry: entry, focus: .proxy)
                .containerBackground(for: .widget) { WidgetBackground() }
                .widgetURL(AppIdentity.url(for: "policy"))
        }
        .configurationDisplayName("代理出口")
        .description("当前节点、出站模式和上次测试延迟；轻点管理策略。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
