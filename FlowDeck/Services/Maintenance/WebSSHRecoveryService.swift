import Foundation

/// WebSSH 重启恢复流程。提交一次后保留旧运行时长与设备标识，重连只观察、不重发。
/// 前台 Activity 与进度展示由调用方负责；轮询绑定同一设备会话。
@MainActor
struct WebSSHRecoveryService {
    let context: DeviceServiceContext
    let storageID: String
    let defaults: UserDefaults
    let pending: (Bool) -> Void
    let progress: (String, Double) async -> Void

    func prepare(sendCommand: Bool) async throws {
        try context.validate()
        let api = context.session.management
        if sendCommand {
            let snapshot = try await api.snapshot()
            guard let uptime = snapshot.uptime, uptime > 0 else {
                throw ManagementError.unconfirmed("无法读取运行时长，不能核验重启结果。")
            }
            let service = try await api.mihomoStatus()
            try context.validate()
            defaults.set(uptime, forKey: "recovery.uptime")
            defaults.set(Date().timeIntervalSince1970, forKey: "recovery.started")
            defaults.set(storageID, forKey: "recovery.device")
            defaults.set(service.autostart, forKey: "recovery.proxy")
            defaults.set(true, forKey: "recovery.pending")
            pending(true)
            // 重启可能在 HTTP 应答前断线。保留 pending，只检查恢复，不自动重发。
            do { try await api.reboot() } catch {
                if case WebSSHError.unreachable = error {
                    await progress("重启应答未确认，继续观察设备恢复", 0.1)
                } else {
                    pending(false)
                    defaults.set(false, forKey: "recovery.pending")
                    throw error
                }
            }
        } else {
            guard defaults.string(forKey: "recovery.device") == storageID else {
                throw ManagementError.deviceChanged
            }
        }
    }

    func waitForRecovery() async throws -> Bool {
        let api = context.session.management
        let previousUptime = defaults.integer(forKey: "recovery.uptime")
        let started = defaults.double(forKey: "recovery.started")
        let expectProxy = defaults.bool(forKey: "recovery.proxy")
        await progress("等待设备恢复，重新连上它的 Wi-Fi 后继续检查", 0.2)
        let deadline = Date().addingTimeInterval(context.session.demo ? 5 : 240)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: context.session.demo ? 300_000_000 : 5_000_000_000)
            try context.validate()
            guard let state = try? await api.snapshot(), let uptime = state.uptime else {
                continue
            }
            try context.validate()
            let elapsed = max(0, Date().timeIntervalSince1970 - started)
            guard context.session.demo || Double(uptime) < Double(previousUptime) + elapsed - 2 else {
                continue
            }
            if !context.session.demo, state.identityFingerprint != context.session.profile?.fingerprint {
                throw ManagementError.deviceChanged
            }
            await progress("设备已回来，检查蜂窝与代理", 0.6)
            guard state.connected == true else {
                continue
            }
            if expectProxy {
                guard let service = try? await api.mihomoStatus(), service.running, service.apiReachable,
                    (try? await api.connectivity()) == true
                else {
                    continue
                }
            }
            try context.validate()
            return true
        }
        try context.validate()
        return false
    }
}
