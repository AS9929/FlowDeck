import AppIntents
import Foundation

/// 快捷指令和 Siri 用的操作。手机需要连着 U60 的 Wi-Fi；连不上时直接报错，不会假装成功。
@MainActor
private enum IntentContext {
    static func verifiedSession(_ capability: ManagementCapability = .mihomo) async throws -> DeviceSession {
        let devices = DeviceStore()
        let session = devices.session()
        if capability == .mihomo { try devices.requireAccess(.mihomo) }
        _ = try await ManagementStore().verifiedAPI(devices, capability: capability)
        try session.validate(in: devices)
        return session
    }

    static func clients(_ requirement: DeviceAccessRequirement = .mihomo) throws -> (mihomo: any MihomoAPI, web: any WebSSHAPI, demo: Bool) {
        let d = DeviceStore()
        try d.requireAccess(requirement)
        return (d.client, d.webClient, d.demoMode)
    }
}

enum OutboundModeOption: String, AppEnum {
    case rule, global, direct

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "出站模式"
    static let caseDisplayRepresentations: [OutboundModeOption: DisplayRepresentation] = [
        .rule: "规则判定", .global: "全局代理", .direct: "直接连接",
    ]

    var mode: OutboundMode { OutboundMode(rawValue: rawValue) ?? .rule }
}

struct GetU60StatusIntent: AppIntent {
    static let title: LocalizedStringResource = "查看 设备总览"
    static let description = IntentDescription("读出常用策略选中节点、延迟、电量和今日蜂窝流量。只读，不改设备。")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let devices = DeviceStore()
        try devices.requireAccess(.mihomo)
        let session = devices.session()
        let mihomo = session.mihomo
        let web = session.management
        let demo = session.demo
        let preferred = PreferredPolicyGroup.saved(deviceID: devices.storageID, defaults: devices.defaults)
        async let proxies = mihomo.proxies()
        async let config = mihomo.config()
        let (list, cfg) = try await (proxies, config)
        var parts: [String] = []
        if cfg.mode == .direct {
            parts.append("现在是直连模式")
        } else if let group = PreferredPolicyGroup.resolve(in: list, mode: cfg.mode, preferred: preferred),
            let node = PolicyStore.resolve(group, in: list), !node.isBuiltin
        {

            let d = node.lastDelay.map { $0 == 0 ? "，上次测速超时" : "，延迟 \($0) 毫秒" } ?? ""
            parts.append("常用策略选中 \(PolicyStore.shortName(node.name))\(d)")
        }
        if let snap = try? await web.snapshot() {
            if let b = snap.battery { parts.append("电量 \(b)%") }
            if let rx = snap.dayRx {
                parts.append("今日蜂窝 \(ByteCountFormatter.string(fromByteCount: rx + (snap.dayTx ?? 0), countStyle: .binary))")
            }
        }
        let text = (demo ? "（演示数据）" : "") + parts.joined(separator: "，")
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

struct SwitchPolicyIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let title: LocalizedStringResource = "切换代理策略组"
    static let description = IntentDescription("把某个策略组切到指定地区或节点，例如把 Claude 切到日本。已有连接保持原线路。")

    @Parameter(title: "策略组", description: "留空使用 App 中的常用策略组", default: "")
    var group: String

    @Parameter(title: "切换到", description: "地区、子策略组或节点名，支持只写节点名的一部分")
    var option: String

    static var parameterSummary: some ParameterSummary {
        Summary("把 \(\.$group) 切到 \(\.$option)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let lease = try DeviceOperationGate.begin("快捷指令操作")
        defer { DeviceOperationGate.end(lease) }
        let session = try await IntentContext.verifiedSession()
        let api = session.mihomo
        let list = try await api.proxies()
        let storageID = session.demo ? "demo" : session.profile?.fingerprint ?? session.profile?.id.uuidString ?? "unpaired"
        let group =
            group.isEmpty
            ? PreferredPolicyGroup.resolve(in: list, mode: .rule, preferred: PreferredPolicyGroup.saved(deviceID: storageID)) ?? ""
            : group
        guard let g = list[group], g.isSelectable, let members = g.all else {
            throw MihomoError.notSelectable(group)
        }
        let q = option.trimmingCharacters(in: .whitespaces).lowercased()
        guard
            let target = members.first(where: { $0.lowercased() == q })
                ?? members.first(where: { PolicyStore.shortName($0).lowercased() == q })
                ?? members.first(where: { $0.lowercased().contains(q) })
        else {
            return .result(dialog: "\(group) 里没有找到“\(option)”")
        }
        try await api.select(group: group, proxy: target)
        let now = try await api.proxies()[group]?.now
        return .result(dialog: now == target ? "\(group) 已切到 \(PolicyStore.shortName(target))" : "已发送切换，但回读结果是 \(now ?? "未知")")
    }
}

struct SetOutboundModeIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let title: LocalizedStringResource = "设置出站模式"
    static let description = IntentDescription("切换规则、全局或直连。只在本次运行有效，代理重启后恢复为配置里的模式。")

