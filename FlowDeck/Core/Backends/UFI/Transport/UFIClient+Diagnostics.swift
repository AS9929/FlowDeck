import Foundation

/// 使用设备上的 Java UDP socket，绕开 Android 缺少 nslookup 的限制。
extension UFIClient {
    func dnsDiagnostic(publicResolver: Bool) async throws -> DiagnosticCheck {
        try await verifyServiceAdapter()
        let server = baseURL.host ?? ""
        guard server.range(of: "^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", options: .regularExpression) != nil else {
            throw ManagementError.unsupported("UDP 探测当前需要 IPv4 管理地址。")
        }
        let helper = try await UFISecureConfigChannel { try await self.shell($0, root: true) }.prepare()
        if publicResolver {
            return try await DeviceUDPDNSDiagnostic.run { server in
                let output = try await self.shell(
                    "CLASSPATH=\(helper) app_process /system/bin FlowDeckProbe \(server)", root: true)
                return Self.fields(output)["probe"]
            }
        }
        let output = try await shell("CLASSPATH=\(helper) app_process /system/bin FlowDeckProbe \(server)", root: true)
        let result = Self.fields(output)["probe"]
        let title = "局域网 DNS"
        let detail: String
        switch result {
        case "passed":
            detail = "设备 LAN DNS 已返回 www.example.com 的有效回答。"
        case "timeout":
            detail = "\(server):53 的 UDP DNS 请求超时，可能是解析器或链路限制；不能据此认定代理节点故障。"
        case "invalid-response":
            detail = "收到 DNS 应答，但事务编号、结果码或回答不满足校验。"
        default:
            detail = "设备未能执行 UDP 探测。"
        }
        return DiagnosticCheck(
            id: "dns", title: title,
            outcome: result == "passed" ? .passed : result == "unavailable" || result == nil ? .unavailable : .failed,
            detail: detail)
    }
}

/// 公网 DNS 仅用于验证设备发出的 UDP 往返，不代表热点终端或所有代理规则。
/// 固定两个独立解析器，各最多两次；保留失败目标，避免单点超时被解释成整体故障。
enum DeviceUDPDNSDiagnostic {
    static let servers = ["223.5.5.5", "1.1.1.1"]

    static func run(probe: (String) async throws -> String?) async throws -> DiagnosticCheck {
        var outcomes: [(server: String, result: String)] = []
        for server in servers {
            var result: String?
            for _ in 0..<2 {
                try Task.checkCancellation()
                result = try await probe(server)
                // 辅助程序缺失或无法执行时重复请求没有意义；仅重试未收到有效回答。
                if result != "timeout" && result != "invalid-response" { break }
            }
            outcomes.append((server, result ?? "unavailable"))
        }
        try Task.checkCancellation()
        let passed = outcomes.filter { $0.result == "passed" }.map(\.server)
        let details = outcomes.map { entry in
            let status: String
            switch entry.result {
            case "passed": status = "有有效应答"
            case "timeout": status = "重试后仍超时"
            case "invalid-response": status = "应答未通过校验"
            default: status = "未能执行"
            }
            return "\(entry.server):53 \(status)"
        }.joined(separator: "；")
        let outcome: DiagnosticCheck.Outcome
        let conclusion: String
        if !passed.isEmpty {
            outcome = .passed
            conclusion = "设备 UDP DNS 往返已验证；不代表手机 UDP 代理分流全部正常。"
        } else if outcomes.allSatisfy({ $0.result == "timeout" || $0.result == "invalid-response" }) {
            outcome = .failed
            conclusion = "本次未获得有效 DNS 应答，不能据此认定全部 UDP 或代理节点故障。"
        } else {
            outcome = .unavailable
            conclusion = "探测未完整执行，请重测；尚不能判断设备 UDP 状态。"
        }
        return DiagnosticCheck(id: "udp-device", title: "设备 UDP DNS", outcome: outcome, detail: details + "。" + conclusion)
    }
}
