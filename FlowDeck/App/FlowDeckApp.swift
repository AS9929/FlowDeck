import SwiftUI

@main
struct FlowDeckApp: App {
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue
    @State private var devices: DeviceStore
    @State private var policy: PolicyStore
    @State private var status: DeviceStatusStore
    @State private var manager = ManagementStore()
    @State private var router = AppRouter()

    init() {
        var defaults = UserDefaults.standard
        #if DEBUG
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
                || NSClassFromString("XCTestCase") != nil
            {
                // 单元测试宿主不加载模拟器里保存的真实连接。UI 测试另用下方的导航测试域。
                let suite = "com.max.U60Manager.unit-test-host"
                let isolated = UserDefaults(suiteName: suite)!
                isolated.removePersistentDomain(forName: suite)
                isolated.set(true, forKey: "demoMode")
                isolated.set(true, forKey: "demo.explicitSelection.v1")
                defaults = isolated
            }
            if ProcessInfo.processInfo.arguments.contains("--navigation-audit") {
                // 导航测试使用独立偏好域，避免真实配对记录改变测试前置状态。
                // 只清理测试域，不删除普通运行时的设备和钥匙串凭据。
                let suite = "com.max.U60Manager.navigation-audit"
                let isolated = UserDefaults(suiteName: suite)!
                isolated.removePersistentDomain(forName: suite)
                defaults = isolated
            }
        #endif
        let d = DeviceStore(defaults: defaults)
        _devices = State(initialValue: d)
        _policy = State(initialValue: PolicyStore(api: d.client, deviceID: d.storageID, defaults: defaults))
        _status = State(initialValue: DeviceStatusStore(api: d.webClient, deviceID: d.storageID))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // 未指定字体的文字（表单行、按钮标签等）默认用 medium；显式字体不受影响。
                .font(.body.weight(.medium))
                .frame(width: AppTheme.auditWidth)
                .preferredColorScheme(AppAppearance.resolve(appearance).colorScheme)
                .environment(devices)
                .environment(policy)
                .environment(status)
                .environment(manager)
                .environment(router)
        }
    }
}

struct RootView: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(PolicyStore.self) private var policy
    @Environment(DeviceStatusStore.self) private var status
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppRouter.self) private var router
    @Environment(ManagementStore.self) private var manager

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            AppTabNavigationStack(tab: 0) { OverviewView() }
                .tabItem { Label("总览", systemImage: "gauge.with.dots.needle.33percent") }
                .tag(0)
            AppTabNavigationStack(tab: 1) {
                DeviceAccessGate(requirement: .mihomo, title: "Mihomo", root: true) { PolicyListView() }
            }
            .tabItem { Label("Mihomo", image: "TabMihomo") }
            .tag(1)
            AppTabNavigationStack(tab: 2) {
                DeviceAccessGate(requirement: .webSSH, title: "设备", root: true) { DeviceView() }
            }
            .tabItem { Label("设备", image: "TabDevice") }
            .tag(2)
            AppTabNavigationStack(tab: 3) { MaintenanceView() }
                .tabItem { Label("工具", systemImage: "wrench.and.screwdriver") }
                .tag(3)
        }

        .onOpenURL { url in
            router.open(url)
        }
        .onChange(of: router.navigationNotice) {
            if let message = router.navigationNotice {
                policy.notice = message
                router.navigationNotice = nil
            }
        }
        .onChange(of: policy.state) { syncWidget() }
        .onChange(of: status.snapshotAt) {
            syncWidget()
            if status.snapshotError == nil, status.snapshotAt != nil { devices.recordReachable() }
        }
        .onChange(of: status.service) { syncWidget() }
        .onChange(of: status.snapshotError) { syncWidget() }
        .onChange(of: devices.clientRevision) {
            policy.use(devices.client, deviceID: devices.storageID)
            status.use(devices.webClient, deviceID: devices.storageID)
            status.expectedFingerprint = devices.demoMode ? nil : devices.current?.fingerprint
            manager.clearDeviceResults()
            status.historyDeviceID = devices.storageID
            syncWidget()
        }
        .task(id: devices.clientRevision) {
            if policy.state == .idle { policy.use(devices.client, deviceID: devices.storageID) }
            status.historyDeviceID = devices.storageID
            status.expectedFingerprint = devices.demoMode ? nil : devices.current?.fingerprint
            status.authorizeWrite = { _ = try await manager.verifiedAPI(devices, capability: .proxyService) }
            policy.authorizeWrite = {
                try devices.requireAccess(.mihomo)
                _ = try await manager.verifiedAPI(devices, capability: .mihomo)
            }
            syncWidget()
            router.consumeSystemAction()
            if devices.mihomoAvailable { await policy.refresh() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                router.consumeSystemAction()
                Task {
                    // 不在回到前台时自动尝试设备库中的管理密码。
                    if devices.mihomoAvailable { await policy.refresh() }
                    if manager.recoveryPending && !manager.working { router.sheet = .recovery }
                }
            }
        }
        .onChange(of: policy.mode) { syncWidget() }
        .onChange(of: policy.preferredGroup) { syncWidget() }
        .overlay(alignment: .top) { NoticeToast() }
    }
}

extension RootView {
    private func syncWidget() {
        WidgetSync.update(devices: devices, policy: policy, status: status)
    }
}

/// 操作结果提示。计时跟随消息身份，视图离开或新提示到来时取消旧计时。
struct NoticeToast: View {
    @Environment(PolicyStore.self) private var policy
    @Environment(DeviceStatusStore.self) private var status
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Message: Hashable {
        let id: UUID
        let text: String
        let fromPolicy: Bool
    }

    private var message: Message? {
        if let text = policy.notice {
            return Message(id: policy.noticeID, text: text, fromPolicy: true)
        }
        if let text = status.notice {
            return Message(id: status.noticeID, text: text, fromPolicy: false)
        }
        return nil
    }

    var body: some View {
        ZStack {
            if let message {
                Text(message.text)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassSurface(in: Capsule())
                    .padding(.top, 8)
                    .padding(.horizontal, 24)
                    .id(message.id)
                    .transition(.opacity)
                    .onTapGesture { clear(message) }
            }
        }
        .animation(AppMotion.feedback(reduceMotion: reduceMotion), value: message)
        .task(id: message) {
            guard let message else { return }
            UIAccessibility.post(notification: .announcement, argument: message.text)
            do {
                try await Task.sleep(nanoseconds: 2_400_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            clear(message)
        }
    }

    private func clear(_ displayed: Message) {
        guard message == displayed else { return }
        if displayed.fromPolicy {
            policy.notice = nil
        } else {
            status.notice = nil
        }
    }
}
