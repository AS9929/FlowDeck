import SwiftUI

/// 应用导航目的地标识；保持原始值以兼容深链接与现有路由。
enum ManagementDestination: String, Identifiable {
    case runtime, providers, logs, dns, rules, strategyVisibility, settings, ruleData, devices, diagnostics, pairing, backup, recovery, updates, history,
        advanced, system, service, wifi, clients, sms, factory, webSSH
    var id: String {
        rawValue
    }
}
