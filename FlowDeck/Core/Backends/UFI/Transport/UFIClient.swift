import CryptoKit
import Foundation

/// UFI 会话与身份边界。原厂控制和射频协议分别位于扩展文件，不复用 U60 的 ubus。
actor UFIClient: WebSSHAPI {
    let baseURL: URL
    private let password: String
    private let session: URLSession
    let expectedFingerprint: String?
    let mihomo: (any MihomoAPI)?
    private let redirectBlocker = RedirectBlocker()
    private var configurationTransferRunning = false
    var radioWriteRunning = false
    var factoryCookie: String?
    var factoryPasswordDigest: String?

    init(
        baseURL: URL, password: String, expectedFingerprint: String? = nil,
        mihomo: (any MihomoAPI)? = nil,
        configuration: URLSessionConfiguration = .ephemeral
    ) {
        self.baseURL = baseURL
        self.password = password
        self.expectedFingerprint = expectedFingerprint
        self.mihomo = mihomo
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration, delegate: redirectBlocker, delegateQueue: nil)
    }

    /// 作者公开协议签名常量，不是用户密钥。时间戳以毫秒计。
    nonisolated static func headers(password: String, method: String, path: String, timestamp: String)
        -> [String: String]
    {
        let key = SymmetricKey(data: Data("minikano_kOyXz0Ciz4V7wR0IeKmJFYFQ20jd".utf8))
        let digest = Data(
            HMAC<Insecure.MD5>.authenticationCode(
                for: Data("minikano\(method)\(path)\(timestamp)".utf8), using: key))
        let halves = Data(SHA256.hash(data: digest.prefix(8))) + Data(SHA256.hash(data: digest.suffix(8)))
        return [
            "authorization": DeviceIdentity.digest(Data(password.utf8)),
            "kano-t": timestamp, "kano-sign": DeviceIdentity.digest(halves),
            "Content-Type": "application/json",
        ]
    }

    func request(
        _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil,
        form: [String: String]? = nil, cookie: String? = nil
    ) async throws -> JSONObject {
        guard !password.isEmpty else { throw ManagementError.invalid("请填写 UFI-TOOLS 管理口令。") }
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = query.isEmpty ? nil : query
        guard let url = components?.url else { throw WebSSHError.invalidResponse }
        var request = URLRequest(url: url)
        let method = body == nil && form == nil ? "GET" : "POST"
        request.httpMethod = method
        // UFI 的签名只包含路由路径，查询参数另行编码，不参与签名。
        request.allHTTPHeaderFields = Self.headers(
            password: password, method: method, path: "/" + path,
            timestamp: String(Int64(Date().timeIntervalSince1970 * 1000)))
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        if let form {
            request.httpBody = Self.formData(form)
            request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        }
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Kano-Cookie") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw WebSSHError.invalidResponse }
        guard response.statusCode != 401, response.statusCode != 403 else {
            throw ManagementError.invalid("UFI-TOOLS 认证失败，请检查管理口令和手机时间。")
        }
        guard response.statusCode == 200, let object = JSONObject(data: data),
            object.string("error") == nil, object.string("Error") == nil
        else {
            // 原始 shell 错误可能包含敏感内容，不直接展示或写日志。
            throw ManagementError.unconfirmed("UFI-TOOLS 请求失败（HTTP \(response.statusCode)），请检查连接与高级功能。")
        }
        if let cookie = response.value(forHTTPHeaderField: "kano-cookie")?.components(separatedBy: ";").first,
            cookie.contains("="), !cookie.contains("\n"), !cookie.contains("\r") {
            factoryCookie = cookie
        }
        return object
    }

    /// 原厂 goform 使用表单编码。特别编码 +、& 和 =，避免破坏密码及中文 SSID。
    nonisolated static func formData(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let text = values.keys.sorted().map { key in
            let name = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            let value = values[key]!.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return name + "=" + value
        }.joined(separator: "&")
        return Data(text.utf8)
    }

    func hardwareDetails() async throws -> UFIHardwareDetails {
        _ = try await identitySnapshot()
        let system = try await request("api/baseDeviceInfo")
        // USB 信息不是读取系统状态的前提，失败时页面单独说明。
        let usb = try? await request("api/usb_status")
        return UFIHardwareDetails(system: system, usb: usb)
    }

    func shell(_ command: String, root: Bool = false) async throws -> String {
        let result = try await request(
            root ? "api/root_shell" : "api/user_shell",
            body: ["command": command, "timeout": 8000])
        if root, let text = result.raw["result"] as? String {
            return text.replacingOccurrences(of: "\\n", with: "\n")
        }
        guard let output = result.object("result"), output.bool("done") == true,
            let content = output.string("content")
        else {
            throw ManagementError.unconfirmed("UFI-TOOLS 未返回已完成的读取结果。")
        }
        return content
    }

    nonisolated static func fields(_ text: String) -> [String: String] {
        text.split(separator: "\n").reduce(into: [:]) { fields, line in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                fields[String(parts[0])] = String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
    }

    /// 不把序列号伪装成 IMEI；旧 U60 指纹保持不变。
    nonisolated static func snapshot(from text: String) throws -> DeviceSnapshot {
        let values = fields(text)
        guard values["model"] == "F50", let serial = values["serial"],
            (6...64).contains(serial.count), serial.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else {
            throw ManagementError.unsupported("未读取到可验证的 F50 身份，当前 UFI 接入仅适配 F50。")
        }
        var snapshot = DeviceSnapshot()
        snapshot.model = "MU300"
        snapshot.marketName = "F50"
        snapshot.identitySerial = serial
        snapshot.firmware = values["firmware"]
        snapshot.operatorName = values["operator"].flatMap { $0.isEmpty ? nil : $0 }
        snapshot.networkType = values["network"].flatMap { $0.isEmpty ? nil : $0 }
        snapshot.uptime = values["uptime"].flatMap(Double.init).map(Int.init)
        snapshot.memTotalKB = values["memoryTotal"].flatMap(Int64.init)
        snapshot.memAvailKB = values["memoryAvailable"].flatMap(Int64.init)
        return snapshot
    }

    func snapshot() async throws -> DeviceSnapshot {
        var snapshot = try await identitySnapshot()
        do {
            let cellular = try await wifiQuery(
                "network_type,network_provider,ppp_status,signalbar,Z5g_rsrp,lte_rsrp")
            snapshot = Self.applyingCellular(cellular, to: snapshot)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            // 原厂接口不可用不等于整台设备离线；保留身份和系统状态，但不沿用旧蜂窝值。
            snapshot.cellularStatusError = "蜂窝状态读取失败，请下拉刷新重试。"
        }
        return snapshot
    }

    /// 只解析原厂明确返回的状态；缺失、未知和信号占位值不推断为在线或正常。
    nonisolated static func applyingCellular(_ object: JSONObject, to source: DeviceSnapshot) -> DeviceSnapshot {
        var snapshot = source
        snapshot.operatorName = object.string("network_provider")?.trimmingCharacters(in: .whitespacesAndNewlines)
        snapshot.networkType = object.string("network_type")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let network = snapshot.networkType?.uppercased() ?? ""
        snapshot.isNR = network.contains("5G") || ["NR", "SA", "NSA"].contains(network)
        switch object.string("ppp_status")?.lowercased() {
        case "ppp_connected", "ipv4_connected", "ipv6_connected", "ipv4_ipv6_connected", "connected":
            snapshot.connected = true
        case "ppp_disconnected", "ipv4_disconnected", "ipv6_disconnected", "ipv4_ipv6_disconnected", "disconnected":
            snapshot.connected = false
        default:
            snapshot.connected = nil
        }
        snapshot.signalBars = object.double("signalbar").flatMap {
            (0...5).contains($0) && $0.rounded() == $0 ? Int($0) : nil
        }
        // 不用残留的 5G 读数覆盖当前 LTE；也不把 LTE 锚点信号标成 NR 信号。
        let signalKey = snapshot.isNR ? "Z5g_rsrp" : "lte_rsrp"
        snapshot.rsrp = object.double(signalKey).flatMap { (-160 ... -20).contains($0) ? $0 : nil }
        snapshot.cellularStatusError = snapshot.connected == nil ? "设备未返回可识别的蜂窝连接状态。" : nil
        return snapshot
    }

    /// 服务操作只校验身份，不依赖可选的蜂窝状态接口。
    func identitySnapshot() async throws -> DeviceSnapshot {
        let text = try await shell(
            """
            printf 'model='; getprop ro.product.model
            printf 'serial='; getprop ro.serialno
            printf 'firmware='; getprop ro.build.display.id
            printf 'operator='; getprop gsm.operator.alpha
            printf 'network='; getprop gsm.network.type
            awk '{print "uptime=" $1}' /proc/uptime
            awk '/MemTotal:/ {print "memoryTotal=" $2} /MemAvailable:/ {print "memoryAvailable=" $2}' /proc/meminfo
            """)
        let snapshot = try Self.snapshot(from: text)
        if let expectedFingerprint, snapshot.identityFingerprint != expectedFingerprint {
            throw ManagementError.deviceChanged
        }
        return snapshot
    }

    /// 写入只接受实测 B09 和归档的服务适配脚本；不自动覆盖设备上的未知实现。
    func verifyServiceAdapter() async throws {
        let current = try await identitySnapshot()
        guard expectedFingerprint != nil, DeviceCompatibility.supportsUFIWrite(current) else {
            throw ManagementError.unsupported("代理启停需要已绑定的 F50 B09。")
        }
        let output = try await shell("id -u; sha256sum /data/clash/Scripts/Clash.Service", root: true)
        guard output.split(separator: "\n").first == "0",
            output.contains(DeviceCompatibility.f50ServiceDigest)
        else {
            throw ManagementError.unsupported("未检测到受支持的 F50 服务适配器，已禁止启停；节点管理仍可使用。")
        }
    }

    func mihomoStatus() async throws -> MihomoServiceStatus {
        _ = try await identitySnapshot()
        let output = try await shell(
            """
            printf 'pid='; pidof Clash.Core; echo
            printf 'version='; /data/clash/Proxy/Clash.Core -v 2>/dev/null | head -1
            if grep -qxF '/data/clash/Scripts/Clash.Service start' /sdcard/ufi_tools_boot.sh; then echo 'autostart=1'; else echo 'autostart=0'; fi
            """, root: true)
        let values = Self.fields(output)
        let pid = values["pid"]?.split(separator: " ").first.flatMap { Int($0) }
        let apiReachable = (try? await mihomo?.version()) != nil
        return MihomoServiceStatus(
            running: pid != nil, pid: pid, startTime: nil,
            binaryVersion: values["version"], apiReachable: apiReachable,
            autostart: values["autostart"] == "1")
    }

    func control(_ action: ProxyAction) async throws -> String {
        try await verifyServiceAdapter()
        let commands: String
        switch action {
        case .start: commands = "/data/clash/Scripts/Clash.Service start"
        case .stop: commands = "/data/clash/Scripts/Clash.Service stop"
        case .restart:
            commands = "/data/clash/Scripts/Clash.Service stop && /data/clash/Scripts/Clash.Service start"
        case .reloadIPSet: throw unsupported()
        }
        try await checkedCommand(commands)
        return "命令已执行，正在回读状态"
    }

    func checkedCommand(_ command: String) async throws {
        let result = try await shell("{ \(command); } >/dev/null 2>&1; echo flowdeck_exit=$?", root: true)
        guard Self.fields(result)["flowdeck_exit"] == "0" else {
            throw ManagementError.unconfirmed("服务命令未完成，请重新读取状态。")
        }
    }

    func setAutostart(_ enabled: Bool) async throws {
        try await verifyServiceAdapter()
        let remove = "sed -i '\\|^/data/clash/Scripts/Clash.Service start$|d' /sdcard/ufi_tools_boot.sh"
        let append =
            enabled ? " && echo '/data/clash/Scripts/Clash.Service start' >> /sdcard/ufi_tools_boot.sh" : ""
        try await checkedCommand("touch /sdcard/ufi_tools_boot.sh && \(remove)\(append)")
    }

    func checkConfig() async throws -> ConfigCheckResult {
        try await verifyServiceAdapter()
        let output = try await shell(
            "/data/clash/Proxy/Clash.Core -t -d /data/clash/Proxy -f /data/clash/Proxy/config.yaml >/dev/null 2>&1; echo flowdeck_exit=$?",
            root: true)
        let ok = Self.fields(output)["flowdeck_exit"] == "0"
        return ConfigCheckResult(ok: ok, message: ok ? "配置校验通过" : "配置校验失败", output: "")
    }

    func connectivity() async throws -> Bool {
        try await verifyServiceAdapter()
        guard let runtime = try await mihomo?.runtimeSettings(),
            let port = runtime.int("mixed-port") ?? runtime.int("port"), (1...65535).contains(port) else {
            throw ManagementError.unconfirmed("无法确认当前代理端口。")
        }
        let output = try await shell(
            "/data/data/com.minikano.f50_sms/files/curl --silent --output /dev/null "
                + "--max-time 5 --proxy http://127.0.0.1:\(port) "
                + "--write-out 'flowdeck_http=%{http_code}' https://www.gstatic.com/generate_204",
            root: true)
        return Self.fields(output)["flowdeck_http"] == "204"
    }

    private func unsupported() -> ManagementError {
        .unsupported("此功能尚未适配 F50 / UFI-TOOLS，请使用设备管理网页。")
    }

    /// 辅助程序只传密文，不使用公开上传目录，也不让 shell 日志接触明文配置。
    func loadConfig() async throws -> String {
        try await transferConfiguration()
    }

    func saveConfig(_ content: String) async throws {
        _ = try await transferConfiguration(saving: content)
    }

    private func transferConfiguration(saving content: String? = nil) async throws -> String {
        guard expectedFingerprint != nil else { throw ManagementError.deviceChanged }
        guard !configurationTransferRunning else {
            throw ManagementError.invalid("配置正在传输，请稍后重试。")
        }
        configurationTransferRunning = true
        defer { configurationTransferRunning = false }
        try await verifyServiceAdapter()
        return try await UFISecureConfigChannel { command in
            try await self.shell(command, root: true)
        }.transfer(saving: content)
    }
    func rpc(_ service: String, _ method: String, params: JSONObject) async throws -> JSONObject {
        throw unsupported()
    }
    func management(_ method: String, _ path: String, body: JSONObject?) async throws -> JSONObject {
        throw unsupported()
    }
    func dataVersion() async throws -> DataVersion {
        throw unsupported()
    }
    func startDataUpdate() async throws -> DataUpdateStatus {
        throw unsupported()
    }
    func dataUpdateStatus() async throws -> DataUpdateStatus {
        throw unsupported()
    }
    func clients() async throws -> [LANClient] {
        throw unsupported()
    }
    func sms() async throws -> [SMSMessage] {
        throw unsupported()
    }
    func markSMSRead(id: Int) async throws {
        throw unsupported()
    }
    func wifiSettings() async throws -> [String: WifiRadioSettings] {
        throw unsupported()
    }
    func setWifi(_ settings: [String: WifiRadioSettings]) async throws {
        throw unsupported()
    }
    func setNetworkMode(_ mode: NetworkMode) async throws {
        throw unsupported()
    }
    func lockLTEBands(_ bands: [Int]) async throws {
        throw unsupported()
    }
    func lockNRBands(_ bands: [Int]) async throws {
        throw unsupported()
    }
    func reboot() async throws {
        throw unsupported()
    }
}
