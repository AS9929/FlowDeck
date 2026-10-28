import Foundation

/// 在一次读取或写入中固定设备和客户端；await 前后复核修订，禁止跨设备保存响应或凭据。
/// 由页面短期持有。写入仍须在 ManagementStore.run 的操作租约中验证，不能借此绕过只读保护。
@MainActor
struct DeviceServiceContext {
    let session: DeviceSession
    private let devices: DeviceStore

    init(_ devices: DeviceStore, revision: Int) throws {
        guard revision == devices.clientRevision else { throw ManagementError.deviceChanged }
        self.devices = devices
        session = devices.session()
    }

    func validate() throws {
        try session.validate(in: devices)
    }

    /// 用能力协议解析同一客户端；不因接口缺失改用另一后端。
    func service<Service>(_ type: Service.Type) throws -> Service {
        try validate()
        guard let service = session.management as? Service else {
            throw ManagementError.unsupported("当前管理通道未提供此功能。")
        }
        return service
    }

    /// 认证结果与本机持久化分开。目标已变化仍抛错；保存失败仅返回警告，保留已读取的数据。
    func rememberFactoryPasswordWarning(_ password: String) throws -> String? {
        try validate()
        do {
            try rememberFactoryPassword(password)
            return nil
        } catch {
            return "设备认证已通过，但密码未保存在本机。" + error.localizedDescription
        }
    }

    /// 仅在成功认证或原厂读取后调用；保留密钥串报错，不把失败当成保存成功。
    func rememberFactoryPassword(_ password: String) throws {
        try validate()
        try devices.saveFactoryPasswordChecked(password, session: session)
    }
}
