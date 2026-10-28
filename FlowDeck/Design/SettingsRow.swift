import SwiftUI

/// 原生分组列表中的导航行，说明只放在确实需要区分任务的入口。
struct SettingsRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    let symbol: String
    var subtitle: String?
    var value: String?
    var disclosure = true

    init(_ title: String, symbol: String, subtitle: String? = nil, value: String? = nil, disclosure: Bool = true) {
        self.title = title
        self.symbol = symbol
        self.subtitle = subtitle
        self.value = value
        self.disclosure = disclosure
    }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                // 大字体时把装饰放在单独一行，把可用宽度留给内容。
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        FeatureIcon(symbol: symbol)
                        Spacer()
                        chevron
                    }
                    labels
                }
            } else {
                HStack(spacing: 12) {
                    FeatureIcon(symbol: symbol)
                    labels
                    chevron
                }
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(AppTypography.rowTitle).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let value {
                Text(value).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var chevron: some View {
        if disclosure {
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }

}

extension View {
    /// 只负责原生导航与页面底色，分组材质由 GlassSection 或玻璃列表行明确提供。
    func nativeSettingsPage(title: String, inline: Bool = false) -> some View {
        listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(inline ? .inline : .large)
    }
}

/// 保留 List 的懒加载和侧滑操作时，用同一玻璃材质替换系统不透明行底色。
struct GlassListBackground: View {
    var body: some View {
        Color.clear
            .glassCard(cornerRadius: 28)
    }
}
