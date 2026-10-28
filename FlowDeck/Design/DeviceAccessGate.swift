import SwiftUI

/// 不创建受限页面，避免其 task、轮询或按钮在接入前访问设备。
struct DeviceAccessGate<Content: View>: View {
    @Environment(DeviceStore.self) private var devices
    let requirement: DeviceAccessRequirement
    let title: String
    var root = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        if let issue = devices.accessIssue(for: requirement) {
            GlassSheet {
                DeviceAccessNotice(issue: issue)
            }
            .nativeSettingsPage(title: title, inline: true)
            .toolbar {
                if root { DeviceContextToolbar() }
            }
        } else {
            content()
        }
    }
}

/// 功能限制始终附带可完成的下一步；本地偏好和接入引导保持可用。
struct DeviceAccessNotice: View {
    @Environment(DeviceStore.self) private var devices
    let issue: DeviceAccessIssue

    var body: some View {
        GlassSection {
            VStack(alignment: .leading, spacing: 20) {
                FeatureIcon(symbol: issue == .noDevice ? "plus.circle" : "checkmark.shield")
                Text(issue.title).font(.title2.bold())
                Text(issue.message)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                NavigationLink {
                    if issue == .noDevice {
                        DeviceOnboardingView().appDetailDestination()
                    } else {
                        PairingView().appDetailDestination()
                    }
                } label: {
                    Label(
                        issue == .noDevice ? "接入设备" : "连接与凭据",
                        systemImage: issue == .noDevice ? "plus.circle" : "key"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)

            }
        }
    }
}

extension ManagementDestination {
    /// 兼容旧调用；唯一支持清单来自后端注册表。
    var supportsUFI: Bool {
        guard let feature else { return true }
        return BackendRegistry.descriptor(for: .ufiTools)?.features.contains(feature) == true
    }

    var feature: DeviceFeature? {
        switch self {
        case .settings, .devices, .pairing, .system: return nil
        case .runtime, .providers, .logs, .dns, .rules, .strategyVisibility: return .mihomo
        case .diagnostics: return .diagnostics
        case .ruleData: return .ruleData
        case .backup: return .factoryArchive
        case .recovery: return .recovery
        case .updates: return .coreUpdates
        case .history: return .configuration
        case .advanced: return .advanced
        case .service: return .proxyService
        case .wifi: return .wifi
        case .clients: return .clients
        case .sms: return .messages
        case .factory: return .factoryReset
        case .webSSH: return .webTerminal
        }
    }

    /// 顶层目的地统一覆盖普通导航、深链接及系统入口。
    var accessRequirement: DeviceAccessRequirement? {
        switch self {
        case .settings, .devices, .pairing, .system:
            return nil
        case .runtime, .providers, .logs, .dns, .rules, .strategyVisibility:
            return .mihomo
        case .diagnostics:
            return .device
        default:
            return .webSSH
        }
    }
}
