import SwiftUI

/// 首页连接路径与指标图形，仅负责展示。
struct FlowPath: View {
    struct Node {
        let asset: String
        let title: String
        var emphasized = false
    }

    let nodes: [Node]
    var flowing = false
    let attention: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var lineColor: Color { attention ? .orange : .accentColor }
    private var animating: Bool { flowing && !reduceMotion && !typeSize.isAccessibilitySize }

    var body: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: 10),
            count: typeSize.isAccessibilitySize ? 2 : max(nodes.count, 1))
        LazyVGrid(columns: columns, alignment: .center, spacing: 16) {
            ForEach(nodes.indices, id: \.self) { index in
                let node = nodes[index]
                VStack(spacing: 6) {
                    Image(node.asset)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 25, height: 25)
                        .foregroundStyle(lineColor)
                        .frame(width: 44, height: 44)
                        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 14))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(lineColor.opacity(node.emphasized ? 0.35 : 0.16), lineWidth: 1)
                        }
                    Text(node.title)
                        .font(node.emphasized ? .caption.weight(.bold) : .caption.weight(.semibold))
                        .foregroundStyle(node.emphasized ? .primary : .secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .background(alignment: .top) {
            if !typeSize.isAccessibilitySize {
                // 三个光点沿路径流动，只在有真实吞吐时出现；减少动态效果时静止。
                TimelineView(.animation(paused: !animating)) { context in
                    Canvas { ctx, size in
                        let inset = size.width / CGFloat(max(nodes.count, 1)) / 2
                        let y: CGFloat = 22
                        var line = Path()
                        line.move(to: CGPoint(x: inset, y: y))
                        line.addLine(to: CGPoint(x: size.width - inset, y: y))
                        ctx.stroke(line, with: .color(lineColor.opacity(attention ? 0.5 : 0.2)), lineWidth: 1.5)
                        guard animating else { return }
                        let t = context.date.timeIntervalSinceReferenceDate / 4.2
                        for index in 0..<3 {
                            let phase = (t + Double(index) / 3).truncatingRemainder(dividingBy: 1)
                            let x = inset + (size.width - inset * 2) * phase
                            let fade = min(phase / 0.08, (1 - phase) / 0.08, 1)
                            var glow = ctx
                            glow.addFilter(.blur(radius: 1.5))
                            glow.fill(Path(ellipseIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)), with: .color(lineColor.opacity(0.9 * fade)))
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("连接路径：" + nodes.map(\.title).joined(separator: "，") + (flowing ? "，流量传输中" : attention ? "，连接异常" : "") + "。出口连通性请用检测出口确认。")
    }
}

// MARK: - 设备指标

enum OverviewGauge {
    /// 与设备的信号质量标签保持同一阈值；缺失值不伪装为零格或弱信号。
    static func signalLevel(rsrp: Double?) -> Int? {
        guard let rsrp, rsrp.isFinite else {
            return nil
        }
        if rsrp >= -90 {
            return 4
        }
        if rsrp >= -105 {
            return 3
        }
        if rsrp >= -115 {
            return 2
        }
        return 1
    }

    static func short(_ bytes: Int64) -> String {
        let value = Double(bytes)
        if value >= 10 * 1_073_741_824 { return String(format: "%.0f", value / 1_073_741_824) }
        if value >= 1_073_741_824 { return String(format: "%.2f", value / 1_073_741_824) }
        if value >= 1_048_576 { return String(format: "%.0f", value / 1_048_576) }
        return String(format: "%.0f", value / 1024)
    }

    static func unit(_ bytes: Int64) -> String {
        let value = Double(bytes)
        if value >= 1_073_741_824 { return "GB" }
        if value >= 1_048_576 { return "MB" }
        return "KB"
    }
}

/// 三项指标保留统一的玻璃底座，各自使用符合含义的可视化；辅助字号允许自然增高。
struct OverviewMetricTile<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 9) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .top)
        .padding(.vertical, 12).padding(.horizontal, 8)
        .glassCard(cornerRadius: 22)
        .accessibilityElement(children: .combine)
    }
}

/// 横向电池轮廓表达真实电量，数字独立排版；未知值不绘制虚假的剩余电量。
struct BatteryChargeGlyph: View {
    let battery: Int?
    let charging: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: CGFloat { min(max(CGFloat(battery ?? 0) / 100, 0), 1) }
    private var tint: Color { battery.map { $0 <= 20 && !charging ? .orange : .accentColor } ?? .secondary }

    var body: some View {
        HStack(spacing: 2) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(tint.opacity(0.65), lineWidth: 1.8)
                RoundedRectangle(cornerRadius: 3)
                    .fill(tint.opacity(0.22))
                    .frame(width: 34 * fraction, height: 14)
                    .padding(.leading, 4)
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 42, height: 22)
            Capsule().fill(tint.opacity(0.65)).frame(width: 3, height: 9)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: fraction)
        .accessibilityHidden(true)
    }
}

/// 新鲜度与联网状态分开判断；设备旧快照不能被包装为当前已联网。
