import SwiftUI

/// 读取任务随页面可见性、选中 Tab、前后台和设备修订一起取消/重建。
/// 不承载需要离开页面后继续执行的写入与恢复任务。
struct DeviceReadScope: Equatable {
    let revision: Int
    let active: Bool
}

private struct VisibleDeviceTask: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppRouter.self) private var router
    @Environment(DeviceStore.self) private var devices
    @State private var visible = false
    let tab: Int
    let enabled: Bool
    let action: @MainActor () async -> Void

    func body(content: Content) -> some View {
        content
            .onAppear { visible = true }
            .onDisappear { visible = false }
            .task(
                id: DeviceReadScope(
                    revision: devices.clientRevision,
                    active: visible && scenePhase == .active && router.tab == tab && enabled
                )
            ) {
                guard visible, scenePhase == .active, router.tab == tab, enabled else { return }
                await action()
            }
    }
}

extension View {
    func visibleDeviceTask(tab: Int, enabled: Bool, action: @escaping @MainActor () async -> Void) -> some View {
        modifier(VisibleDeviceTask(tab: tab, enabled: enabled, action: action))
    }
}
