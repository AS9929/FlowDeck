import SwiftUI

/// 页面尺寸和辅助功能回退色；材质与极光背景参考余量的设计系统。
enum AppTheme {
    /// 仅 Debug 的布局验收参数，模拟显示缩放后的逻辑宽度；发布构建不生效。
    static var auditWidth: CGFloat? {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--layout-width-320") {
                return 320
            }
        #endif
        return nil
    }

    static let pageInset: CGFloat = 20
    static let cardRadius: CGFloat = 28
    static let background = adaptive(
        light: UIColor(red: 0.94, green: 0.96, blue: 0.99, alpha: 1),
        dark: UIColor(red: 0.035, green: 0.055, blue: 0.105, alpha: 1)
    )
    static let card = adaptive(
        light: .white,
        dark: UIColor(red: 0.085, green: 0.11, blue: 0.15, alpha: 1)
    )

    static let aqua = Color(red: 0.22, green: 0.79, blue: 0.85)
    static let violet = Color(red: 0.52, green: 0.42, blue: 0.92)

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

/// 字重按内容职责区分；保留语义字号，继续响应 Dynamic Type 与系统粗体设置。
/// 正文、日志和配置编辑器不继承标题字重，以保持长文本的阅读密度。
enum AppTypography {
    static let sectionTitle = Font.subheadline.weight(.bold)
    static let rowTitle = Font.body.weight(.semibold)
    static let detailTitle = Font.headline.weight(.bold)
    static let compactTitle = Font.subheadline.weight(.semibold)
}

/// 自定义动效只作用于交互反馈；长列表和批量布局变更不使用弹簧。
enum AppMotion {
    static func feedback(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.16)
    }

    /// 工作区只淡化内容，不推动整页卡片；持续时间短于页面导航。
    static func workspace(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.24)
    }

    static func disclosure(reduceMotion: Bool) -> Animation? {
        // 给长预览足够的连续展开时间；采用固定时长曲线，避免弹簧很快走完主要位移。
        reduceMotion ? nil : .timingCurve(0.25, 0.1, 0.25, 1, duration: 0.5)
    }
}

extension View {
    /// 浮层和按钮使用原生玻璃；系统要求降低透明度时使用不透明背景。
    func glassSurface<S: Shape>(in shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(InteractiveSurface(shape: shape, interactive: interactive, tint: tint))
    }

    /// 内容卡片使用与余量一致的轻染色玻璃。包含按钮的整张卡片默认不做按压形变。
    func glassCard(
        cornerRadius: CGFloat = AppTheme.cardRadius,
        tint: Color = .accentColor,
        interactive: Bool = false
    ) -> some View {
        // 内容不参与玻璃合成，避免滚动复用时材质存在而文字层丢失。
        background {
            Color.clear.glassSurface(
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                interactive: interactive,
                tint: tint.opacity(0.035)
            )
        }
    }
}

/// 统一玻璃表面：布局完成后添加系统材质，再叠加轻量高光和阴影。
private struct InteractiveSurface<SurfaceShape: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    let shape: SurfaceShape
    let interactive: Bool
    let tint: Color?

    func body(content: Content) -> some View {
        surface(content)
            .overlay {
                shape.stroke(
                    LinearGradient(
                        colors: contrast == .increased
                            ? [Color.primary.opacity(0.5)]
                            : [
                                .white.opacity(scheme == .dark ? 0.16 : 0.60),
                                Color.accentColor.opacity(0.06),
                                .white.opacity(0.05),
                            ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: contrast == .increased ? 1.5 : 0.75
                )
                .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0.10 : 0.025), radius: 12, y: 4)
    }

    @ViewBuilder
    private func surface(_ content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.background(AppTheme.card, in: shape)
        } else if #available(iOS 26.0, *) {
            content.glassEffect(glass, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background(tint ?? .clear, in: shape)
        }
    }

    @available(iOS 26.0, *)
    private var glass: Glass {
        var result: Glass = .regular
        if let tint {
            result = result.tint(tint)
        }
        if interactive {
            result = result.interactive()
        }
        return result
    }
}

/// 同一页面的玻璃面共享合成容器。间距小于卡片间距，避免相邻卡片融合。
struct GlassCluster<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 6) {
                content()
            }
        } else {
            content()
        }
    }
}

