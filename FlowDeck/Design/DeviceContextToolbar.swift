import SwiftUI

/// 四个主页面共享设备上下文，切换后沿用根视图的客户端重建与状态隔离。
struct DeviceContextToolbar: ToolbarContent {
    @Environment(DeviceStore.self) private var devices
    @Environment(AppRouter.self) private var router
    @Environment(ManagementStore.self) private var manager
    @Environment(DeviceStatusStore.self) private var status

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                router.sheet = .devices
            } label: {
                HStack(spacing: 6) {
                    Image("TabDevice")
                        .resizable().scaledToFit().frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                    Text(devices.demoMode ? "演示设备" : devices.current?.name ?? "选择设备")
                        .lineLimit(1)
                }
                .font(AppTypography.compactTitle)
            }
            .disabled(manager.working || status.busy != nil)
            .accessibilityLabel("切换设备")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                router.sheet = .settings
            } label: {
                Label("App 设置", systemImage: "gearshape")
            }
        }
    }
}

/// 功能归属页面中的整行入口；具体操作沿用统一 Sheet 路由。
struct DestinationRow: View {
    @Environment(AppRouter.self) private var router
    let title: String
    let symbol: String
    var subtitle: String?
    let destination: ManagementDestination

    init(_ title: String, symbol: String, subtitle: String? = nil, destination: ManagementDestination) {
        self.title = title
        self.symbol = symbol
        self.subtitle = subtitle
        self.destination = destination
    }

    var body: some View {
        Button {
            router.sheet = destination
        } label: {
            SettingsRow(title, symbol: symbol, subtitle: subtitle)
        }
    }
}
