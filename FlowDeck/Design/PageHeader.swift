import SwiftUI

/// 四个主页面共用的标题比例；辅助说明统一位于标题下方。
struct PageHeader<Trailing: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        let layout =
            typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        layout {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// 与余量一致的 44pt 圆角玻璃操作按钮。
struct CircleGlassLabel: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 44, height: 44)
            .glassCard(cornerRadius: 16, interactive: true)
    }
}

/// 所有滚动详情共用的原生导航容器，关闭操作固定在导航栏，不随内容滚走。
/// 正在执行的不可中断操作通过 closeDisabled 保持原有关闭边界。
struct DetailSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPushedDetail) private var isPushed
    let title: String
    var doneTitle = "完成"
    var closeDisabled = false
    var onDone: (() -> Void)?
    var primaryTitle: String?
    var primaryDisabled = false
    var onPrimary: (() -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        DetailNavigationContainer {
            GlassSheet(content: content)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarBackButtonHidden(closeDisabled)
                .toolbar {
                    if !isPushed || closeDisabled {
                        ToolbarItem(placement: primaryTitle == nil ? .confirmationAction : .cancellationAction) {
                            Button(doneTitle) {
                                if let onDone { onDone() } else { dismiss() }
                            }
                            .disabled(closeDisabled)
                        }
                    }
                    if let primaryTitle, let onPrimary {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(primaryTitle, action: onPrimary)
                                .fontWeight(.semibold)
                                .disabled(primaryDisabled)
                        }
                    }
                }
        }
        .frame(width: AppTheme.auditWidth)
    }
}

/// List 详情保留原生懒加载、侧滑与搜索，同时获得统一导航栏。
struct DetailListShell<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPushedDetail) private var isPushed
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        DetailNavigationContainer {
            content()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if !isPushed {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { dismiss() }
                        }
                    }
                }
        }
        .frame(width: AppTheme.auditWidth)
    }
}

extension View {
    /// 标题与页面内容左边缘对齐，去掉 List 自带的行底色。
    func headerRow() -> some View {
        listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
            .listRowSeparator(.hidden)
    }
}

/// 表单字段始终保留名称，输入后不依赖占位文字辨认含义。
struct FormField<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// 详情首屏先呈现状态，具体参数与操作放在后续分组。
struct DetailStatus: View {
    let title: String
    let subtitle: String
    let symbol: String
    var color: Color = .accentColor

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 48, height: 48)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title3.weight(.bold))
                Text(subtitle).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .glassCard()
    }
}
