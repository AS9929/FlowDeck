import SwiftUI

/// 长列表采用离线模板字形和轻量光泽底座。玻璃由外层卡片承担，避免嵌套材质合成。
struct GroupIcon: View {
    let name: String
    var iconURL: String?
    var size: CGFloat = 32
    var groupType: String?

    var body: some View {
        PolicyIconBadge(spec: PolicyIconCatalog.resolve(name: name, iconURL: iconURL, groupType: groupType), size: size)
            .accessibilityHidden(true)
    }
}

/// 服务字形统一青色；国家保留彩色国旗，以共享尺寸和底座保持视觉一致。
struct PolicyIconBadge: View {
    let spec: PolicyIconSpec
    var size: CGFloat = 36
    @Environment(\.colorScheme) private var colorScheme

    private var tint: Color { .accentColor }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(tint.opacity(colorScheme == .dark ? 0.1 : 0.07))
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [tint.opacity(0.28), Color.primary.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1)
            glyph
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spec.title)
    }

    @ViewBuilder
    private var glyph: some View {
        if spec.regionCode != nil {
            if let asset = spec.flagAssetName, UIImage(named: asset) != nil {
                // 旗面保留完整比例；两侧各留 18% 空间，与服务字形的视觉重量接近。
                Image(asset).renderingMode(.original).resizable().scaledToFit()
                    .frame(width: size * 0.64, height: size * 0.48)
            } else {
                Image(systemName: "globe").font(.system(size: size * 0.51, weight: .medium))
            }
        } else if let asset = spec.asset {
            Image(asset).renderingMode(.template).resizable().scaledToFit()
                .frame(width: size * 0.55, height: size * 0.55)
        } else {
            Image(systemName: spec.symbol ?? "square.stack.3d.up")
                .font(.system(size: size * 0.51, weight: .medium))
        }
    }
}
