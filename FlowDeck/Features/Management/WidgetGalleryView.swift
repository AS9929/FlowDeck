import SwiftUI
import WidgetKit

/// 与扩展共享布局的原生外观预览；时间线调度和后台操作仍需系统组件验收。
struct WidgetGalleryView: View {
    @State private var zoomed = false
    @State private var scenario = "最近读取"
    private let scenarios = ["最近读取", "数据过期", "连接失败", "无数据"]
    private var entry: SnapshotEntry {
        // 预览使用固定样本，避免一次失败的真实读取污染所有设计样式。
        var snapshot = WidgetSnapshot.placeholder
        snapshot.demo = false
        snapshot.deviceName = "随身"
        snapshot.battery = 100
        snapshot.todayBytes = 10_018_000_000
        snapshot.updatedAt = Date().addingTimeInterval(scenario == "数据过期" ? -600 : -10)
        snapshot.connectionMessage = scenario == "连接失败" ? "设备不在附近，请打开 App 检查" : nil
        return SnapshotEntry(date: Date(), snapshot: scenario == "无数据" ? nil : snapshot)
    }

    var body: some View {
        DetailSheet(title: "小组件预览") {
            Picker("预览状态", selection: $scenario) {
                ForEach(scenarios, id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.menu)
            Toggle("放大模式的紧凑尺寸", isOn: $zoomed)
            Text("使用与桌面组件相同的视图。这里模拟显示状态，不执行组件中的操作。")
                .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            ForEach(WidgetFocus.allCases) { focus in
                VStack(alignment: .leading, spacing: 10) {
                    Label(focus.title, systemImage: focus.symbol).font(.headline)
                    focusedPreview(focus, family: .systemSmall, width: zoomed ? 148 : 164, height: zoomed ? 148 : 164)
                    ViewThatFits(in: .horizontal) {
                        focusedPreview(focus, family: .systemMedium, width: zoomed ? 292 : 344, height: zoomed ? 148 : 164)
                        focusedPreview(focus, family: .systemMedium, width: 260, height: 148)
                    }
                }
            }
            preview(.systemSmall, title: "小号 · 节点与电量", width: zoomed ? 148 : 164, height: zoomed ? 148 : 164)
            preview(.systemMedium, title: "中号 · 状态与快捷入口", width: zoomed ? 292 : 344, height: zoomed ? 148 : 164)
            preview(.systemLarge, title: "大号 · 设备与代理总览", width: zoomed ? 292 : 344, height: zoomed ? 310 : 344)
            preview(.accessoryRectangular, title: "锁屏 · 矩形", width: 180, height: 76)
            preview(.accessoryCircular, title: "锁屏 · 电量", width: 76, height: 76)
            preview(.accessoryInline, title: "锁屏 · 单行", width: 300, height: 32)
        }
    }

    private func focusedPreview(_ focus: WidgetFocus, family: WidgetFamily, width: CGFloat, height: CGFloat) -> some View {
        FocusedWidgetView(entry: entry, focus: focus, previewFamily: family)
            .padding(14)
            .frame(width: width, height: height)
            .background { WidgetBackground().clipShape(RoundedRectangle(cornerRadius: 24)) }
            .allowsHitTesting(false)
    }

    private func preview(_ family: WidgetFamily, title: String, width: CGFloat, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.medium))
            ViewThatFits(in: .horizontal) {
                card(family, width: width, height: height)
                card(family, width: min(width, 260), height: height)
            }
        }
    }

    private func card(_ family: WidgetFamily, width: CGFloat, height: CGFloat) -> some View {
        WidgetView(entry: entry, previewFamily: family)
            .padding(family == .accessoryInline ? 0 : 14)
            .frame(width: width, height: height)
            .background { WidgetBackground().clipShape(RoundedRectangle(cornerRadius: 24)) }
            .allowsHitTesting(false)
    }
}
