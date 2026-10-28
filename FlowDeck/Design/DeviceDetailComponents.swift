import SwiftUI

/// 设备详情的紧凑状态摘要。正文随动态字体换行，不依赖固定卡片高度。
struct DeviceDetailSummary: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        let layout =
            typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        layout {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(AppTypography.detailTitle).foregroundStyle(.primary)
                Text(subtitle).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 长版本号和标识按上下两行显示，复制保留原值，避免巨大的两列表格挤压值。
struct DeviceParameterRow: View {
    let title: String
    let value: String?
    var symbol = "doc.on.doc"
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if let value, !value.isEmpty {
                    Button {
                        UIPasteboard.general.setItems(
                            [["public.utf8-plain-text": value]],
                            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : symbol)
                            .font(.system(size: 14))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("复制" + title)
                }
            }
            Text(value.flatMap { $0.isEmpty ? nil : $0 } ?? "尚未读取")
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: value) { _, _ in copied = false }
    }
}
