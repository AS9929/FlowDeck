import OSLog
import Observation
import UIKit

/// 随包提供的图标集合；系统名称与构建配置一致，默认图标使用 nil 恢复。
enum AppIconOption: String, CaseIterable, Identifiable {
    case aurora
    case graphite
    case porcelain

    var id: String { rawValue }

    var systemName: String? {
        switch self {
        case .aurora: nil
        case .graphite: "GraphiteIcon"
        case .porcelain: "PorcelainIcon"
        }
    }

    var previewName: String {
        switch self {
        case .aurora: "BrandMark"
        case .graphite: "GraphiteIconPreview"
        case .porcelain: "PorcelainIconPreview"
        }
    }

    var title: String {
        switch self {
        case .aurora: "极光"
        case .graphite: "石墨"
        case .porcelain: "白瓷"
        }
    }
}

/// 将 UIKit 副作用隔离，以便验证失败、重入和实际系统状态，不在测试中更改桌面图标。
@MainActor
protocol AppIconApplying {
    var supportsAlternateIcons: Bool { get }
    var alternateIconName: String? { get }
    /// 完成回调必须在主 actor 执行；离开选择页面不取消系统已经接受的操作。
    func apply(_ name: String?, completion: @escaping @MainActor @Sendable (Error?) -> Void)
}

@MainActor
private struct SystemAppIcon: AppIconApplying {
    var supportsAlternateIcons: Bool { UIApplication.shared.supportsAlternateIcons }
    var alternateIconName: String? { UIApplication.shared.alternateIconName }

    func apply(_ name: String?, completion: @escaping @MainActor @Sendable (Error?) -> Void) {
        UIApplication.shared.setAlternateIconName(name) { error in
            if let error = error as NSError? {
                // 仅记录系统错误域和代码，避免把不可控的系统说明直接展示给用户。
                Logger(subsystem: Bundle.main.bundleIdentifier ?? "FlowDeck", category: "AppIcon")
                    .error("Icon request failed: \(error.domain, privacy: .public) / \(error.code)")
            }
            Task { @MainActor in completion(error) }
        }
    }
}

/// 应用级串行切换状态。以系统完成结果和名称读取为准，不把用户点击当作切换成功。
@MainActor
@Observable
final class AppIconController {
    static let shared = AppIconController(runtime: SystemAppIcon())

    private let runtime: any AppIconApplying
    private var lastRequested: AppIconOption?
    /// 成功回调可能先于名称读取更新；只屏蔽这次操作之前的旧值，不持久化第二份图标偏好。
    private var awaitingReadback: (previous: String?, confirmed: AppIconOption)?
    private(set) var currentName: String?
    private(set) var pending: AppIconOption?
    private(set) var failed = false
    private(set) var isSupported = false

    var current: AppIconOption? {
        AppIconOption.allCases.first { $0.systemName == currentName }
    }

    init(runtime: any AppIconApplying) {
        self.runtime = runtime
        refresh()
    }

    /// 页面进入和回到前台时重新读取，避免依赖上次请求或未知图标名称猜测选中项。
    func refresh() {
        isSupported = runtime.supportsAlternateIcons
        if pending == nil {
            let reportedName = runtime.alternateIconName
            if let awaitingReadback {
                if reportedName == awaitingReadback.previous {
                    currentName = awaitingReadback.confirmed.systemName
                    return
                }
                self.awaitingReadback = nil
            }
            currentName = reportedName
            if let lastRequested, currentName == lastRequested.systemName {
                failed = false
            }
        }
    }

    func select(_ icon: AppIconOption) {
        guard pending == nil else { return }
        refresh()
        failed = false
        guard isSupported, currentName != icon.systemName else { return }
        pending = icon
        lastRequested = icon
        let previousReportedName = runtime.alternateIconName
        runtime.apply(icon.systemName) { [weak self] error in
            guard let self else { return }
            let reportedName = runtime.alternateIconName
            if error == nil {
                // UIKit 的成功回调已确认切换完成，不能再用尚未更新的读取值回滚选中项。
                currentName = icon.systemName
                awaitingReadback =
                    reportedName == icon.systemName
                    ? nil : (previousReportedName, icon)
                failed = false
            } else {
                // 某些系统提示失败时图标已经生效，仍以读回的实际图标补充确认。
                if reportedName != previousReportedName || awaitingReadback == nil {
                    awaitingReadback = nil
                    currentName = reportedName
                }
                failed = currentName != icon.systemName
            }
            pending = nil
        }
    }
}
