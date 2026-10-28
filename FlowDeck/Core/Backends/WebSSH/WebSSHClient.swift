import Foundation

/// 能力组合供现有状态仓库迁移使用；新功能优先依赖下列窄接口。
protocol WebSSHAPI: ManagementTransport, DeviceStatusAPI, ProxyServiceAPI, ConfigurationAPI, RuleDataAPI, WifiManagementAPI, MessageManagementAPI,
    RadioManagementAPI, ClientManagementAPI, SystemManagementAPI
{}

/// WebSSH 传输与受控后台任务。
protocol ManagementTransport: Sendable {
    func rpc(_ service: String, _ method: String, params: JSONObject) async throws -> JSONObject
    func management(_ method: String, _ path: String, body: JSONObject?) async throws -> JSONObject
    func read(_ service: String, _ method: String) async throws -> JSONObject
    func runBackgroundScript(
        directory: String, name: String, title: String, script: String,
        timeout: Duration, pollInterval: Duration
    ) async throws -> String
    func runMaintenanceScript(_ script: String) async throws -> String
}

/// 设备身份和实时快照。
protocol DeviceStatusAPI: Sendable {
    func snapshot() async throws -> DeviceSnapshot
}

/// 代理进程生命周期，与 Mihomo 控制 API 分离。
protocol ProxyServiceAPI: Sendable {
    func mihomoStatus() async throws -> MihomoServiceStatus
    func control(_ action: ProxyAction) async throws -> String
    func setAutostart(_ enabled: Bool) async throws
    func connectivity() async throws -> Bool
}

/// 配置文件传输及设备端校验。
protocol ConfigurationAPI: Sendable {
    func loadConfig() async throws -> String
    func saveConfig(_ content: String) async throws
    func checkConfig() async throws -> ConfigCheckResult
}

/// 规则数据版本和更新。
protocol RuleDataAPI: Sendable {
    func dataVersion() async throws -> DataVersion
    func startDataUpdate() async throws -> DataUpdateStatus
    func dataUpdateStatus() async throws -> DataUpdateStatus
}

/// 原厂 Wi-Fi 读取与保存。
protocol WifiManagementAPI: Sendable {
    func wifiSettings() async throws -> [String: WifiRadioSettings]
    func setWifi(_ settings: [String: WifiRadioSettings]) async throws
    func readWifiNetworks() async throws -> [WifiNetwork]
    func saveWifiNetworks(_ networks: [WifiNetwork]) async throws
}

/// 短信读取与写入。
protocol MessageManagementAPI: Sendable {
    func sms() async throws -> [SMSMessage]
    func markSMSRead(id: Int) async throws
    func sendSMS(number: String, message: String) async throws
}

/// 蜂窝制式及射频设置。
protocol RadioManagementAPI: Sendable {
    func setNetworkMode(_ mode: NetworkMode) async throws
    func lockLTEBands(_ bands: [Int]) async throws
    func lockNRBands(_ bands: [Int]) async throws
}

/// 接入终端和访问控制。
protocol ClientManagementAPI: Sendable {
    func clients() async throws -> [LANClient]
    func setClientBlocked(mac: String, blocked: Bool) async throws
    func blockedClients() async throws -> Set<String>
}

/// 系统设置和 WebSSH 核心维护。
protocol SystemManagementAPI: Sendable {
    func reboot() async throws
    func coreVersion() async throws -> CoreUpdateInfo
    func coreDirectory() async throws -> String
    func rollbackCore() async throws
    func apnProfiles() async throws -> [APNProfile]
    func saveAPN(_ profile: APNProfile) async throws
    func selectAPN(_ id: String?) async throws
    func setRoaming(_ enabled: Bool) async throws
    func setDirectPower(_ enabled: Bool) async throws
    func usbMode() async throws -> String
    func setUSBMode(_ mode: String) async throws
}

struct UbusCall: @unchecked Sendable {
    let service: String
    let method: String
    let params: [String: Any]
}

