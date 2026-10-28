import Foundation

/// 一个操作固定使用同一目标和客户端。持有者不在 await 后重新解析当前设备。
struct DeviceSession: Sendable {
    let profile: DeviceProfile?
    let revision: Int
    let demo: Bool
    let mihomo: any MihomoAPI
    let management: any WebSSHAPI

    @MainActor
    func validate(in store: DeviceStore) throws {
        guard revision == store.clientRevision, profile == store.current, demo == store.demoMode else {
            throw ManagementError.deviceChanged
        }
    }
}

/// 地址只接受主机与端口，避免配置损坏时解析为带路径或凭据的不同目标。
enum DeviceEndpoint {
    static func url(host: String, port: Int) -> URL? {
        guard (1...65535).contains(port), !host.isEmpty,
            !host.contains(where: { "/?#@ \t\r\n".contains($0) })
        else { return nil }
        guard let url = URL(string: "http://\(host):\(port)"),
            url.host?.isEmpty == false, url.port == port, url.user == nil,
            url.password == nil, url.path.isEmpty
        else { return nil }
        return url
    }
}
