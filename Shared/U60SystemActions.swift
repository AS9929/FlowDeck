import ActivityKit
import AppIntents
import Foundation

/// 系统入口只传递动作，不把凭据放进小组件进程或共享偏好；需要写入时交给前台 App 确认。
enum U60QuickAction: String, AppEnum {
    case refresh, policy, service, diagnostics
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "U60 操作"
    static let caseDisplayRepresentations: [U60QuickAction: DisplayRepresentation] = [
        .refresh: "刷新状态", .policy: "切换节点", .service: "代理开关", .diagnostics: "网络诊断",
    ]
}

struct U60QuickActionIntent: AppIntent {
    static let title: LocalizedStringResource = "管理 U60"
    static let openAppWhenRun = true
    @Parameter(title: "操作") var action: U60QuickAction

    init() {
        action = .refresh
    }
    init(action: U60QuickAction) {
        self.action = action
    }

    func perform() async throws -> some IntentResult {
        let defaults = UserDefaults(suiteName: AppIdentity.appGroup)
        defaults?.set(action.rawValue, forKey: "pending.action")
        defaults?.set(Date().timeIntervalSince1970, forKey: "pending.date")
        return .result()
    }
}

/// 不包含设备标识或密码；锁屏上只展示当前恢复阶段。后台暂停后 staleDate 会提示数据过期。
struct U60RecoveryAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var stage: String
        var progress: Double
    }
    var name: String
}

/// 直接操作在 App 进程执行，凭据仍留在 App 钥匙串；控件扩展只持有动作枚举。
enum U60DirectAction: String, AppEnum {
    case refresh, nextNode, toggleProxy, cycleMode
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "U60 快捷操作"
    static let caseDisplayRepresentations: [U60DirectAction: DisplayRepresentation] = [
        .refresh: "刷新状态", .nextNode: "下一个可用节点", .toggleProxy: "开关代理", .cycleMode: "切换出站模式",
    ]
}

struct U60DirectActionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "U60 快捷操作"
    static let openAppWhenRun = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "操作") var action: U60DirectAction

    init() {
        action = .refresh
    }
    init(action: U60DirectAction) {
        self.action = action
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if FLOWDECK_APP
            if action == .toggleProxy || action == .cycleMode {
                if #available(iOS 18.0, *) {
                    try await requestConfirmation(actionName: .continue, dialog: "此操作会改变设备上所有客户端的代理路径，确认继续？")
                } else {
                    try await requestConfirmation(result: .result(dialog: "此操作会改变设备上所有客户端的代理路径，确认继续？"))
                }
            }
            try await SystemActionRunner.perform(action)
        #else
            // LiveActivityIntent 由系统转交 App；扩展不接受代替 App 执行的降级路径。
            try Self.rejectExtensionExecution()
        #endif
        return .result()
    }
    private static func rejectExtensionExecution() throws {
        throw NSError(domain: "U60", code: 1, userInfo: [NSLocalizedDescriptionKey: "请打开 U60 App 后重试。"])
    }

}
