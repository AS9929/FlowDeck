import Foundation
import Network

/// 手机 Wi-Fi 的 IPv4 STUN 探测。仅证明该次 UDP 往返及出口地址，不推断所有规则或 IPv6 均正常。
/// 每次最多发送四个 20 字节请求；不上传设备凭据、订阅或短信，不保存出口地址到长期缓存。
enum ClientUDPDiagnostic {
    static let server = "stun.cloudflare.com"

    static func run(deviceHost: String) async -> DiagnosticCheck {
        guard IPv4Address(deviceHost) != nil else {
            return result(.unavailable, "当前检测需要设备的 IPv4 管理地址，请在连接设置中检查。")
        }
        // 模拟器借用 Mac 网络，不能代表 iPhone 到热点的真实转发路径。
        #if targetEnvironment(simulator)
            return result(.unavailable, "模拟器使用 Mac 网络，无法验证手机经 F50 / 随身 Wi-Fi 的 UDP 出口。请在真机连接当前设备 Wi-Fi 后检测；此项不计为网络故障。")
        #else
            return await runOnDevice(deviceHost: deviceHost)
        #endif
    }

    private static func runOnDevice(deviceHost: String) async -> DiagnosticCheck {
        let operation = STUNOperation(deviceHost: deviceHost)
        do {
            let address = try await operation.run()
            return result(
                .passed,
                "手机经当前设备 Wi-Fi 收到 STUN 应答，IPv4 出口为 \(address)。该请求按现有规则路由，不代表所有 UDP 都走代理。")
        } catch let error as STUNOperation.Failure {
            switch error {
            case .wrongNetwork:
                return result(.unavailable, "请连接当前设备 Wi-Fi 并关闭手机 VPN 后重测；尚未确认 Wi-Fi 网关与管理地址一致。")
            case .timeout:
                return result(.failed, "手机已发出 UDP 请求，但未收到有效应答。可能是 STUN 服务、运营商、分流规则或节点限制，请重测并对照设备 UDP 结果。")
            case .unreachable:
                return result(.unavailable, "未能建立 Wi-Fi 探测连接，请检查 Wi-Fi、域名解析及本地网络权限。")
            case .cancelled:
                return result(.unavailable, "检测已取消，请重新检测。")
            }
        } catch {
            return result(.unavailable, "未能完成手机 UDP 检测，请重新检测。")
        }
    }

    static func result(_ outcome: DiagnosticCheck.Outcome, _ detail: String) -> DiagnosticCheck {
        DiagnosticCheck(id: "udp", title: "手机 UDP 出口", outcome: outcome, detail: detail)
    }

    /// 不用“能访问管理地址”代替默认出口判断：家中 Wi-Fi 也可能通过路由访问设备。
    static func matchesGateway(wifi: Bool, gateways: [String], deviceHost: String) -> Bool {
        wifi && IPv4Address(deviceHost) != nil && gateways.contains(deviceHost)
    }
}

/// RFC 8489 Binding 消息。逐项校验边界、事务号及 XOR-MAPPED-ADDRESS，忽略无关数据报。
enum STUNPacket {
    static let cookie: [UInt8] = [0x21, 0x12, 0xa4, 0x42]

    static func request(transaction: [UInt8]) -> Data {
        precondition(transaction.count == 12)
        return Data([0x00, 0x01, 0x00, 0x00] + cookie + transaction)
    }

    static func address(response: Data, transaction: [UInt8]) -> String? {
        let bytes = Array(response)
        guard transaction.count == 12, bytes.count >= 20,
            bytes[0] == 0x01, bytes[1] == 0x01,
            Array(bytes[4..<8]) == cookie, Array(bytes[8..<20]) == transaction
        else { return nil }
        let length = Int(bytes[2]) * 256 + Int(bytes[3])
        guard length % 4 == 0, bytes.count == length + 20 else { return nil }
        var offset = 20
        var address: String?
        while offset < bytes.count {
            guard offset + 4 <= bytes.count else { return nil }
            let type = Int(bytes[offset]) * 256 + Int(bytes[offset + 1])
            let count = Int(bytes[offset + 2]) * 256 + Int(bytes[offset + 3])
            let start = offset + 4
            let end = start + count
            let paddedEnd = start + ((count + 3) / 4) * 4
            guard end <= bytes.count, paddedEnd <= bytes.count else { return nil }
            if type == 0x0020 {
                // 此检测强制 IPv4；拒绝不匹配的地址族、端口零和重复的映射地址。
                guard address == nil, count == 8, bytes[start] == 0, bytes[start + 1] == 1 else { return nil }
                let port = (Int(bytes[start + 2]) * 256 + Int(bytes[start + 3])) ^ 0x2112
                guard port > 0 else { return nil }
                address = (0..<4).map { String(bytes[start + 4 + $0] ^ cookie[$0]) }.joined(separator: ".")
            }
            offset = paddedEnd
        }
        return address
    }
}

