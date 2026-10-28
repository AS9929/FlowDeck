import Foundation

enum MihomoError: LocalizedError, Equatable {
    case unauthorized
    case unreachable(String)
    case http(Int, String)
    case invalidResponse
    case notSelectable(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "代理控制返回 401：Secret 不对或已失效。"
        case .unreachable(let reason):
            return "连不上代理控制接口：\(reason)"
        case .http(let code, let body):
            return body.isEmpty ? "代理控制返回 \(code)。" : "代理控制返回 \(code)：\(body)"
        case .invalidResponse:
            return "代理控制返回了无法识别的数据。"
        case .notSelectable(let group):
            return "“\(group)”不是可手动选择的策略组。"
        }
    }
}

/// App 用到的 Mihomo 控制接口。真实设备和演示数据各有一份实现。
protocol MihomoAPI: Sendable {
    func version() async throws -> VersionResponse
    func proxies() async throws -> [String: MihomoProxy]
    func select(group: String, proxy: String) async throws
    func delay(proxy: String, url: String, timeoutMs: Int) async throws -> Int
    func groupDelay(group: String, url: String, timeoutMs: Int) async throws -> [String: Int]
    func config() async throws -> MihomoConfig
    func runtimeSettings() async throws -> JSONObject
    func patchRuntime(_ change: RuntimeChange) async throws
    func providers(_ kind: ProviderKind) async throws -> [MihomoProvider]
    func updateProvider(_ name: String, kind: ProviderKind) async throws
    func queryDNS(_ name: String, type: String) async throws -> JSONObject
    func flushCache(_ kind: ProxyCacheKind) async throws
    func healthCheckProvider(_ name: String) async throws
    func logs(level: String) -> AsyncThrowingStream<MihomoLog, Error>
    func setMode(_ mode: OutboundMode) async throws
    func rules() async throws -> [MihomoRule]
    func connections() async throws -> ConnectionsResponse
    func closeConnection(id: String) async throws
    func traffic() -> AsyncThrowingStream<TrafficSample, Error>
}

extension MihomoAPI {
    /// 断开所有经过某个策略组的连接，让正在使用的 App 立刻换线路。
    @discardableResult
    func closeConnections(through group: String) async throws -> Int {
        let list = try await connections().connections.filter { $0.chains.contains(group) }
        for conn in list {
            try await closeConnection(id: conn.id)
        }
        return list.count
    }
}

enum DelayTest {
    static let url = "https://www.gstatic.com/generate_204"
    static let timeoutMs = 5000
}

/// 通过 HTTP 访问设备上的 Mihomo external-controller（部署配置为 192.168.0.1:9090）。
final class MihomoClient: MihomoAPI, @unchecked Sendable {
    let baseURL: URL
    private let secret: String
    private let session: URLSession

