import Foundation

/// 已核验原厂通道上的单次写入与回读。互斥和身份核验由调用方持有，失败不自动重发。
enum UFIFactoryOperations {
    static func markRead(
        _ message: SMSMessage, page: Int, password: String, api: any UFIMessagesService
    ) async throws -> SMSMessage {
        try await api.performFactoryAction(.markMessageRead(message.id), password: password)
        let actual = try await api.readMessages(page: page, password: password)
        guard let confirmed = actual.first(where: { $0.id == message.id }), !confirmed.unread else {
            throw ManagementError.unconfirmed("已提交，但未回读到已读状态，请刷新检查。")
        }
        return confirmed
    }
    /// 仅发送一次重启；只对网络断开继续观察，认证或原厂拒绝直接报错。
    @MainActor
    static func reboot(
        api: any UFIDeviceService, password: String, validate: () throws -> Void
    ) async throws {
        guard let uptime = try await api.snapshot().uptime, uptime > 30 else {
            throw ManagementError.unconfirmed("设备刚启动或运行时长未知，请稍后再试。")
        }
        try validate()
        do { try await api.performFactoryAction(.reboot, password: password) } catch {
            // 只有网络断开可以进入恢复观察；认证或原厂明确拒绝应立即显示错误。
            guard error is URLError else { throw error }
        }
        for _ in 0..<20 {
            try await Task.sleep(for: .seconds(3))
            try validate()
            let current = try? await api.snapshot()
            try validate()
            if let now = current?.uptime, now < uptime {
                return
            }
        }
        throw ManagementError.unconfirmed("暂未确认重启完成。请重新连接 F50 热点后刷新检查，不要连续重启。")
    }

}
