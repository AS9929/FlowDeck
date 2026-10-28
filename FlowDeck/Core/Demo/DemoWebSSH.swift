import Foundation

/// 演示用的 WebSSH：数据为示例，所有修改只改内存。
actor DemoWebSSH: WebSSHAPI {
    static let shared = DemoWebSSH()

    private var demoPowerSaving = "on"
    private var demoForwardConfig = JSONObject([
        "bark_enabled": false, "bark_url": "", "bark_group": "短信", "tg_enabled": false, "tg_bot_token": "", "tg_chat_id": "", "last_id": 0,
    ])
    private var demoForwardRunning = false
    private var demoForwardAutostart = false
    private var rebooted = false
    private var demoCoreVersion = "v1.19.32"
    private var chargeStopped = false
    private var apnMode = 0
    private var selectedAPN = "1"
    private var roaming = false
    private var pinEnabled = false
    private var usb = "storage"
    private var lteBands = NetworkMode.lteBands
    private var nrBands = NetworkMode.nrBands
    private var apnList: [[String: Any]] = [["profileId": "1", "profilename": "中国移动", "wanapn": "cmnet", "pdpType": 3, "pppAuthMode": 0]]
    private var adminWireless: [String: Any] = [
        "main_2g": ["ssid": "U60-Travel", "key": "example-pass", "hidden": "0", "encryption": "psk2", "macfilter": "disable", "denymaclist": []]
            as [String: Any],
        "main_5g": ["ssid": "U60-Travel-5G", "key": "example-pass", "hidden": "0", "encryption": "psk2", "macfilter": "disable", "denymaclist": []]
            as [String: Any],
        "wifi0": ["disabled": "0", "channel": "auto"], "wifi1": ["disabled": "0", "channel": "auto"],
    ]

    func rpc(_ service: String, _ method: String, params: JSONObject) async throws -> JSONObject {
        await pause(50)
        switch (service, method) {
        case ("uci", "changes"):
            return JSONObject(["changes": [:]])
        case ("uci", "get"):
            return JSONObject(["values": adminWireless])
        case ("uci", "set"):
            if let section = params.string("section"), let updates = params.object("values") {
                var current = adminWireless[section] as? [String: Any] ?? [:]
                current.merge(updates.raw) { _, new in new }
                adminWireless[section] = current
            }
            return JSONObject()
        case ("uci", "commit"), ("zwrt_wlan", "reload"):
            return JSONObject()
        case ("zwrt_wms", "zte_libwms_send_sms"):
            return JSONObject()
        case ("zwrt_wms", "zwrt_wms_get_cmd_status"):
            return JSONObject(["sms_cmd_status_result": 3])
        case ("zwrt_bsp.charger", "list"):
            return JSONObject(["direct_power_supply_mode": chargeStopped ? "enable" : "disable"])
        case ("zwrt_bsp.charger", "set"):
            chargeStopped = params.string("direct_power_supply_mode") == "enable"
            return JSONObject()
        case ("zwrt_apn_object", "get_apn_mode"):
            return JSONObject(["apn_mode": apnMode])
        case ("zwrt_apn_object", "set_apn_mode"):
            apnMode = params.int("apn_mode") ?? 0
            return JSONObject()
        case ("zwrt_apn_object", "get_manu_apn_list"):
            return JSONObject(["apnListArray": apnList])
        case ("zwrt_apn_object", "get_enabled_manu_apn_id"):
            return JSONObject(["profileId": selectedAPN])
        case ("zwrt_apn_object", "enable_manu_apn_id"):
            selectedAPN = params.string("profileId") ?? "1"
            return JSONObject()
        case ("zwrt_apn_object", "add_manu_apn"), ("zwrt_apn_object", "modify_manu_apn"):
            var values = params.raw
            if let id = params.string("profileId") {
                apnList.removeAll { $0["profileId"] as? String == id }
            } else {
                values["profileId"] = UUID().uuidString
            }
            apnList.append(values)
            return JSONObject()
        case ("zwrt_apn_object", "delete_manu_apn"):
            apnList.removeAll { $0["profileId"] as? String == params.string("profileId") }
            return JSONObject()
        case ("u60.demo", "set_pin"):
            if params.string("action") == "enable" { pinEnabled = true }
            if params.string("action") == "disable" { pinEnabled = false }
            return JSONObject()
        case ("zwrt_zte_mdm.api", "get_sim_info"):
            return JSONObject(["pin_status": pinEnabled ? "1" : "0", "pinnumber": "3", "puknumber": "10"])
        case ("zwrt_data", "get_wwaniface"):
            return JSONObject(["connect_mode": 1, "roam_enable": roaming ? 1 : 0])
        case ("zwrt_data", "set_wwaniface"):
            roaming = params.int("roam_enable") == 1
            return JSONObject()
        case ("zte_nwinfo_api", "nwinfo_get_netinfo"):
            return JSONObject([
                "net_select": mode.rawValue, "lte_band_lock": BandSelection.mask(lteBands), "lte_band": lteBands.map(String.init).joined(separator: ","),
                "nr5g_sa_band_lock": nrBands.map(String.init).joined(separator: ","),
            ])
        case ("file", "exec"):
            let script = params.strings("params").last ?? ""
            // 后台任务：启动时按内层脚本模拟，首次轮询即完成。
            if script.contains("FLOWDECK_JOB_PENDING") {
                return JSONObject(["code": 0, "stdout": "FLOWDECK_JOB_DONE 0\n"])
            }
            if script.contains("cp -p mihomo.u60-before-update mihomo") { demoCoreVersion = "v1.19.32" }
            if script.contains("FLOWDECK_JOB_STARTED") {
                return JSONObject(["code": 0, "stdout": "FLOWDECK_JOB_STARTED"])
            }
            if script.contains("ln -s ../../functions/gsi.ecm") { usb = "ecm" }
            if script.contains("ln -s ../../functions/gsi.rndis") { usb = "rndis" }
            let output = script.contains("date +%s") ? String(Int(Date().timeIntervalSince1970)) : script.contains("readlink") ? "functions/gsi.\(usb)" : ""
            return JSONObject(["code": 0, "stdout": output])
        default:
            throw ManagementError.unsupported("演示数据尚未提供此项能力：\(service).\(method)")
        }
    }

    func management(_ method: String, _ path: String, body: JSONObject?) async throws -> JSONObject {
        await pause(100)
        switch path {
        case "api/wifi/psm/get":
            return JSONObject(["data": ["wlan0_psm": demoPowerSaving, "wlan1_psm": demoPowerSaving]])
        case "api/wifi/psm/set":
            demoPowerSaving = body?.string("mode") ?? "on"
            return JSONObject(["code": 0])
        case "api/system/sms-forward/config":
            demoForwardConfig = body ?? demoForwardConfig
            return JSONObject(["code": 0])
        case "api/system/sms-forward/control":
            demoForwardRunning = body?.string("action") != "stop"
            return JSONObject(["code": 0])
        case "api/system/sms-forward/autostart":
            demoForwardAutostart = body?.bool("enabled") ?? false
            return JSONObject(["code": 0])
        case "api/system/sms-forward/status":
            return JSONObject([
                "data": ["config": demoForwardConfig.raw, "running": demoForwardRunning, "autostart_enabled": demoForwardAutostart, "sent_count": 0]
            ])
        case "api/mihomo/binary/version":
            return JSONObject(["data": ["local_version": demoCoreVersion, "remote_version": "v1.19.33", "has_update": demoCoreVersion != "v1.19.33"]])
        case "api/mihomo/dir":
            return JSONObject(["data": ["mihomo_dir": "/demo/mihomo"]])
        case "api/mihomo/install":
            demoCoreVersion = "v1.19.33"
            return JSONObject(["data": ["state": "downloading"]])
        case "api/mihomo/install/status":
            return JSONObject(["data": ["state": "done", "msg": "演示更新完成", "percent": 100]])
        case "api/update/run":
            return JSONObject(["code": 0])
        case "api/update/status":
            return JSONObject(["data": ["state": "done", "percent": 100]])
        case "api/update/version":
            return JSONObject(["data": ["current_version": "20260909", "latest_version": "20260909"]])
        default:
            throw ManagementError.unsupported("演示数据不支持此接口。")
        }
    }

    private var running = true
    private var autostart = true
    private var config = """
        # 演示配置
        mixed-port: 7893
        mode: rule
        external-controller: 192.168.0.1:9090
        secret: demo-secret
        proxies:
        - {name: "🇯🇵 [华为沪日] | IDCF 东一", type: ss, server: "203.0.113.10", port: 40005, cipher: "aes-128-gcm", password: "demo", udp: true, tfo: false}
        proxy-groups:
        - name: Proxies
          type: select
          proxies: ["🇯🇵 [华为沪日] | IDCF 东一"]
        rule-providers:
          china:
            type: file
            behavior: classical
            format: text
            path: ./rule_provider/china.list
        rules:
        - RULE-SET,china,DIRECT
        - MATCH,Proxies
        dns:
          listen: 0.0.0.0:1053

        """
    private var update = DataUpdateStatus(state: "idle", message: "暂无更新任务")
    private var updateStarted: Date?
    private var messages: [SMSMessage] = [
        SMSMessage(id: 3, number: "10086", date: "2026 年 10 月 04 日 09:12:00", content: "【示例】您本月套餐内通用流量已使用 62%，剩余 38.1 GB。", tag: "1"),
        SMSMessage(id: 2, number: "10086", date: "2026 年 10 月 03 日 18:40:11", content: "【示例】您的话费余额为 48.20 元。", tag: "1"),
        SMSMessage(id: 1, number: "106900000000", date: "2026 年 10 月 02 日 08:03:27", content: "【示例】验证码 381946，5 分钟内有效。", tag: "0"),
    ]
    private var wifi = ["wifi0": WifiRadioSettings(txPower: "100", country: "CN"), "wifi1": WifiRadioSettings(txPower: "100", country: "CN")]
    private var mode: NetworkMode = .auto

    private func pause(_ ms: UInt64 = 200) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

    func mihomoStatus() async throws -> MihomoServiceStatus {
        await pause()
        return MihomoServiceStatus(
            running: running, pid: running ? 2481 : nil, startTime: running ? "2026-10-04 08:31:02" : nil,
            binaryVersion: "Mihomo Meta v1.19.32 linux arm64", apiReachable: running, autostart: autostart)
    }

    func control(_ action: ProxyAction) async throws -> String {
        await pause(action == .stop ? 600 : 1800)
        switch action {
        case .start, .restart: running = true
        case .stop: running = false
        case .reloadIPSet: break
        }
        return "[演示] mm.sh \(action.rawValue) 完成"
    }

    func setAutostart(_ enabled: Bool) async throws { autostart = enabled }

    func connectivity() async throws -> Bool { running }

    func loadConfig() async throws -> String { config }

    func saveConfig(_ content: String) async throws { config = content }

    func checkConfig() async throws -> ConfigCheckResult {
        await pause(600)
        if config.contains("USER-AGENT") {
            return ConfigCheckResult(ok: false, message: "配置校验未通过", output: "rules[12] [USER-AGENT,...] error: unsupported rule type USER-AGENT")
        }
        return ConfigCheckResult(ok: true, message: "配置有效", output: "configuration file config.yaml test is successful")
    }

    func dataVersion() async throws -> DataVersion {
        await pause(500)
        return DataVersion(local: "202609280012", remote: "202610040012", hasUpdate: true)
    }

    func startDataUpdate() async throws -> DataUpdateStatus {
        updateStarted = Date()
        update = DataUpdateStatus(state: "downloading", message: "正在下载", fileName: "GeoSite.dat", fileIndex: 1, fileTotal: 4, percent: 0)
        return update
    }

    func dataUpdateStatus() async throws -> DataUpdateStatus {
        guard let start = updateStarted else { return update }
        let p = min(100, Int(Date().timeIntervalSince(start) * 18))
        let names = ["GeoSite.dat", "geoip.metadb", "chnroute.txt", "chnroute6.txt"]
        if p >= 100 {
            update = DataUpdateStatus(state: "done", message: "更新完成", fileIndex: 4, fileTotal: 4, percent: 100)
            updateStarted = nil
        } else {
            let idx = min(3, p / 25)
            update = DataUpdateStatus(state: "downloading", message: "正在下载", fileName: names[idx], fileIndex: idx + 1, fileTotal: 4, percent: p)
        }
        return update
    }

    func snapshot() async throws -> DeviceSnapshot {
        await pause()
        var s = DeviceSnapshot()
        s.operatorName = "中国移动"
        s.networkType = "SA"
        s.isNR = true
        s.signalBars = 4
        s.rsrp = -94 + Double.random(in: -2...2).rounded()
        s.rsrq = -11
        s.sinr = 18
        s.band = mode == .lteOnly || mode == .lte3g ? "3" : "78"
        if mode == .lteOnly || mode == .lte3g {
            s.isNR = false
            s.networkType = "LTE"
        }
        s.pci = "412"
        s.channel = "627264"
        s.netSelect = mode.rawValue
        s.wanIPv4 = "10.74.18.203"
        s.connected = true
        s.rxSpeed = Int64.random(in: 2_000_000...6_000_000)
        s.txSpeed = Int64.random(in: 200_000...700_000)
        s.dayRx = 1_284_000_000
        s.dayTx = 84_000_000
        s.monthRx = 62_400_000_000
        s.monthTx = 3_100_000_000
        s.battery = 94
        s.charging = true
        s.batteryTemp = 33
        s.uptime = rebooted ? 5 : 11_520
        s.cpuTemp = 41
        s.memTotalKB = 1_919_000
        s.memAvailKB = 1_102_000
        s.imei = "868000001234567"
        s.iccid = "89860000000000003721"
        s.imsi = "460000000003721"
        s.model = "MU5250"
        s.marketName = "U60 Pro"
        s.firmware = "BD_FLYMODEMMU5250V1.0.0B28"
        s.integrateVersion = "FLY_CN_MU5250V1.0.0B13"
        s.hardware = "MU5250_HW1.0"
        s.ssid24 = (adminWireless["main_2g"] as? [String: Any])?["ssid"] as? String
        s.ssid5 = (adminWireless["main_5g"] as? [String: Any])?["ssid"] as? String
        s.radio24On = true
        s.radio5On = true
        s.clientsTotal = 4
        s.clientsWifi = 3
        s.clientsLan = 1
        return s
    }

    func clients() async throws -> [LANClient] {
        await pause()
        return [
            LANClient(
                hostname: "iPhone", ip: "192.168.0.105", mac: "A2:11:3C:00:00:01", interface: "5G", signal: -48, rateKbps: 866_700, accessTime: "02:41:10"),
            LANClient(
                hostname: "MacBook-Pro", ip: "192.168.0.161", mac: "6E:22:00:00:00:02", interface: "Ethernet", signal: nil, rateKbps: nil,
                accessTime: "03:12:44"),
            LANClient(hostname: "iPad", ip: "192.168.0.118", mac: "B6:33:00:00:00:03", interface: "5G", signal: -61, rateKbps: 433_300, accessTime: "00:52:03"),
            LANClient(
                hostname: "未命名设备", ip: "192.168.0.140", mac: "3C:44:00:00:00:04", interface: "2.4G", signal: -72, rateKbps: 72_200, accessTime: "00:05:31"),
        ]
    }

    func sms() async throws -> [SMSMessage] { messages }

    func markSMSRead(id: Int) async throws {
        if let i = messages.firstIndex(where: { $0.id == id }) { messages[i].tag = "0" }
    }

    func wifiSettings() async throws -> [String: WifiRadioSettings] { wifi }

    func setWifi(_ settings: [String: WifiRadioSettings]) async throws {
        for (k, v) in settings { wifi[k] = v }
    }

    func setNetworkMode(_ mode: NetworkMode) async throws { self.mode = mode }

    func lockLTEBands(_ bands: [Int]) async throws {
        lteBands = bands
        await pause(400)
    }

    func lockNRBands(_ bands: [Int]) async throws {
        nrBands = bands
        await pause(400)
    }

    func reboot() async throws {
        rebooted = true
        await pause(500)
    }
}
