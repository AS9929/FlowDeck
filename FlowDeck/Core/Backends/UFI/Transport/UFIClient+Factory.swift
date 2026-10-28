import Foundation

/// F50 B09 原厂挑战认证及受控写入；共享 actor 会话，禁止自动重发 POST。
extension UFIClient {
    func wifiQuery(_ command: String, parameters: [URLQueryItem] = []) async throws -> JSONObject {
        try await request(
            "api/goform/goform_get_cmd_process",
            query: [
                URLQueryItem(name: "isTest", value: "false"),
                URLQueryItem(name: "cmd", value: command),
                URLQueryItem(name: "multi_data", value: "1"),
            ] + parameters + [
                // UFI 4.1.5 反向代理会重复附加 query；末尾保留无语义参数，防止污染 cmd。
                URLQueryItem(name: "_", value: String(Int64(Date().timeIntervalSince1970 * 1000)))
            ], cookie: factoryCookie)
    }

    /// 原厂挑战响应采用大写 SHA-256，与 UFI 自身的小写签名不同。
    nonisolated static func factoryDigest(_ value: String) -> String {
        DeviceIdentity.digest(Data(value.utf8)).uppercased()
    }

    func verifyWifiFirmware() async throws {
        let snapshot = try await identitySnapshot()
        guard DeviceCompatibility.supportsUFIWrite(snapshot) else {
            throw ManagementError.unsupported("原厂写入当前仅适配 F50 B09，其他固件请使用原厂网页。")
        }
    }

    /// 会话只在本客户端内存中保存，不写入 UFI 全局 Cookie，不重试失败密码。
    func authenticateFactory(password: String) async throws {
        _ = try await identitySnapshot()
        if factoryCookie != nil, factoryPasswordDigest == Self.factoryDigest(password),
            try await wifiQuery("loginfo").string("loginfo") == "ok"
        {
            return
        }
        factoryCookie = nil
        factoryPasswordDigest = nil
        guard !password.isEmpty else { throw ManagementError.invalid("请填写 F50 原厂网页后台密码。") }
        guard let challenge = try await wifiQuery("LD").string("LD"), !challenge.isEmpty else {
            throw ManagementError.unconfirmed("原厂后台没有返回登录挑战，请稍后重试。")
        }
        let result = try await request(
            "api/goform/goform_set_cmd_process",
            form: [
                "goformId": "LOGIN", "isTest": "false", "user": "admin",
                "password": Self.factoryDigest(Self.factoryDigest(password) + challenge),
            ])
        guard result.string("result") == "0", factoryCookie != nil,
            try await wifiQuery("loginfo").string("loginfo") == "ok"
        else {
            factoryCookie = nil
            throw ManagementError.invalid("原厂登录未通过，请核对网页后台密码；不要填写 Wi-Fi 密码或 UFI 口令。")
        }
        factoryPasswordDigest = Self.factoryDigest(password)
    }

    /// 读取芯片和接入点索引，不能用旧 SSID1 接口拼装双频设置。
    func readWifiAccessPoints(password: String) async throws -> [UFIWifiAccessPoint] {
        try await authenticateFactory(password: password)
        return try UFIWifiAccessPoint.parse(await wifiQuery("queryAccessPointInfo"))
    }

    /// 单次只写一个频段。检测其他客户端改动后终止，不自动覆盖，也不重发可能已生效的请求。
    func saveWifiAccessPoint(
        _ target: UFIWifiAccessPoint, replacing original: UFIWifiAccessPoint, password: String
    ) async throws {
        guard expectedFingerprint != nil, target.id == original.id else { throw ManagementError.deviceChanged }
        try target.validate()
        try await verifyWifiFirmware()
        let current = try await readWifiAccessPoints(password: password)
        guard current.first(where: { $0.id == original.id }) == original else {
            throw ManagementError.unconfirmed("设备上的 Wi-Fi 已被其他操作修改，请重新读取后再保存。")
        }
        let versions = try await wifiQuery("wa_inner_version,cr_version")
        guard let inner = versions.string("wa_inner_version"), !inner.isEmpty,
            let version = versions.string("cr_version"), !version.isEmpty,
            let challenge = try await wifiQuery("RD").string("RD"), !challenge.isEmpty
        else {
            throw ManagementError.unconfirmed("没有获得原厂写入校验信息，未提交 Wi-Fi 修改。")
        }
        var form = try target.form()
        form["AD"] = Self.factoryDigest(Self.factoryDigest(inner + version) + challenge)
        let result = try await request("api/goform/goform_set_cmd_process", form: form, cookie: factoryCookie)
        guard result.string("result") == "success" else {
            throw ManagementError.unconfirmed("原厂后台未确认 Wi-Fi 修改，请重新读取配置检查结果。")
        }
    }