/// 所有状态只在专用串行队列上访问；取消、超时和回调竞争时只恢复一次 continuation。
private final class STUNOperation: @unchecked Sendable {
    enum Failure: Error { case wrongNetwork, timeout, unreachable, cancelled }
    private let queue = DispatchQueue(label: "FlowDeck.STUN")
    private let deviceHost: String
    private let transaction = (0..<12).map { _ in UInt8.random(in: .min ... .max) }
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<String, Error>?
    private var finished = false
    private var sent = false

    init(deviceHost: String) { self.deviceHost = deviceHost }

    func run() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.start(continuation) }
            }
        } onCancel: {
            self.queue.async { self.finish(.failure(Failure.cancelled)) }
        }
    }

    private func start(_ continuation: CheckedContinuation<String, Error>) {
        guard !finished else {
            continuation.resume(throwing: Failure.cancelled)
            return
        }
        self.continuation = continuation
        let parameters = NWParameters.udp
        parameters.requiredInterfaceType = .wifi
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(host: NWEndpoint.Host(ClientUDPDiagnostic.server), port: 3478, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.finished else { return }
            switch state {
            case .ready:
                guard self.validPath(connection.currentPath) else {
                    self.finish(.failure(Failure.wrongNetwork))
                    return
                }
                self.receive()
                self.send()
                // 有限重传应对 UDP 丢包；总截止时间包含 DNS 解析与连接等待。
                for delay in [0.5, 1.5, 3.5] {
                    self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.send() }
                }
            case .failed:
                self.finish(.failure(self.sent ? Failure.timeout : Failure.unreachable))
            default: break
            }
        }
        connection.pathUpdateHandler = { [weak self] path in
            guard let self, self.sent, !self.validPath(path) else { return }
            self.finish(.failure(Failure.wrongNetwork))
        }
        queue.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self else { return }
            self.finish(.failure(self.sent ? Failure.timeout : Failure.unreachable))
        }
        connection.start(queue: queue)
    }

    private func validPath(_ path: NWPath?) -> Bool {
        guard let path, path.status == .satisfied else { return false }
        let gateways = path.gateways.compactMap { endpoint -> String? in
            if case .hostPort(let host, _) = endpoint { return "\(host)" }
            return nil
        }
        return ClientUDPDiagnostic.matchesGateway(wifi: path.usesInterfaceType(.wifi), gateways: gateways, deviceHost: deviceHost)
    }

    private func send() {
        guard !finished, let connection else { return }
        guard validPath(connection.currentPath) else {
            finish(.failure(Failure.wrongNetwork))
            return
        }
        sent = true
        connection.send(
            content: STUNPacket.request(transaction: transaction),
            completion: .contentProcessed { [weak self] error in
                if error != nil { self?.finish(.failure(Failure.timeout)) }
            })
    }

    private func receive() {
        connection?.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.finished else { return }
            guard self.validPath(self.connection?.currentPath) else {
                self.finish(.failure(Failure.wrongNetwork))
                return
            }
            if let data, let address = STUNPacket.address(response: data, transaction: self.transaction) {
                self.finish(.success(address))
            } else if error != nil {
                self.finish(.failure(Failure.timeout))
            } else {
                self.receive()
            }
        }
    }

    private func finish(_ result: Result<String, Error>) {
        guard !finished else { return }
        finished = true
        connection?.stateUpdateHandler = nil
        connection?.pathUpdateHandler = nil
        connection?.cancel()
        connection = nil
        continuation?.resume(with: result)
        continuation = nil
    }
}