/// 与余量相同的静态极光底色，为透明材质提供低饱和环境色。
struct AppBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geometry in
            let dark = scheme == .dark
            ZStack {
                AppTheme.background
                if !reduceTransparency {
                    Ellipse()
                        .fill(AppTheme.aqua.opacity(dark ? 0.13 : 0.12))
                        .frame(width: geometry.size.width * 1.25, height: geometry.size.height * 0.55)
                        .blur(radius: 80)
                        .offset(x: -geometry.size.width * 0.3, y: -geometry.size.height * 0.35)
                    Ellipse()
                        .fill(AppTheme.violet.opacity(dark ? 0.15 : 0.09))
                        .frame(width: geometry.size.width, height: geometry.size.height * 0.65)
                        .blur(radius: 85)
                        .offset(x: geometry.size.width * 0.4, y: geometry.size.height * 0.06)
                    Ellipse()
                        .fill(Color.blue.opacity(dark ? 0.08 : 0.05))
                        .frame(width: geometry.size.width, height: geometry.size.height * 0.4)
                        .blur(radius: 70)
                        .offset(x: -geometry.size.width * 0.15, y: geometry.size.height * 0.46)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 普通表单分组的玻璃替代容器；提示文字留在卡片外，内容仍使用原有状态和操作。
struct GlassSection<Content: View, Header: View, Footer: View>: View {
    @ViewBuilder let content: () -> Content
    @ViewBuilder let header: () -> Header
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header()
                .font(AppTypography.sectionTitle)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 16) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .glassCard()
            .buttonStyle(GlassRowButtonStyle())
            .labelStyle(GlassFeatureLabelStyle())
            .tint(.accentColor)
            .textFieldStyle(GlassInputStyle())
            .labeledContentStyle(DetailValueStyle())
            footer()
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }
}

extension GlassSection where Header == Text, Footer == EmptyView {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(content: content, header: { Text(title) }, footer: { EmptyView() })
    }
}

extension GlassSection where Header == EmptyView, Footer == EmptyView {
    init(@ViewBuilder content: @escaping () -> Content) {
        self.init(content: content, header: { EmptyView() }, footer: { EmptyView() })
    }
}

extension GlassSection where Footer == EmptyView {
    init(@ViewBuilder content: @escaping () -> Content, @ViewBuilder header: @escaping () -> Header) {
        self.init(content: content, header: header, footer: { EmptyView() })
    }
}

extension GlassSection where Header == EmptyView {
    init(@ViewBuilder content: @escaping () -> Content, @ViewBuilder footer: @escaping () -> Footer) {
        self.init(content: content, header: { EmptyView() }, footer: footer)
    }
}

/// 详情表单沿用主页面的材质；滚动内容和关闭操作保持各自的点击区域。
struct GlassSheet<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            // 设置页是有限分组；稳定挂载内容，长数据列表仍由各自的 List 懒加载。
            VStack(alignment: .leading, spacing: 20) {
                content()
            }
            .padding(.horizontal, AppTheme.pageInset)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(AppBackground())
        .scrollDismissesKeyboard(.interactively)
        .presentationDragIndicator(.visible)
    }
}

/// 分组内整行可点；不在已有玻璃内部重复叠加玻璃。
private struct GlassRowButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTypography.rowTitle)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .foregroundStyle(configuration.role == .destructive ? Color.red : Color.primary)
            .tint(configuration.role == .destructive ? Color.red : Color.accentColor)
            .opacity(!isEnabled ? 0.45 : (configuration.isPressed ? 0.65 : 1))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(AppMotion.feedback(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

private struct GlassFeatureLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            configuration.title
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 统一图标底座，供设备信息及功能入口使用。
struct FeatureIcon: View {
    let symbol: String
    var color: Color = .accentColor

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 36, height: 36)
            .background(
                LinearGradient(
                    colors: [color.opacity(0.13), color.opacity(0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(color.opacity(0.14), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

/// 延迟以毫秒显示，并用文字区分未知和超时，避免仅依赖颜色。
struct DelayBadge: View {
    let delay: Int?
    var testing = false

    var body: some View {
        Group {
            if testing {
                ProgressView().controlSize(.mini)
                    .accessibilityLabel("正在测速")
            } else if let delay {
                Text(delay == 0 ? "超时" : "\(delay) ms")
                    .font(.system(.caption2, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Self.color(for: delay))
                    .accessibilityLabel(delay == 0 ? "测速超时" : "延迟 \(delay) 毫秒")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    static func color(for delay: Int) -> Color {
        switch delay {
        case 0: return .secondary
        case ..<90: return .accentColor
        case ..<200: return .orange
        default: return .red
        }
    }
}

extension GlassSection where Header == Text {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content, @ViewBuilder footer: @escaping () -> Footer) {
        self.init(content: content, header: { Text(title) }, footer: footer)
    }
}

/// 输入区使用轻量凹面底色，避免与外层玻璃重复采样；密码框沿用同一尺寸。
private struct GlassInputStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 详情值独占一行可用宽度，显示缩放与长地址不再和标签争抢空间。
/// 短字段保持标签和值两端对齐；长值或大字体改为上下排列，不省略数据。
private struct DetailValueStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                configuration.label.foregroundStyle(.secondary)
                    .fixedSize()
                Spacer(minLength: 0)
                configuration.content.foregroundStyle(.primary)
                    .fontWeight(.semibold)
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                configuration.label.foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                configuration.content
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.subheadline.weight(.medium))
        .frame(minHeight: 30)
    }
}
