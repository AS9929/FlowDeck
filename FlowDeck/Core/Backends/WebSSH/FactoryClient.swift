import CryptoKit
import Foundation

/// 原厂后台第三路认证。会话和 Cookie 仅在本 actor 的临时 URLSession 中保留。
actor FactoryClient {
    private let baseURL: URL
    private let password: String
    private let session: URLSession
    private let redirectBlocker = RedirectBlocker()
    private var token: String?

    init(host: String, password: String, configuration: URLSessionConfiguration = .ephemeral) throws {
        guard let url = URL(string: "http://\(host)"), url.host == host, url.path.isEmpty else {
            throw ManagementError.invalid("请输入设备局域网地址，不要包含路径。")
        }
        baseURL = url
        self.password = password
        let config = configuration
        config.timeoutIntervalForRequest = 15
        config.connectionProxyDictionary = [:]
        session = URLSession(configuration: config, delegate: redirectBlocker, delegateQueue: nil)
    }

    private func request(_ service: String, _ method: String, params: JSONObject, token: String) async throws -> JSONObject {
        var request = URLRequest(url: baseURL.appendingPathComponent("ubus/"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(baseURL.absoluteString + "/", forHTTPHeaderField: "Referer")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            [
                "jsonrpc": "2.0", "id": 1, "method": "call", "params": [token, service, method, params.raw],
            ]
        ])
        let (data, response) = try await session.data(for: request)
        return try Self.decodeResponse(data, statusCode: (response as? HTTPURLResponse)?.statusCode, method: method)
    }

    /// ubus 无返回载荷的操作以 [0] 表示成功，例如 B28 的备份生成。
    /// 登录结果仍由 login 单独校验 token；协议错误不能冒充密码错误。
    nonisolated static func decodeResponse(_ data: Data, statusCode: Int?, method: String) throws -> JSONObject {
        guard statusCode == 200 else {
            throw ManagementError.unconfirmed("原厂接口 \(method) 请求失败（HTTP \(statusCode ?? 0)）。")
        }
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            let result = list.first?["result"] as? [Any],
            let code = result.first as? Int
        else {
            throw ManagementError.unconfirmed("原厂接口 \(method) 返回格式无法识别。")
        }
        guard code == 0 else {
            if code == 6 {
                throw ManagementError.unconfirmed("原厂会话已失效或没有操作权限，请在连接与凭据中重新验证。")
            }
            throw ManagementError.unconfirmed("原厂接口 \(method) 未完成（ubus \(code)）。")
        }
        if result.count == 1 {
            return JSONObject()
        }
        guard let value = result[1] as? [String: Any] else {
            throw ManagementError.unconfirmed("原厂接口 \(method) 返回了不支持的数据格式。")
        }
        if let result = value["result"] as? String, ["failure", "failed", "error"].contains(result.lowercased()) {
            throw ManagementError.unconfirmed("原厂后台未接受此操作（\(method)）。")
        }
        return JSONObject(value)
    }

    /// 首次部署身份以当前原厂响应为准，不能用固定的局域网 IP 代替硬件身份。
    func deploymentIdentity() async throws -> FactoryDeploymentIdentity {
        try await login()
        let info = try await request("zwrt_web", "device_info", params: JSONObject(), token: token ?? "")
        guard let imei = info.string("imei"), let firmware = info.string("wa_inner_version"),
            firmware == FactoryBootstrap.firmware,
            let fingerprint = DeviceIdentity.fingerprint(model: "MU5250", imei: imei)
        else { throw ManagementError.unsupported("首次部署当前仅适配 MU5250 B28，设备身份或固件不匹配。") }
        return FactoryDeploymentIdentity(imei: imei, firmware: firmware, fingerprint: fingerprint)
    }

    /// 上传后核对摘要并再次读身份；恢复只提交一次，网络中断不能当成成功或自动重试。
    func restoreDeploymentBackup(_ data: Data, expected: FactoryDeploymentIdentity) async throws {
        guard Self.isEncryptedBackup(data), data.count <= 16 * 1024 * 1024 else {
            throw ManagementError.invalid("待恢复的原厂包格式或大小不符合要求。")
        }
        guard try await deploymentIdentity() == expected else { throw ManagementError.deviceChanged }
        let boundary = "FlowDeck-" + UUID().uuidString
        var body = Data(
            ("--\(boundary)\r\nContent-Disposition: form-data; name=\"filename\"\r\n\r\n/tmp/back_parameter\r\n"
                + "--\(boundary)\r\nContent-Disposition: form-data; name=\"filedata\"; filename=\"back_parameter\"\r\n"
                + "Content-Type: application/octet-stream\r\n\r\n").utf8)
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var upload = URLRequest(url: URL(string: baseURL.absoluteString + "/cgi-bin%2fcgi-upload")!)
        upload.httpMethod = "POST"
        upload.timeoutInterval = 120
        upload.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        upload.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        upload.setValue(baseURL.absoluteString + "/", forHTTPHeaderField: "Referer")
        upload.httpBody = body
        let (responseData, response) = try await session.data(for: upload)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
            let value = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            value["sha256sum"] as? String == DeviceIdentity.digest(data)
        else { throw ManagementError.unconfirmed("原厂包上传摘要未确认，没有触发恢复。") }
        guard try await deploymentIdentity() == expected else { throw ManagementError.deviceChanged }
        _ = try await request("zwrt_mc.device.manager", "device_restore_proc", params: JSONObject(["procType": "web"]), token: token ?? "")
    }

    func login() async throws {
        guard !password.isEmpty else {
            throw ManagementError.invalid("请先填写原厂网页管理密码。")
        }
        let zero = String(repeating: "0", count: 32)
        let info = try await request("zwrt_web", "web_login_info", params: JSONObject(), token: zero)
        guard let salt = info.string("zte_web_sault") else {
            throw ManagementError.unsupported("原厂认证协议与已知 B28 不一致。")
        }
        let digest = Self.passwordDigest(password, salt: salt)
        let result = try await request("zwrt_web", "web_login", params: JSONObject(["password": digest]), token: zero)
        guard let token = result.string("ubus_rpc_session"), token != zero else {
            throw ManagementError.invalid("原厂管理密码验证失败。")
        }
        self.token = token
    }

    nonisolated static func passwordDigest(_ password: String, salt: String) -> String {
        let first = DeviceIdentity.digest(Data(password.utf8)).uppercased()
        return DeviceIdentity.digest(Data((first + salt).utf8)).uppercased()
    }

    func backup() async throws -> Data {
        try await login()
        _ = try await request("zwrt_mc.device.manager", "device_backup_proc", params: JSONObject(["procType": "web"]), token: token ?? "")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        var request = URLRequest(url: URL(string: baseURL.absoluteString + "/backu%70/back_parameter")!)
        request.setValue(baseURL.absoluteString + "/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, Self.isEncryptedBackup(data)
        else {
            throw ManagementError.unconfirmed("没有获取到有效的原厂加密备份。")
        }
        return data
    }
    /// OpenSSL 加盐 3DES 容器：16 字节头，后续密文为完整的 8 字节分组。
    nonisolated static func isEncryptedBackup(_ data: Data) -> Bool {
        data.count >= 24 && (data.count - 16) % 8 == 0 && data.starts(with: Data("Salted__".utf8))
    }

    /// PIN 错误会消耗 SIM 尝试次数。调用方必须确认，本方法不自动重试写入。
    nonisolated static func validatePIN(action: String, pin: String, newPIN: String, puk: String) throws {
        func validPIN(_ value: String) -> Bool {
            (4...8).contains(value.count)
                && value.utf8.allSatisfy {
                    (48...57).contains($0)
                }
        }
        guard ["enable", "disable", "change", "unlock", "puk"].contains(action), validPIN(pin),
            action != "change" || validPIN(newPIN),
            action != "puk"
                || (puk.count == 8
                    && puk.utf8.allSatisfy {
                        (48...57).contains($0)
                    })
        else {
            throw ManagementError.invalid("PIN 须为 4–8 位数字，PUK 须为 8 位数字。")
        }
    }

    func changePIN(action: String, pin: String, newPIN: String = "", puk: String = "") async throws {
        try Self.validatePIN(action: action, pin: pin, newPIN: newPIN, puk: puk)
        try await login()
        guard let token else {
            throw ManagementError.unconfirmed("原厂会话未建立。")
        }
        let certificate = try await request("zwrt_web", "web_crt_get", params: JSONObject(), token: token)
        guard let pem = certificate.string("result") else {
            throw ManagementError.unconfirmed("缺少原厂公钥。")
        }
        let key = try FactoryEncryption.randomBytes(count: 32)
        let wrapped = try FactoryEncryption.wrapKey(key, publicPEM: pem)
        _ = try await request("zwrt_web", "web_http_enstr_set", params: JSONObject(["web_enstr": wrapped]), token: token)
        func encrypted(_ value: String) throws -> String {
            try FactoryEncryption.encryptPIN(value, key: key, iv: FactoryEncryption.randomBytes(count: 16))
        }
        let method: String
        let params: [String: Any]
        switch action {
        case "change":
            method = "sim_change_pin"
            params = ["pin_num": try encrypted(pin), "new_pin_num": try encrypted(newPIN)]
        case "unlock", "puk":
            method = "sim_verify_pin_puk"
            params = ["pin_num": try encrypted(pin), "puk_num": action == "puk" ? try encrypted(puk) : ""]
        default:
            method = "sim_change_pin_mode"
            params = ["pin_num_m": try encrypted(pin), "pin_mode": action == "enable" ? 1 : 0]
        }
        let result = try await request("zwrt_zte_mdm.api", method, params: JSONObject(params), token: token)
        if let value = result.string("result"), !["0", "success"].contains(value) {
            throw ManagementError.unconfirmed("SIM 未接受请求，请刷新剩余次数后检查 PIN；不要重复尝试。")
        }
    }

    func reset() async throws {
        try await login()
        guard let token else {
            throw ManagementError.unconfirmed("原厂会话未建立。")
        }
        do {
            _ = try await request(
                "zwrt_mc.device.manager", "device_reset",
                params: JSONObject(["moduleName": "web", "resetFlag": 0]), token: token)
        } catch let error as URLError where [.timedOut, .networkConnectionLost].contains(error.code) {
            throw DeviceRequestUncertain()
        }
    }

}

/// 写入已发出但应答丢失，不能等同于认证拒绝或自动重试。
struct DeviceRequestUncertain: LocalizedError {
    var errorDescription: String? { "设备请求已发出，但应答未确认。请检查设备状态，不要重复提交。" }
}
