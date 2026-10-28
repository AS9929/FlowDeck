import SwiftUI

/// 品牌展示与系统所选图标一致；选择页可显式传入候选，复用相同的比例和圆角。
struct AppBrandIcon: View {
    var size: CGFloat = 80
    var icon: AppIconOption?
    @State private var icons = AppIconController.shared

    var body: some View {
        Image((icon ?? icons.current ?? .aurora).previewName)
            .renderingMode(.original)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.275, style: .continuous))
            .accessibilityHidden(true)
    }
}