    /// 原生设备页仅查询白名单字段，不下载 APN 密码、短信转发密钥或完整配置。
    func factoryDetails(password: String) async throws -> JSONObject {
        try await authenticateFactory(password: password)
        return try await wifiQuery(
            "modem_main_state,pin_status,pinnumber,puknumber,apn_mode,wan_apn_ui,profile_name_ui,pdp_type_ui,ConnectionMode,net_select,usb_network_protocal")
    }

    func readClients(password: String) async throws -> [LANClient] {
        try await authenticateFactory(password: password)
        return try UFIDeviceParser.clients(await wifiQuery("station_list,lan_station_list"))
    }

    func readClientAccess(password: String) async throws -> UFIClientAccess {
        try await authenticateFactory(password: password)
        return try UFIClientAccess(await wifiQuery("queryDeviceAccessControlList"))
    }

    /// 保留现有 ACL 策略，并在提交前重新确认调用方 IP，防止把正在管理的手机拉黑。
    func setClientBlocked(mac: String, name: String, blocked: Bool, replacing state: UFIClientAccess, password: String) async throws {
        let target = try state.changing(mac: mac, name: name, blocked: blocked)
        guard try await readClientAccess(password: password) == state else {
            throw ManagementError.unconfirmed("访问控制表已被修改，请刷新后重试。")
        }
        if blocked {
            let clients = try await readClients(password: password)
            let system = try await request("api/baseDeviceInfo")
            guard let address = system.string("client_ip"), clients.contains(where: { $0.ip == address }),
                let client = clients.first(where: { $0.mac.caseInsensitiveCompare(mac) == .orderedSame }),
                client.interface == "Wi-Fi", client.ip != address
            else {
                throw ManagementError.invalid("无法确认此设备不是当前管理终端，或它并非 Wi-Fi 终端，未拉黑。")
            }
        }
        var form = target.fields
        form["goformId"] = "setDeviceAccessControlList"
        try await submitFactory(form, password: password)
        guard try await readClientAccess(password: password) == target else {
            throw ManagementError.unconfirmed("访问控制已提交，回读尚未确认，请刷新检查。")
        }
    }

