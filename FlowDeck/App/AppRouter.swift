import Observation
import SwiftUI

/// 页面与系统入口共用路由；顶层目的地通过导航栈进入。
@MainActor
@Observable
final class AppRouter {
    var hasUnsavedConfiguration = false
    var navigationNotice: String?
    var tab = 0
    var proxyNavigationID = UUID()

    /// 从总览或系统入口进入策略工作区；普通 Tab 往返保留用户上次的位置。
    func openProxy() {
        guard !hasUnsavedConfiguration else {
            navigationNotice = "配置仍有未应用的草稿，请先返回编辑器处理。"
            return
        }
        sheet = nil
        tab = 1
        proxyNavigationID = UUID()
    }
    var sheet: ManagementDestination?

    /// 系统深链接先关闭原有顶层弹页，避免目标页面被设置页覆盖。
    func open(_ url: URL) {
        guard url.scheme == AppIdentity.urlScheme else { return }
        guard !hasUnsavedConfiguration else {
            navigationNotice = "配置仍有未应用的草稿，已保留当前页面。"
            return
        }
        sheet = nil
        switch url.host {
        case "policy": openProxy()
        case "device": tab = 2
        case "service": sheet = .service
        case "recovery": sheet = .recovery
        default: tab = 0
        }
    }

    func consumeSystemAction() {
        let defaults = UserDefaults(suiteName: AppIdentity.appGroup)
        guard let raw = defaults?.string(forKey: "pending.action"), let action = U60QuickAction(rawValue: raw) else {
            return
        }
        let age = Date().timeIntervalSince1970 - (defaults?.double(forKey: "pending.date") ?? 0)
        defaults?.removeObject(forKey: "pending.action")
        guard age < 60 else {
            return
        }
        guard !hasUnsavedConfiguration else {
            navigationNotice = "配置仍有未应用的草稿，已保留当前页面。"
            return
        }
        switch action {
        case .refresh:
            sheet = nil
            tab = 0
        case .policy: openProxy()
        case .service: sheet = .service
        case .diagnostics: sheet = .diagnostics
        }
    }
}