/// 访问 WebSSH 的 HTTP 接口。认证头是原始 JWT（不带 Bearer）；令牌失效时自动重新登录一次。
actor WebSSHClient: WebSSHAPI {
    let baseURL: URL
    private let username: String
    private let password: String
    private var token: String?
    private let session: URLSession
    private let redirectBlocker = RedirectBlocker()

    init(
        baseURL: URL, username: String, password: String,
        configuration: URLSessionConfiguration = .ephemeral
    ) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        let cfg = configuration.copy() as! URLSessionConfiguration
        cfg.timeoutIntervalForRequest = 20
        cfg.connectionProxyDictionary = [:]
        session = URLSession(configuration: cfg, delegate: redirectBlocker, delegateQueue: nil)
    }

    // MARK: 基础

    private func login() async throws {
        guard !password.isEmpty else { throw WebSSHError.notConfigured }
        var req = URLRequest(url: baseURL.appending(path: "api/login"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["name": username, "pwd": password])
        let (data, _) = try await perform(req)
        guard let obj = JSONObject(data: data) else { throw WebSSHError.invalidResponse }
        guard obj.int("code") == 0, let t = obj.string("token") else {
            throw WebSSHError.loginFailed(obj.string("msg") ?? "未知原因")
        }
        token = t
    }

    private func perform(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let err as URLError {
            if err.code == .cancelled { throw CancellationError() }
            throw WebSSHError.unreachable(err.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw WebSSHError.invalidResponse }
        if let renewed = http.value(forHTTPHeaderField: "NewToken"), !renewed.isEmpty { token = renewed }
        switch http.statusCode {
        case 200..<300: return (data, http)
        case 300..<400: throw WebSSHError.wrongPath
        case 401:
            // 登录接口密码错也返回 401，交给调用方区分。
            if req.url?.path.hasSuffix("/api/login") == true { return (data, http) }
            throw WebSSHError.unauthorized
        case 403:
            throw WebSSHError.forbidden(JSONObject(data: data)?.string("err_msg") ?? "403")
        default:
            throw WebSSHError.api(http.statusCode, JSONObject(data: data)?.string("msg") ?? "HTTP \(http.statusCode)")
        }
    }

    private func rawRequest(_ method: String, _ path: String, json: Any?, timeout: TimeInterval) async throws -> Data {
        if token == nil { try await login() }
        func build() throws -> URLRequest {
            var req = URLRequest(url: baseURL.appending(path: path))
            req.httpMethod = method
            req.timeoutInterval = timeout
            req.setValue(token, forHTTPHeaderField: "Authorization")
            if let json {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: json)
            }
            return req
        }
        do {
            return try await perform(try build()).0
        } catch WebSSHError.unauthorized {
            token = nil
            try await login()
            return try await perform(try build()).0
        }
    }

    /// 大多数接口返回 `{"code":0,"msg":"ok","data":...}`，非 0 视为失败。
    func call(_ method: String, _ path: String, json: Any? = nil, timeout: TimeInterval = 20) async throws -> JSONObject {
        let data = try await rawRequest(method, path, json: json, timeout: timeout)
        guard let obj = JSONObject(data: data) else { throw WebSSHError.invalidResponse }
        if let code = obj.int("code"), code != 0 {
            throw WebSSHError.api(code, obj.string("msg") ?? "操作失败")
        }
        return obj
    }

    /// `POST /api/ubus`：在设备本机调用原厂 ubus 服务。返回按请求顺序排列的结果，失败的为 nil。
    func ubus(_ calls: [UbusCall]) async throws -> [Result<JSONObject, WebSSHError>] {
        let body: [[String: Any]] = calls.enumerated().map { i, c in
            [
                "jsonrpc": "2.0", "id": i + 1, "method": "call",
                "params": ["00000000000000000000000000000000", c.service, c.method, c.params as [String: Any]],
            ]
        }
        let data = try await rawRequest("POST", "api/ubus", json: body, timeout: 20)
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw WebSSHError.invalidResponse
        }
        var byID: [Int: Result<JSONObject, WebSSHError>] = [:]
        for item in list {
            guard let id = (item["id"] as? NSNumber)?.intValue, let result = item["result"] as? [Any], let code = (result.first as? NSNumber)?.intValue else {
                continue
            }
            if code == 0, result.count > 1, let obj = result[1] as? [String: Any] {
                byID[id] = .success(JSONObject(obj))
            } else {
                byID[id] = .failure(.ubus(result.count > 1 ? "\(result[1])" : "code \(code)"))
            }
        }
        return calls.indices.map { byID[$0 + 1] ?? .failure(.ubus("没有返回")) }
    }

    func rpc(_ service: String, _ method: String, params: JSONObject = JSONObject()) async throws -> JSONObject {
        let results = try await ubus([UbusCall(service: service, method: method, params: params.raw)])
        let result = try results[0].get()
        if service == "file", method == "exec" { return result }
        if let code = result.int("code"), code != 0 {
            throw ManagementError.unconfirmed("设备拒绝了操作（\(code)）")
        }
        if let value = result.string("result"), ["failure", "failed", "error"].contains(value.lowercased()) {
            throw ManagementError.unconfirmed("设备未接受此操作。")
        }
        if result.bool("success") == false {
            throw ManagementError.unconfirmed("设备报告操作失败。")
        }
        return result
    }

    func management(_ method: String, _ path: String, body: JSONObject? = nil) async throws -> JSONObject {
        try await call(method, path, json: body?.raw, timeout: 90)
    }

    // MARK: 代理服务

    func mihomoStatus() async throws -> MihomoServiceStatus {
        MihomoServiceStatus(try await call("GET", "api/mihomo/status").object("data") ?? JSONObject())
    }

    /// 同步执行 mm.sh，服务端超时 60 秒，加载 IP 段要 30 秒左右。
    func control(_ action: ProxyAction) async throws -> String {
        let obj = try await call("POST", "api/mihomo/control", json: ["action": action.rawValue], timeout: 90)
        return obj.string("output") ?? ""
    }

    func setAutostart(_ enabled: Bool) async throws {
        _ = try await call("POST", "api/mihomo/autostart", json: ["enabled": enabled])
    }

    func connectivity() async throws -> Bool {
        try await call("GET", "api/mihomo/connectivity", timeout: 6).object("data")?.bool("reachable") ?? false
    }

    // MARK: 代理配置

    func loadConfig() async throws -> String {
        try await call("GET", "api/mihomo/config").object("data")?.string("content") ?? ""
    }

    /// 服务端会先把旧文件备份为 config.yaml.bak，不会自动重载代理。
    func saveConfig(_ content: String) async throws {
        _ = try await call("PUT", "api/mihomo/config", json: ["content": content])
    }

    /// 检查的是已保存的文件（mihomo -t），本身不改设备。
    func checkConfig() async throws -> ConfigCheckResult {
        let data = try await rawRequest("POST", "api/mihomo/config/check", json: nil, timeout: 30)
        guard let obj = JSONObject(data: data) else { throw WebSSHError.invalidResponse }
        let code = obj.int("code") ?? 1
        return ConfigCheckResult(
            ok: code == 0, message: obj.string("msg") ?? "",
            output: [obj.string("output"), obj.string("err")].compactMap { $0 }.joined(separator: "\n"))
    }

    // MARK: 规则数据

    func dataVersion() async throws -> DataVersion {
        let d = try await call("GET", "api/mihomo/data/version", timeout: 30).object("data") ?? JSONObject()
        return DataVersion(local: d.string("local_version"), remote: d.string("remote_version"), hasUpdate: d.bool("has_update") ?? false)
    }

    func startDataUpdate() async throws -> DataUpdateStatus {
        DataUpdateStatus(try await call("POST", "api/mihomo/data/update").object("data") ?? JSONObject())
    }

    func dataUpdateStatus() async throws -> DataUpdateStatus {
        DataUpdateStatus(try await call("GET", "api/mihomo/data/update/status").object("data") ?? JSONObject())
    }

    // MARK: 设备

    func snapshot() async throws -> DeviceSnapshot {
        let calls = [
            UbusCall(service: "zte_nwinfo_api", method: "nwinfo_get_netinfo", params: [:]),
            UbusCall(service: "zwrt_data", method: "get_wwandst", params: ["source_module": "web", "cid": 1, "type": 4]),
            UbusCall(service: "zwrt_mc.device.manager", method: "get_device_info", params: [:]),
            UbusCall(service: "zwrt_bsp.thermal", method: "get_cpu_temp", params: [:]),
            UbusCall(service: "uci", method: "get", params: ["config": "zwrt_zte_mdm", "section": "device_info"]),
            UbusCall(service: "zwrt_zte_mdm.api", method: "get_sim_info", params: [:]),
            UbusCall(service: "uci", method: "get", params: ["config": "zwrt_common_info", "section": "common_config"]),
            UbusCall(service: "zwrt_wlan", method: "report", params: [:]),
            UbusCall(service: "zwrt_router.api", method: "router_get_user_list_num", params: [:]),
            UbusCall(service: "zwrt_data", method: "get_wwaniface", params: ["source_module": "web", "cid": 1, "connect_status": ""]),
        ]
        let r = try await ubus(calls).map { try? $0.get() }
        if r.allSatisfy({ $0 == nil }) { throw WebSSHError.ubus("所有原厂接口都没有返回数据") }
        return DeviceSnapshot(
            netinfo: r[0], traffic: r[1], device: r[2], cpuTemp: r[3], mdm: r[4], sim: r[5],
            common: r[6], wlan: r[7], users: r[8], wan: r[9])
    }

    func clients() async throws -> [LANClient] {
        let r = try await ubus([
            UbusCall(service: "zwrt_router.api", method: "router_wireless_access_list", params: ["start_id": 1, "end_id": 64]),
            UbusCall(service: "zwrt_router.api", method: "router_lan_access_list", params: [:]),
            UbusCall(service: "iwinfo", method: "assoclist", params: ["device": "wlan0"]),
            UbusCall(service: "iwinfo", method: "assoclist", params: ["device": "wlan2"]),
        ]).map { try? $0.get() }
        var stations: [String: JSONObject] = [:]
        for s in (r[2]?.array("results") ?? []) + (r[3]?.array("results") ?? []) {
            if let mac = s.string("mac")?.uppercased() { stations[mac] = s }
        }
        let entries = (r[0]?.array("wireless_access_list_info") ?? []) + (r[1]?.array("lan_access_list_info") ?? [])
        return entries.compactMap { e in
            guard let mac = e.string("mac_address")?.uppercased() else { return nil }
            let st = stations[mac]
            return LANClient(
                hostname: e.string("hostname") ?? "未命名设备", ip: e.string("ip_address") ?? "", mac: mac,
                interface: e.string("interface_type") ?? "", signal: st?.int("signal"),
                rateKbps: st?.object("tx")?.int("rate"), accessTime: e.string("access_time"))
        }
    }

    func sms() async throws -> [SMSMessage] {
        let d = try await call("GET", "api/system/sms").object("data") ?? JSONObject()
        return d.array("messages").compactMap { m in
            guard let id = m.int("id") else { return nil }
            return SMSMessage(
                id: id, number: m.string("number") ?? "", date: m.string("date") ?? "", content: m.string("content") ?? "", tag: m.string("tag") ?? "")
        }
    }

    func markSMSRead(id: Int) async throws {
        let r = try await ubus([UbusCall(service: "zwrt_wms", method: "zwrt_wms_modify_tag", params: ["id": "\(id);", "tag": 0])])
        if case .failure(let e) = r[0] { throw e }
    }

    func wifiSettings() async throws -> [String: WifiRadioSettings] {
        let d = try await call("GET", "api/wifi/settings").object("data") ?? JSONObject()
        var out: [String: WifiRadioSettings] = [:]
        for key in ["wifi0", "wifi1"] {
            if let v = d.object(key)?.object("values") {
                out[key] = WifiRadioSettings(txPower: v.string("txpowerpercent") ?? "100", country: v.string("country") ?? "CN")
            }
        }
        return out
    }

    /// WebSSH 只允许修改发射功率（40/80/100）和国家码。
    func setWifi(_ settings: [String: WifiRadioSettings]) async throws {
        var body: [String: Any] = [:]
        for (k, v) in settings { body[k] = ["txpowerpercent": v.txPower, "country": v.country] }
        _ = try await call("POST", "api/wifi/settings", json: body)
    }

    func setNetworkMode(_ mode: NetworkMode) async throws {
        _ = try await call("POST", "api/network/mode", json: ["net_select": mode.rawValue])
    }

    func lockLTEBands(_ bands: [Int]) async throws {
        _ = try await call("POST", "api/network/band/lte", json: ["bands": bands])
    }

    func lockNRBands(_ bands: [Int]) async throws {
        _ = try await call("POST", "api/network/band/nr", json: ["bands": bands])
    }

    func reboot() async throws {
        let r = try await ubus([UbusCall(service: "zwrt_mc.device.manager", method: "device_reboot", params: ["moduleName": "web"])])
        if case .failure(let e) = r[0] { throw e }
    }
}

/// 未知路径会被 WebSSH 301 到 /app/，不跟随跳转，直接当作接口不存在。
final class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
