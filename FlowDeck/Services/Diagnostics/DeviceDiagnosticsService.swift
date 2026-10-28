import Foundation

/// 一次诊断只读取固定会话，不操作前台状态；每项失败分别形成结果，目标变化整体丢弃。
@MainActor
struct DeviceDiagnosticsService {
    let context: DeviceServiceContext
    let progress: (String, Double) async -> Void

    func run() async throws -> DiagnosticReport {
        let usesUFI = context.session.profile.flatMap { BackendRegistry.descriptor(for: $0.backend) }?.presentation == .ufi
        let api = context.session.management
        let client = context.session.mihomo
        let demo = context.session.demo
        let host = context.session.profile?.host
        var checks: [DiagnosticCheck] = []
        func check(_ id: String, _ title: String, _ outcome: DiagnosticCheck.Outcome, _ detail: String) {
            checks.append(DiagnosticCheck(id: id, title: title, outcome: outcome, detail: detail))
        }
        do {
            let snapshot = try await api.snapshot()
            check("management", "设备管理", .passed, usesUFI ? "UFI-TOOLS 与设备身份读取正常" : "WebSSH 与原厂状态接口响应正常")
            check(
                "cellular", "蜂窝网络", snapshot.connected.map { $0 ? .passed : .failed } ?? .unavailable,
                snapshot.connected == true ? "已建立数据连接" : "没有确认到数据连接")
        } catch {
            check("management", "设备管理", .failed, "不可达或认证失败，请检查 Wi-Fi、本地网络权限和管理凭据")
        }
        await progress("检测代理与 DNS", 0.35)
        do {
            _ = try await client.version()
            check("controller", "代理控制", .passed, "控制 API 认证通过")
        } catch {
            check("controller", "代理控制", .failed, "控制 API 不可达或 Secret 无效")
        }
        do {
            let reachable = try await api.connectivity()
            check("tcp", "代理 TCP", reachable ? .passed : .failed, reachable ? "设备代理 HTTP 探测通过" : "设备代理 HTTP 探测失败")
        } catch {
            check("tcp", "代理 TCP", .unavailable, "设备未能完成连通性检测")
        }
        if demo {
            check("dns", "设备 DNS", .passed, "演示：域名解析通过")
            check("udp", "UDP TUN", .unavailable, "演示模式不发送公网 UDP 探测")
            check("clock", "设备校时", .passed, "演示：设备时间与手机接近")
        } else {
            if let host, !host.isEmpty {
                do {
                    if let ufi = api as? any UFIDiagnosticsService {
                        checks.append(try await ufi.dnsDiagnostic(publicResolver: false))
                        do {
                            checks.append(try await ufi.dnsDiagnostic(publicResolver: true))
                        } catch {
                            check("udp-device", "设备 UDP DNS", .unavailable, "未能执行公网 UDP 探测，请检查管理通道。")
                        }
                    } else {
                        let output = try await api.runMaintenanceScript(NetworkDiagnostics.dnsProbe(host: host))
                        checks.append(NetworkDiagnostics.dnsResult(output))
                    }
                } catch {
                    check("dns", "局域网 DNS", .unavailable, "未能执行 DNS 探测，请检查管理通道；此结果不代表 DNS 故障。")
                }
            } else {
                check("dns", "局域网 DNS", .unavailable, "没有当前设备地址，未执行 DNS 探测。")
            }
            await progress("检测手机 Wi-Fi UDP 出口", 0.75)
            try context.validate()
            checks.append(await ClientUDPDiagnostic.run(deviceHost: host ?? ""))
            do {
                let started = Date()
                let value: String
                if let ufi = api as? any UFIDiagnosticsService {
                    value = try await ufi.readClock()
                } else {
                    value = try await api.runMaintenanceScript("date +%s")
                }
                checks.append(NetworkDiagnostics.clockResult(value, started: started, finished: Date()))
            } catch {
                check("clock", "设备时间", .unavailable, "无法读取设备时钟，未进行偏差判断。")
            }
        }
        try context.validate()
        let result = DiagnosticReport(date: Date(), demo: demo, checks: checks)
        return result
    }
}
