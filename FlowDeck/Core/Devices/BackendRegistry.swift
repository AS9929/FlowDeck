import Foundation

/// 管理后端只负责通信构造；型号、固件兼容性单独声明，不下放到页面。
struct BackendDescriptor: Sendable {
    let id: ManagementBackend
    let presentation: BackendPresentation
    let supportedModels: Set<String>
    let features: Set<DeviceFeature>
    let makeClient: @Sendable (DeviceProfile, String, String) -> (any WebSSHAPI)?
    let verifyWrite: @Sendable (any WebSSHAPI, DeviceSnapshot, ManagementCapability) async throws -> Void

    func accepts(_ snapshot: DeviceSnapshot) -> Bool {
        snapshot.model.map(supportedModels.contains) ?? false
    }
}

enum BackendPresentation: Sendable {
    case webSSH, ufi
}

/// 新适配器必须显式注册，未知 ID 永远不落入 WebSSH 默认分支。
enum BackendRegistry {
    static let descriptors: [BackendDescriptor] = [
        BackendDescriptor(
            id: .webSSH, presentation: .webSSH, supportedModels: [DeviceCompatibility.u60Model],
            features: [
                .status, .mihomo, .proxyService, .configuration, .wifi, .messages, .clients,
                .diagnostics, .coreUpdates, .recovery, .ruleData, .factoryArchive,
                .factoryReset, .webTerminal, .advanced,
            ],
            makeClient: { profile, password, _ in
                guard let url = profile.webURL else { return nil }
                return WebSSHClient(baseURL: url, username: profile.webUser, password: password)
            },
            verifyWrite: { _, snapshot, _ in
                guard DeviceCompatibility.supportsWebSSHWrite(snapshot) else {
                    throw ManagementError.unsupported("此写入流程仅适配 MU5250 B28，当前固件不匹配。")
                }
            }),
        BackendDescriptor(
            id: .ufiTools, presentation: .ufi, supportedModels: [DeviceCompatibility.f50Model],
            features: [
                .status, .mihomo, .proxyService, .configuration, .wifi, .messages, .clients,
                .diagnostics, .coreUpdates, .recovery, .ufiFactory,
            ],
            makeClient: { profile, password, secret in
                guard let url = profile.webURL else { return nil }
                let proxy = profile.mihomoURL.map { MihomoClient(baseURL: $0, secret: secret) }
                return UFIClient(
                    baseURL: url, password: password,
                    expectedFingerprint: profile.fingerprint, mihomo: proxy)
            },
            verifyWrite: { api, snapshot, capability in
                guard snapshot.model == DeviceCompatibility.f50Model, capability != .system else {
                    throw ManagementError.unsupported("此通用系统操作未适配当前设备。")
                }
                guard let adapter = api as? any AdapterVerification else {
                    throw ManagementError.unsupported("管理通道未提供写入兼容性验证。")
                }
                if capability == .proxyService { try await adapter.verifyServiceAdapter() }
                if [.wifi, .factoryControl, .clock].contains(capability) {
                    try await adapter.verifyWifiFirmware()
                }
            }),
    ]

    static var supportedIDs: [ManagementBackend] { descriptors.map(\.id) }
    static func descriptor(for id: ManagementBackend, in registered: [BackendDescriptor] = descriptors) -> BackendDescriptor? {
        registered.first { $0.id == id }
    }
}

/// 适配器负责安装布局和原厂固件的最终写入检查，能力展示不能替代这项验证。
protocol AdapterVerification: Sendable {
    func verifyServiceAdapter() async throws
    func verifyWifiFirmware() async throws
}

extension UFIClient: AdapterVerification {}
