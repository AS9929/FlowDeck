import Foundation

/// 页面声明所需功能，适配器声明实现范围；不支持的功能不能靠 else 进入其他后端。
enum DeviceFeature: CaseIterable, Sendable {
    case status, mihomo, proxyService, configuration, wifi, messages, clients, diagnostics
    case coreUpdates, recovery, ruleData, factoryArchive, factoryReset, webTerminal, advanced, ufiFactory
}

enum DeviceFeatureAvailability: Equatable {
    case available
    case unavailable(String)
}

extension DeviceStore {
    func availability(of feature: DeviceFeature) -> DeviceFeatureAvailability {
        if demoMode { return .available }
        guard let profile = current else { return .unavailable("请先接入设备。") }
        guard let descriptor = BackendRegistry.descriptor(for: profile.backend),
            descriptor.features.contains(feature)
        else {
            return .unavailable("当前管理方式尚未提供此能力；已保留其他可用功能。")
        }
        guard profile.model.map(descriptor.supportedModels.contains) == true else {
            return .unavailable("此型号尚未完成适配，请先验证设备身份。")
        }
        return .available
    }
}
