import Foundation

/// 经版本接口确认可独立修改的运行选项；不发送端口、认证或 TUN 路由字段。
/// 修改仅影响内存中的运行配置，重启后恢复配置文件中的值。
enum RuntimeChange: Sendable {
    case ipv6(Bool)
    case sniffing(Bool)
    case tcpConcurrent(Bool)
    case logLevel(String)

    var field: String {
        switch self {
        case .ipv6: return "ipv6"
        case .sniffing: return "sniffing"
        case .tcpConcurrent: return "tcp-concurrent"
        case .logLevel: return "log-level"
        }
    }

    func payload() throws -> JSONObject {
        switch self {
        case .ipv6(let value), .sniffing(let value), .tcpConcurrent(let value):
            return JSONObject([field: value])
        case .logLevel(let value):
            guard ["silent", "error", "warning", "info", "debug"].contains(value) else {
                throw ManagementError.invalid("不支持的日志级别")
            }
            return JSONObject([field: value])
        }
    }

    func matches(_ actual: JSONObject) -> Bool {
        switch self {
        case .ipv6(let value), .sniffing(let value), .tcpConcurrent(let value):
            return actual.bool(field) == value
        case .logLevel(let value): return actual.string(field) == value
        }
    }
}

enum ProviderKind: String, CaseIterable, Sendable {
    case proxies, rules
    var title: String { self == .proxies ? "节点订阅" : "规则集合" }
}

/// 只保留可展示的集合摘要与订阅用量，订阅地址及认证信息不进入显示模型。
struct MihomoProvider: Identifiable, Sendable {
    let name: String
    let kind: ProviderKind
    let vehicle: String
    let count: Int
    let updatedAt: String?
    var quota: SubscriptionQuota? = nil
    var id: String { "\(kind.rawValue):\(name)" }
    var canUpdate: Bool { ["HTTP", "File"].contains(vehicle) }
    /// Mihomo 会为每个直接写节点的策略组自动生成 Compatible 集合，它不是订阅，不能更新，也没有更新时间。
    var isUserFacing: Bool { vehicle != "Compatible" }
    var isOnline: Bool { vehicle == "HTTP" }

    /// 0001-01-01 之类的零值时间视为“从未更新”。
    var updatedDate: Date? {
        guard let updatedAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: updatedAt) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: updatedAt)
        }()
        guard let date, date.timeIntervalSince1970 > 946_684_800 else { return nil }
        return date
    }

    static func parse(_ object: JSONObject, kind: ProviderKind) -> [MihomoProvider] {
        let values = object.raw["providers"] as? [String: [String: Any]] ?? [:]
        return values.map { name, raw in
            let item = JSONObject(raw)
            return MihomoProvider(
                name: name, kind: kind, vehicle: item.string("vehicleType") ?? "未知",
                count: kind == .proxies ? item.array("proxies").count : item.int("ruleCount") ?? 0,
                updatedAt: item.string("updatedAt"),
                quota: item.object("subscriptionInfo").map(SubscriptionQuota.init)
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// 日志只保存在当前页面的有界内存中；离开页面会取消连接。
struct MihomoLog: Decodable, Identifiable, Sendable {
    var id = UUID()
    let type: String
    let payload: String
    private enum CodingKeys: String, CodingKey { case type, payload }
}

extension MihomoAPI {
    // 旧测试替身或不支持这些能力的客户端明确失败，不伪造可用设置。
    func runtimeSettings() async throws -> JSONObject { throw MihomoError.invalidResponse }
    func patchRuntime(_ change: RuntimeChange) async throws { throw MihomoError.invalidResponse }
    func providers(_ kind: ProviderKind) async throws -> [MihomoProvider] { throw MihomoError.invalidResponse }
    func updateProvider(_ name: String, kind: ProviderKind) async throws { throw MihomoError.invalidResponse }
    func queryDNS(_ name: String, type: String) async throws -> JSONObject { throw MihomoError.invalidResponse }
    func logs(level: String) -> AsyncThrowingStream<MihomoLog, Error> {
        AsyncThrowingStream { $0.finish(throwing: MihomoError.invalidResponse) }
    }
}

/// 清理核心运行缓存；不会删除用户的 YAML 配置。
enum ProxyCacheKind: String, CaseIterable, Identifiable, Sendable {
    case dns
    case fakeip
    var id: String { rawValue }
    var title: String { self == .dns ? "DNS 解析缓存" : "Fake-IP 映射" }
    var symbol: String { self == .dns ? "network" : "point.3.connected.trianglepath.dotted" }
    var detail: String {
        self == .dns
            ? "下次请求重新解析域名，适合排查过期解析结果。"
            : "清除域名与虚拟 IP 的对应关系，已有连接可能需要重新建立。"
    }
}

extension MihomoAPI {
    func flushCache(_ kind: ProxyCacheKind) async throws { throw MihomoError.invalidResponse }
    func healthCheckProvider(_ name: String) async throws { throw MihomoError.invalidResponse }
}

/// Mihomo 仅在订阅服务器提供 userinfo 时返回；零总额或零到期时间不解释为“无限”。
struct SubscriptionQuota: Sendable {
    let uploaded: Int64
    let downloaded: Int64
    let total: Int64
    let expiry: Date?
    var used: Int64 {
        let result = uploaded.addingReportingOverflow(downloaded)
        return result.overflow ? Int64.max : result.partialValue
    }

    init(_ object: JSONObject) {
        uploaded = max(0, object.int64("Upload") ?? 0)
        downloaded = max(0, object.int64("Download") ?? 0)
        total = max(0, object.int64("Total") ?? 0)
        let expire = object.double("Expire") ?? 0
        expiry = expire > 0 ? Date(timeIntervalSince1970: expire) : nil
    }
}