    @Parameter(title: "模式")
    var mode: OutboundModeOption

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // 先确认再占用写入租约，用户迟迟不回应确认时不会挡住 App 内的其他写操作。
        if mode == .direct {
            if #available(iOS 18.0, *) {
                try await requestConfirmation(actionName: .continue, dialog: "直接连接将绕过代理，确认切换？")
            } else {
                try await requestConfirmation(result: .result(dialog: "直接连接将绕过代理，确认切换？"))
            }
        }
        let lease = try DeviceOperationGate.begin("快捷指令操作")
        defer { DeviceOperationGate.end(lease) }
        let session = try await IntentContext.verifiedSession()
        let api = session.mihomo
        try await api.setMode(mode.mode)
        let now = try await api.config().mode
        return .result(dialog: now == mode.mode ? "已切换为\(mode.mode.title)" : "已发送切换，但回读结果是\(now.title)")
    }
}

struct SetProxyServiceIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let title: LocalizedStringResource = "开关代理服务"
    static let description = IntentDescription("启动或停用设备上的代理服务。停用前会先请你确认。")

    @Parameter(title: "开启", default: true)
    var enabled: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("代理开启：\(\.$enabled)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // 先确认再占用写入租约，用户迟迟不回应确认时不会挡住 App 内的其他写操作。
        if !enabled {
            let prompt: IntentDialog = "停用后所有连接路由器的设备会直接走蜂窝，确定停用吗？"
            if #available(iOS 18.0, *) {
                try await requestConfirmation(actionName: .turnOff, dialog: prompt)
            } else {
                try await requestConfirmation(result: .result(dialog: prompt))
            }
        }
        let lease = try DeviceOperationGate.begin("快捷指令操作")
        defer { DeviceOperationGate.end(lease) }
        let session = try await IntentContext.verifiedSession(.proxyService)
        let web = session.management
        _ = try await web.control(enabled ? .start : .stop)
        let running = try await web.mihomoStatus().running
        return .result(dialog: running == enabled ? (enabled ? "代理已启动" : "代理已停用") : "命令已执行，但回读状态与预期不符")
    }
}

struct U60Shortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: DiagnoseU60Intent(), phrases: ["用 \(.applicationName) 检查网络"], shortTitle: "网络诊断", systemImageName: "stethoscope")
        AppShortcut(
            intent: GetU60StatusIntent(), phrases: ["\(.applicationName) 现在走哪", "查看 \(.applicationName) 状态"],
            shortTitle: "查看状态", systemImageName: "gauge.with.dots.needle.33percent")
        AppShortcut(
            intent: SetOutboundModeIntent(), phrases: ["把 \(.applicationName) 切到\(\.$mode)"],
            shortTitle: "出站模式", systemImageName: "arrow.triangle.branch")
        AppShortcut(
            intent: SwitchPolicyIntent(), phrases: ["用 \(.applicationName) 切换节点"],
            shortTitle: "切换节点", systemImageName: "point.3.connected.trianglepath.dotted")
        AppShortcut(
            intent: SetProxyServiceIntent(), phrases: ["用 \(.applicationName) 开关代理"],
            shortTitle: "开关代理", systemImageName: "power")
    }
}

/// 返回固定检测结果，便于用户自行组合快捷指令自动化；不向其他应用发送消息。
struct DiagnoseU60Intent: AppIntent {
    static let title: LocalizedStringResource = "运行网络诊断"
    static let description = IntentDescription("检查管理、蜂窝、代理和 DNS，并返回各项结果。")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let manager = ManagementStore()
        let devices = DeviceStore()
        try devices.requireAccess(.device)
        await manager.diagnose(devices)
        guard let report = manager.report else { throw ManagementError.unconfirmed("诊断未完成。") }
        let text = report.checks.map { "\($0.title)：\($0.outcome == .passed ? "通过" : $0.outcome == .failed ? "失败" : "未确认")" }.joined(separator: "；")
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}
