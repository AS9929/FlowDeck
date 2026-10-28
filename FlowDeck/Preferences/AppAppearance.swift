import SwiftUI

/// App 专用外观偏好，不影响设备配置或桌面小组件的系统外观。
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "app.appearance"
    var id: String { rawValue }

    /// 未识别的旧值回退至系统外观，避免将迁移或损坏值解释为强制深色。
    static func resolve(_ value: String) -> Self {
        Self(rawValue: value) ?? .system
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    var detail: String {
        switch self {
        case .system: "随设备自动切换深浅色"
        case .light: "明亮背景，清晰呈现"
        case .dark: "深色背景，柔和显示"
        }
    }
}
