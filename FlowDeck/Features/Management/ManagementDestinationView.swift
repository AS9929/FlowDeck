import SwiftUI

/// 按已声明能力路由到具体页面，未满足接入条件时呈现统一引导。
struct ManagementDestinationView: View {
    @Environment(DeviceStore.self) private var devices
    let destination: ManagementDestination
    var body: some View {
        if let requirement = destination.accessRequirement {
            DeviceAccessGate(requirement: requirement, title: "设备连接") {
                if let feature = destination.feature, case .unavailable(let reason) = devices.availability(of: feature) {
                    DetailSheet(title: "功能兼容性") {
                        DeviceDetailSummary(symbol: "info.circle", title: "此能力暂不可用", subtitle: reason)
                    }
                } else {
                    destinationContent
                }
            }
        } else {
            destinationContent
        }
    }

    @ViewBuilder private var destinationContent: some View {
        switch destination {
        case .runtime: RuntimeSettingsView()
        case .providers: ProviderLibraryView()
        case .logs: ProxyLogsView()
        case .dns: ProxyDNSView()
        case .rules: RulesView()
        case .strategyVisibility: HiddenGroupsView()
        case .settings: AppSettingsView()
        case .ruleData: RuleDataView()
        case .devices: DeviceLibraryView()
        case .diagnostics: DiagnosticsView()
        case .pairing: PairingView()
        case .backup: FactoryBackupView()
        case .recovery:
            if devices.usesUFI { UFIDetailView(section: .maintenance) } else { RecoveryView() }
        case .updates:
            if devices.usesUFI { UFICoreUpdatesView() } else { CoreUpdatesView() }
        case .history: ConfigurationHistoryView()
        case .advanced: AdvancedDeviceView()
        case .system: SystemEntrancesView()
        case .service: ServiceControlView()
        case .wifi:
            if devices.usesUFI { UFIWifiView() } else { WifiEditorView() }
        case .clients:
            if devices.usesUFI { UFIDetailView(section: .clients) } else { ClientsView() }
        case .sms:
            if devices.usesUFI { UFIDetailView(section: .messages) } else { SMSView() }
        case .factory: FactoryResetView()
        case .webSSH: WebSSHManagementView()
        }
    }
}