    /// 与 UFI 网页一致使用 tags=100 查询全部消息；不自动标记已读。
    func readMessages(page: Int, password: String) async throws -> [SMSMessage] {
        guard (0..<100).contains(page) else { throw ManagementError.invalid("短信页码无效。") }
        try await authenticateFactory(password: password)
        let result = try await wifiQuery(
            "sms_data_total",
            parameters: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "data_per_page", value: "20"),
                URLQueryItem(name: "mem_store", value: "1"),
                URLQueryItem(name: "tags", value: "100"),
                URLQueryItem(name: "order_by", value: "order by id desc"),
            ])
        return try UFIDeviceParser.messages(result)
    }

    /// 存储计数单独读取，用于区分真实空箱和列表协议异常。
    func messageStorage(password: String) async throws -> UFISMSStorage {
        try await authenticateFactory(password: password)
        return try UFISMSStorage(await wifiQuery("sms_capacity_info"))
    }

    /// 受控原厂动作。新鲜身份、固件和 AD 挑战均在提交前获取，不自动重试 POST。
    func performFactoryAction(_ action: UFIFactoryAction, password: String) async throws {
        try await submitFactory(try action.form(), password: password)
    }

    /// 只由类型化动作构造表单。提交前完成身份、固件和挑战校验，POST 永不自动重试。
    func submitFactory(_ fields: [String: String], password: String) async throws {
        guard expectedFingerprint != nil else { throw ManagementError.deviceChanged }
        try await verifyWifiFirmware()
        try await authenticateFactory(password: password)
        var form = fields
        form["isTest"] = "false"
        let versions = try await wifiQuery("wa_inner_version,cr_version")
        guard let inner = versions.string("wa_inner_version"), !inner.isEmpty,
            let outer = versions.string("cr_version"), !outer.isEmpty,
            let challenge = try await wifiQuery("RD").string("RD"), !challenge.isEmpty
        else {
            throw ManagementError.unconfirmed("未获得原厂写入校验信息，没有提交操作。")
        }
        form["AD"] = Self.factoryDigest(Self.factoryDigest(inner + outer) + challenge)
        let result = try await request("api/goform/goform_set_cmd_process", form: form, cookie: factoryCookie)
        guard result.string("result") == "success" else {
            throw ManagementError.unconfirmed("原厂后台未确认操作，请刷新检查；不会自动重复提交。")
        }
    }

    func readAPNs(password: String) async throws -> UFIAPNState {
        try await authenticateFactory(password: password)
        // B09 在查询 APN_config0 时返回完整槽位集合，包括 default_APN_size。
        return try UFIAPNState(await wifiQuery("APN_config0,ipv6_APN_config0,apn_mode,Current_index"))
    }

    /// 修改前比较整个列表；预置项禁止覆盖。原厂保存进入手动模式，页面提交前提示可能断网。
    func saveAPN(_ profile: UFIAPNProfile, replacing state: UFIAPNState, password: String) async throws {
        let form = try profile.form()
        guard profile.index >= state.presetCount,
            state.profiles.contains(where: { $0.index == profile.index }) || state.freeIndex == profile.index
        else { throw ManagementError.invalid("预置 APN 不可覆盖，或没有可用槽位。") }
        guard try await readAPNs(password: password) == state else {
            throw ManagementError.unconfirmed("APN 已被其他操作修改，请刷新后重试。")
        }
        try await submitFactory(form, password: password)
        let actual = try await readAPNs(password: password)
        guard let saved = actual.profiles.first(where: { $0.index == profile.index }),
            try saved.form() == form
        else { throw ManagementError.unconfirmed("已提交 APN，回读尚未确认，请刷新检查。") }
    }

    func selectAPN(_ profile: UFIAPNProfile?, from state: UFIAPNState, password: String) async throws {
        guard try await readAPNs(password: password) == state else {
            throw ManagementError.unconfirmed("APN 已变化，请刷新后重新选择。")
        }
        var form = ["goformId": "APN_PROC_EX", "apn_mode": profile == nil ? "auto" : "manual"]
        if let profile {
            guard state.profiles.contains(profile), ["IP", "IPv6", "IPv4v6"].contains(profile.protocolType) else {
                throw ManagementError.unsupported("此 APN 未提供完整协议类型，请使用自动模式。")
            }
            form.merge([
                "apn_action": "set_default", "set_default_flag": "1", "pdp_type": profile.protocolType,
                "index": String(profile.index),
            ]) { _, new in new }
        }
        try await submitFactory(form, password: password)
        let actual = try await readAPNs(password: password)
        guard actual.mode == (profile == nil ? "auto" : "manual"),
            profile == nil || actual.currentIndex == profile?.index
        else {
            throw ManagementError.unconfirmed("选择已提交，但回读尚未确认。若断网，可恢复自动 APN。")
        }
    }

    func deleteAPN(_ profile: UFIAPNProfile, from state: UFIAPNState, password: String) async throws {
        guard profile.index >= state.presetCount, state.profiles.contains(profile),
            state.mode == "auto" || (state.currentIndex != nil && state.currentIndex != profile.index)
        else {
            throw ManagementError.invalid("不能删除预置或正在使用的 APN，请先切换自动模式。")
        }
        guard try await readAPNs(password: password) == state else { throw ManagementError.deviceChanged }
        try await submitFactory(
            [
                "goformId": "APN_PROC_EX", "apn_action": "delete", "apn_mode": state.mode,
                "index": String(profile.index),
            ], password: password)
        guard try await readAPNs(password: password).profiles.allSatisfy({ $0.name != profile.name }) else {
            throw ManagementError.unconfirmed("删除尚未确认，请刷新检查。")
        }
    }

    func setRoaming(_ enabled: Bool, password: String) async throws {
        try await authenticateFactory(password: password)
        guard let mode = try await wifiQuery("ConnectionMode").string("connectionMode"),
            ["auto_dial", "manual_dial"].contains(mode)
        else {
            throw ManagementError.unconfirmed("未读取到连接模式，未修改漫游设置。")
        }
        try await submitFactory(
            [
                "goformId": "SET_CONNECTION_MODE", "ConnectionMode": mode,
                "roam_setting_option": enabled ? "on" : "off",
            ], password: password)
        guard try await wifiQuery("ConnectionMode").string("autoConnectWhenRoaming") == (enabled ? "on" : "off") else {
            throw ManagementError.unconfirmed("漫游设置尚未回读确认，请刷新检查。")
        }
    }

    func setNetworkMode(_ mode: UFINetworkMode, password: String) async throws {
        try await submitFactory(["goformId": "SET_BEARER_PREFERENCE", "BearerPreference": mode.rawValue], password: password)
        guard try await wifiQuery("net_select").string("net_select") == mode.rawValue else {
            throw ManagementError.unconfirmed("制式切换已提交，尚未确认生效，请稍后刷新。")
        }
    }

    func setUSBProtocol(_ mode: String, password: String) async throws {
        guard ["0", "1", "2"].contains(mode) else { throw ManagementError.invalid("无效的 USB 网络协议。") }
        try await submitFactory(["goformId": "SET_USB_NETWORK_PROTOCAL", "usb_network_protocal": mode], password: password)
        guard try await wifiQuery("usb_network_protocal").string("usb_network_protocal") == mode else {
            throw ManagementError.unconfirmed("USB 设置已提交，请等待电脑重新识别设备，再刷新确认。")
        }
    }

    func readClock() async throws -> String {
        _ = try await identitySnapshot()
        return try await shell("date +%s")
    }

    /// Android Toybox 支持 Unix 时间输入。仅同步系统时钟，不改时区、RTC 和自动校时开关。
    func synchronizeClock() async throws -> DiagnosticCheck {
        guard expectedFingerprint != nil else { throw ManagementError.deviceChanged }
        try await verifyWifiFirmware()
        try await checkedCommand(NetworkDiagnostics.clockSyncScript(date: Date()))
        let started = Date()
        let value = try await readClock()
        let result = NetworkDiagnostics.clockResult(value, started: started, finished: Date())
        guard result.outcome == .passed else {
            throw ManagementError.unconfirmed("校时已提交，回读尚未确认。" + result.detail)
        }
        return result
    }

    func operatePIN(_ operation: UFIPINOperation, pin: String, newPIN: String, puk: String, password: String) async throws {
        let form = try operation.form(pin: pin, newPIN: newPIN, puk: puk)
        try await authenticateFactory(password: password)
        let state = try await wifiQuery("pin_status,pinnumber,puknumber,modem_main_state")
        guard let remaining = state.int(operation == .unblock ? "puknumber" : "pinnumber"), remaining > 0 else {
            throw ManagementError.invalid("没有可用的 PIN/PUK 尝试次数，未提交。请联系运营商。")
        }
        try await submitFactory(form, password: password)
        let actual = try await wifiQuery("pin_status,pinnumber,puknumber,modem_main_state")
        let confirmed: Bool
        switch operation {
        case .enable, .change: confirmed = actual.int("pin_status") == 1
        case .disable: confirmed = actual.int("pin_status") == 0
        case .unlock, .unblock: confirmed = actual.string("modem_main_state") == "modem_init_complete"
        }
        guard confirmed else { throw ManagementError.unconfirmed("原厂已接受操作，状态尚未确认。请刷新，不要反复尝试密码。") }
    }

    /// 短信命令返回 success 只代表排队成功，还须轮询 sms_cmd 的最终状态。
    private func waitSMS(command: String) async throws {
        for _ in 0..<15 {
            try await Task.sleep(for: .seconds(1))
            let value = try await wifiQuery("sms_cmd_status_info", parameters: [URLQueryItem(name: "sms_cmd", value: command)])
            switch value.string("sms_cmd_status_result") {
            case "3": return
            case "2": throw ManagementError.unconfirmed("短信操作失败，请检查 SIM 与运营商状态；不会自动重发。")
            default: continue
            }
        }
        throw ManagementError.unconfirmed("未确认短信操作结果，请先检查设备，避免重复发送或删除。")
    }

    func sendMessage(number: String, text: String, password: String) async throws {
        let form = try UFISMSComposer.form(number: number, text: text)
        try await submitFactory(form, password: password)
        try await waitSMS(command: "4")
    }

    func deleteMessage(id: Int, password: String) async throws {
        guard id >= 0 else { throw ManagementError.invalid("短信编号无效。") }
        try await submitFactory(["goformId": "DELETE_SMS", "msg_id": "\(id);"], password: password)
        try await waitSMS(command: "6")
    }

    /// 双频共用 ChipEnum；禁止关闭最后一个热点，避免手机无法继续管理。
    func setWifiBands(_ chips: Set<String>, replacing points: [UFIWifiAccessPoint], password: String) async throws {
        guard !chips.isEmpty, chips.isSubset(of: ["0", "1"]), points.count == 2 else {
            throw ManagementError.invalid("至少保留一个 Wi-Fi 频段，且须读取完整双频状态。")
        }
        guard try await readWifiAccessPoints(password: password) == points else {
            throw ManagementError.unconfirmed("Wi-Fi 状态已变化，请刷新后重试。")
        }
        let value = chips.sorted().map { $0 == "0" ? "chip1" : "chip2" }.joined()
        try await submitFactory(["goformId": "switchWiFiChip", "ChipEnum": value, "GuestEnable": "0"], password: password)
        let actual = try await readWifiAccessPoints(password: password)
        guard Set(actual.filter(\.enabled).map(\.chip)) == chips else {
            throw ManagementError.unconfirmed("频段切换已提交，请重新连接热点后刷新确认。")
        }
    }

}