    init(baseURL: URL, secret: String, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.secret = secret
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 8
            cfg.waitsForConnectivity = false
            // 本地设备，不走系统代理。
            cfg.connectionProxyDictionary = [:]
            self.session = URLSession(configuration: cfg)
        }
    }

    // MARK: 路径编码

    /// 策略组和节点名里有中文、空格、emoji、`|`，必须逐段编码，且不能保留 `/`。
    static let segmentAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func encode(segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? segment
    }

    func makeURL(_ segments: [String], query: [URLQueryItem] = []) -> URL {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let base = comps.percentEncodedPath.hasSuffix("/") ? String(comps.percentEncodedPath.dropLast()) : comps.percentEncodedPath
        comps.percentEncodedPath = base + "/" + segments.map(Self.encode(segment:)).joined(separator: "/")
        comps.queryItems = query.isEmpty ? nil : query
        return comps.url!
    }

    private func makeRequest(_ method: String, _ segments: [String], query: [URLQueryItem] = [], json: [String: Any]? = nil) throws -> URLRequest {
        var req = URLRequest(url: makeURL(segments, query: query))
        req.httpMethod = method
        if !secret.isEmpty {
            req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let err as URLError {
            if err.code == .cancelled { throw CancellationError() }
            throw MihomoError.unreachable(err.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw MihomoError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw MihomoError.unauthorized
        default:
            let body = Self.message(from: data)
            throw MihomoError.http(http.statusCode, body)
        }
    }

    private static func message(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let msg = obj["message"] as? String
        {
            return msg
        }
        return String(data: data.prefix(200), encoding: .utf8) ?? ""
    }

    private func get<T: Decodable>(_ type: T.Type, _ segments: [String], query: [URLQueryItem] = []) async throws -> T {
        let data = try await send(makeRequest("GET", segments, query: query))
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MihomoError.invalidResponse
        }
    }

    // MARK: 读取

    func version() async throws -> VersionResponse {
        try await get(VersionResponse.self, ["version"])
    }

    func proxies() async throws -> [String: MihomoProxy] {
        try await get(ProxiesResponse.self, ["proxies"]).proxies
    }

    func delay(proxy: String, url: String, timeoutMs: Int) async throws -> Int {
        let q = [URLQueryItem(name: "url", value: url), URLQueryItem(name: "timeout", value: String(timeoutMs))]
        do {
            return try await get(DelayResponse.self, ["proxies", proxy, "delay"], query: q).delay
        } catch MihomoError.http(let code, _) where code == 408 || code == 504 || code == 503 {
            return 0
        }
    }

    func groupDelay(group: String, url: String, timeoutMs: Int) async throws -> [String: Int] {
        let q = [URLQueryItem(name: "url", value: url), URLQueryItem(name: "timeout", value: String(timeoutMs))]
        return try await get([String: Int].self, ["group", group, "delay"], query: q)
    }

    func config() async throws -> MihomoConfig {
        try await get(MihomoConfig.self, ["configs"])
    }

    func rules() async throws -> [MihomoRule] {
        let list = try await get(RulesResponse.self, ["rules"]).rules
        return list.enumerated().map { MihomoRule(id: $0.offset, type: $0.element.type, payload: $0.element.payload, proxy: $0.element.proxy) }
    }

    func connections() async throws -> ConnectionsResponse {
        try await get(ConnectionsResponse.self, ["connections"])
    }

    // MARK: 写入（会改变设备上的运行状态）

    func select(group: String, proxy: String) async throws {
        _ = try await send(makeRequest("PUT", ["proxies", group], json: ["name": proxy]))
    }

    /// 只改运行状态；Mihomo 重启后会恢复成 config.yaml 里的 mode。
    func setMode(_ mode: OutboundMode) async throws {
        _ = try await send(makeRequest("PATCH", ["configs"], json: ["mode": mode.rawValue]))
    }

    func closeConnection(id: String) async throws {
        _ = try await send(makeRequest("DELETE", ["connections", id]))
    }

    func runtimeSettings() async throws -> JSONObject {
        guard let result = JSONObject(data: try await send(makeRequest("GET", ["configs"]))) else {
            throw MihomoError.invalidResponse
        }
        return result
    }

    func patchRuntime(_ change: RuntimeChange) async throws {
        _ = try await send(makeRequest("PATCH", ["configs"], json: try change.payload().raw))
    }

    func providers(_ kind: ProviderKind) async throws -> [MihomoProvider] {
        guard let result = JSONObject(data: try await send(makeRequest("GET", ["providers", kind.rawValue]))) else {
            throw MihomoError.invalidResponse
        }
        return MihomoProvider.parse(result, kind: kind)
    }

    func updateProvider(_ name: String, kind: ProviderKind) async throws {
        _ = try await send(makeRequest("PUT", ["providers", kind.rawValue, name]))
    }

    func flushCache(_ kind: ProxyCacheKind) async throws {
        _ = try await send(makeRequest("POST", ["cache", kind.rawValue, "flush"]))
    }

    func healthCheckProvider(_ name: String) async throws {
        var request = try makeRequest("GET", ["providers", "proxies", name, "healthcheck"])
        request.timeoutInterval = 60
        _ = try await send(request)
    }

    func queryDNS(_ name: String, type: String) async throws -> JSONObject {
        let query = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "type", value: type)]
        guard let result = JSONObject(data: try await send(makeRequest("GET", ["dns", "query"], query: query))) else {
            throw MihomoError.invalidResponse
        }
        return result
    }

    /// HTTP NDJSON 日志流，页面取消任务时同步取消 URLSession 请求。
    func logs(level: String) -> AsyncThrowingStream<MihomoLog, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(100)) { continuation in
            let task = Task {
                do {
                    var request = try makeRequest("GET", ["logs"], query: [URLQueryItem(name: "level", value: level)])
                    request.timeoutInterval = 3600
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw MihomoError.invalidResponse }
                    if http.statusCode == 401 { throw MihomoError.unauthorized }
                    guard (200..<300).contains(http.statusCode) else { throw MihomoError.http(http.statusCode, "日志接口不可用") }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if let data = line.data(using: .utf8), let log = try? JSONDecoder().decode(MihomoLog.self, from: data) {
                            continuation.yield(log)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: 流

    func traffic() -> AsyncThrowingStream<TrafficSample, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let req = try makeRequest("GET", ["traffic"])
                    let (bytes, response) = try await session.bytes(for: req)
                    if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                        throw MihomoError.unauthorized
                    }
                    for try await line in bytes.lines {
                        if let data = line.data(using: .utf8),
                            let sample = try? JSONDecoder().decode(TrafficSample.self, from: data)
                        {
                            continuation.yield(sample)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
