import Foundation

/// 固定的只读诊断探测与结果解释，区分故障、缺少能力及返回格式异常。
enum NetworkDiagnostics {
    /// 只设置系统时钟，不修改时区、RTC 或 NTP；目标时间必须在设备可表示的范围内。
    static func clockSyncScript(date: Date) throws -> String {
        let timestamp = date.timeIntervalSince1970
        guard timestamp.isFinite, (946_684_800...4_102_444_800).contains(timestamp) else {
            throw ManagementError.invalid("手机时间超出支持范围，请先检查手机的日期与时间。")
        }
        return "date -u -s '@\(Int(timestamp))' >/dev/null && date +%s"
    }

    /// 写入只发送一次；应答丢失时不自动重试，避免再次回拨时钟。
    static func synchronizeClock(api: any WebSSHAPI) async throws -> DiagnosticCheck {
        let target = Date()
        _ = try await api.runMaintenanceScript(clockSyncScript(date: target))
        let started = Date()
        let output = try await api.runMaintenanceScript("date +%s")
        let check = clockResult(output, started: started, finished: Date())
        guard check.outcome == .passed else {
            throw ManagementError.unconfirmed("校时请求已发送，但回读未确认同步成功。\(check.detail)")
        }
        return check
    }

    static func dnsProbe(host: String) -> String {
        // dnsmasq 可能只绑定 LAN 地址，不能假定 127.0.0.1:53 可用。
        let server = ShellValue.quote(host)
        return """
            if ! command -v nslookup >/dev/null 2>&1; then
                printf 'UNAVAILABLE'
            elif nslookup www.apple.com \(server) >/dev/null 2>&1; then
                printf 'PASSED'
            else
                printf 'FAILED'
            fi
            """
    }

    static func dnsResult(_ output: String) -> DiagnosticCheck {
        let outcome: DiagnosticCheck.Outcome
        let detail: String
        switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "PASSED":
            outcome = .passed
            detail = "设备 LAN DNS 已解析 www.apple.com"
        case "FAILED":
            outcome = .failed
            detail = "设备 LAN DNS 查询未成功，请检查 DNS 服务和上游解析。"
        default:
            outcome = .unavailable
            detail = "未能读取 DNS 检测结果，不代表解析服务故障。"
        }
        return DiagnosticCheck(id: "dns", title: "局域网 DNS", outcome: outcome, detail: detail)
    }

    /// 使用请求前后的中点估算偏差；Unix 时间不再叠加手机或设备时区。
    static func clockResult(_ output: String, started: Date, finished: Date) -> DiagnosticCheck {
        guard let timestamp = Double(output.trimmingCharacters(in: .whitespacesAndNewlines)),
            timestamp.isFinite, (946_684_800...4_102_444_800).contains(timestamp)
        else {
            return DiagnosticCheck(id: "clock", title: "设备时间", outcome: .unavailable, detail: "未读取到有效的 Unix 时间，无法判断是否需要校时。")
        }
        let duration = max(0, finished.timeIntervalSince(started))
        let midpoint = started.timeIntervalSince1970 + duration / 2
        let offset = timestamp - midpoint
        if abs(offset) < 60 + duration / 2 {
            return DiagnosticCheck(id: "clock", title: "设备时间", outcome: .passed, detail: "设备与手机时间误差小于一分钟")
        }
        let seconds = Int(abs(offset).rounded())
        let magnitude: String
        if seconds >= 3600 {
            magnitude = "\(seconds / 3600) 小时 \(seconds % 3600 / 60) 分钟"
        } else {
            magnitude = "\(max(1, seconds / 60)) 分钟"
        }
        return DiagnosticCheck(
            id: "clock", title: "设备时间", outcome: .failed,
            detail: "设备时间比手机\(offset > 0 ? "快" : "慢")约 \(magnitude)。请检查设备校时与时区；App 不会自动修改。"
        )
    }
}
