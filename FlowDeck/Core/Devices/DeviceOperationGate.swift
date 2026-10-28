import Foundation
import Observation

/// App 进程内的设备操作互斥。跨页写入与部署、维护共用门闩；读取不占用。
/// 租约由调用方 defer 释放，不能通过切换页面绕过正在执行的操作。
@MainActor
enum DeviceOperationGate {
    @TaskLocal static var owner: UUID?
    private static var nestedLeases: Set<UUID> = []
    @Observable
    final class State {
        var active: UUID?
        var title = ""
    }

    private static let state = State()
    private(set) static var active: UUID? {
        get { state.active }
        set { state.active = newValue }
    }
    private(set) static var title: String {
        get { state.title }
        set { state.title = newValue }
    }

    /// 只有持有当前任务租约的串行流程可提交自己的设备记录。
    static func requireMutationAccess() throws {
        guard active == nil || owner == active else {
            throw ManagementError.invalid("正在\(title)，完成后再更改设备或凭据。")
        }
    }

    static func begin(_ title: String) throws -> UUID {
        // 维护流程会串行调用底层写入；仅同一任务作用域可以借用外层租约。
        // 独立页面任务没有 owner，仍然拒绝；不得在该作用域内并发派生写任务。
        if let active, owner == active {
            let nested = UUID()
            nestedLeases.insert(nested)
            return nested
        }
        guard active == nil else {
            throw ManagementError.invalid("正在\(self.title)，完成后再执行其他操作。")
        }
        let lease = UUID()
        active = lease
        self.title = title
        return lease
    }

    static func end(_ lease: UUID) {
        if nestedLeases.remove(lease) != nil { return }
        guard active == lease else { return }
        active = nil
        title = ""
    }
}
