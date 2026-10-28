import Foundation

/// 前台操作协调器与能力服务的连接点，核心会话层不依赖页面状态对象。
extension ManagementStore {
    /// 核验与能力解析复用同一会话，调用方不能在核验后重新取得“当前客户端”。
    func verifiedService<Service>(
        _ type: Service.Type, devices: DeviceStore, revision: Int,
        capability: ManagementCapability
    ) async throws -> Service {
        let context = try DeviceServiceContext(devices, revision: revision)
        _ = try await verifiedAPI(devices, capability: capability)
        return try context.service(type)
    }
}
