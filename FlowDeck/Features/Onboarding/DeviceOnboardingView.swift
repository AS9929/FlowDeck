import SwiftUI

/// 仅连接已部署的管理服务。入口随已实现后端扩展，不承担原厂安装流程。
struct DeviceOnboardingView: View {
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        DetailSheet(title: "接入设备") {
            DeviceDetailSummary(
                symbol: "link", title: "连接已部署的设备",
                subtitle: "先连接设备的 Wi-Fi，再选择已安装的管理服务。")

            ForEach(ManagementBackend.allCases) { backend in
                GlassSection {
                    NavigationLink {
                        PairingView(isNew: true, backend: backend).appDetailDestination()
                    } label: {
                        entry(backend)
                    }
                    .accessibilityIdentifier("onboarding.\(backend.rawValue)")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("尚未安装管理服务？", systemImage: "laptopcomputer")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("请先在电脑上完成适配设备的安装与部署，再回到这里接入。App 用于日常管理，接入时保留设备现有配置。")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)
        }
    }

    private func entry(_ backend: ManagementBackend) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
        return layout {
            FeatureIcon(symbol: backend.symbol)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(backend.connectionTitle)
                        .font(.headline).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                Text(backend.connectionDescription)
                    .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
