import Foundation

extension WebSSHAPI {
    /// 旧测试替身可以不实现扩展能力；真实 UI 明确显示不支持，绝不返回伪造成功。
    func rpc(_ service: String, _ method: String, params: JSONObject) async throws -> JSONObject {
        throw ManagementError.unsupported("此管理通道没有提供 \(service).\(method)")
    }

    func management(_ method: String, _ path: String, body: JSONObject?) async throws -> JSONObject {
        throw ManagementError.unsupported("此管理通道没有提供该维护接口。")
    }

    func read(_ service: String, _ method: String) async throws -> JSONObject {
        try await rpc(service, method, params: JSONObject())
    }

    /// WebSSH 对每次 ubus 调用固定 5 秒超时（gossh/app/utils/ubus.go），大文件摘要、解压或 mm.sh 启停会被中途杀掉，
    /// 而设备上的脚本可能仍在继续。这里先在设备后台启动脚本，再逐次轮询结束标记；
    /// 同名任务仍在运行时只继续等待，不重复启动。返回脚本输出的末尾部分；非零退出、进程消失和超时都明确失败。
    func runBackgroundScript(
        directory: String, name: String, title: String, script: String,
        timeout: Duration = .seconds(300), pollInterval: Duration = .seconds(1)
    ) async throws -> String {
        let launch = try await runMaintenanceScript(BackgroundJob.launchScript(directory: directory, name: name, script: script))
        guard launch.contains("FLOWDECK_JOB_STARTED") || launch.contains("FLOWDECK_JOB_RUNNING") else {
            throw ManagementError.unconfirmed("设备未能启动后台任务：" + title)
        }
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            try Task.checkCancellation()
            let output = try await runMaintenanceScript(BackgroundJob.pollScript(directory: directory, name: name))
            let lines = output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let head = lines.first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            if head.hasPrefix("FLOWDECK_JOB_DONE ") {
                let body = lines.count > 1 ? String(lines[1]) : ""
                guard Int(head.dropFirst("FLOWDECK_JOB_DONE ".count)) == 0 else {
                    let detail = body.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200)
                    throw ManagementError.unconfirmed(title + "未通过" + (detail.isEmpty ? "。" : "：" + detail))
                }
                return body
            }
            if head == "FLOWDECK_JOB_LOST" {
                throw ManagementError.unconfirmed(title + "意外中断，请检查设备状态后重试。")
            }
            guard clock.now < deadline else {
                throw ManagementError.unconfirmed(title + "等待超时，设备可能仍在处理，请稍后检查。")
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    /// 仅供下面固定维护脚本使用；固件没有 rpcd file.exec 时失败，不降级到不受控通道。
    func runMaintenanceScript(_ script: String) async throws -> String {
        let result = try await rpc("file", "exec", params: JSONObject(["command": "/bin/sh", "params": ["-c", script]]))
        guard result.int("code") == 0 else {
            throw ManagementError.unconfirmed("设备未完成维护命令，请检查固件能力和管理权限。")
        }
        return result.string("stdout") ?? ""
    }

    func readWifiNetworks() async throws -> [WifiNetwork] {
        let values = try await rpc("uci", "get", params: JSONObject(["config": "wireless"])).object("values")
        return try ["main_2g", "main_5g"].map { section in
            guard let item = values?.object(section), let ssid = item.string("ssid"), let password = item.string("key") else {
                throw ManagementError.unsupported("固件未提供完整 Wi-Fi 配置。")
            }
            let radio = section == "main_2g" ? "wifi0" : "wifi1"
            return WifiNetwork(
                id: section, ssid: ssid, password: password, hidden: item.string("hidden") == "1",
                enabled: values?.object(radio)?.string("disabled") != "1",
                channel: (values?.object(radio)?.string("channel") == "0" ? "auto" : values?.object(radio)?.string("channel")) ?? "auto",
                encryption: item.string("encryption") ?? "psk2")
        }
    }

    /// 先逐项校验。保存失败时回写旧值；Wi-Fi 重载可能断开 HTTP，由上层重连并回读确认。
    func saveWifiNetworks(_ networks: [WifiNetwork]) async throws {
        guard networks.count == 2, Set(networks.map(\.id)) == ["main_2g", "main_5g"], networks.contains(where: \.enabled) else {
            throw ManagementError.invalid("至少保留一个 Wi-Fi 频段开启。")
        }
        for network in networks {
            try network.validate()
        }
        try await requireCleanWirelessTransaction()
        let previous = try await readWifiNetworks()
        do {
            try await stageWifi(networks)
            _ = try await rpc("uci", "commit", params: JSONObject(["config": "wireless"]))
        } catch {
            do {
                try await stageWifi(previous)
                _ = try await rpc("uci", "commit", params: JSONObject(["config": "wireless"]))
            } catch {
                throw ManagementError.unconfirmed("Wi-Fi 保存失败，恢复旧值也未得到确认，请通过设备屏幕检查。")
            }
            throw error
        }
        _ = try await read("zwrt_wlan", "reload")
    }

    private func requireCleanWirelessTransaction() async throws {
        let result = try await rpc("uci", "changes", params: JSONObject(["config": "wireless"]))
        let changes = result.raw["changes"]
        let clean = (changes as? [String: Any])?.isEmpty == true || (changes as? [Any])?.isEmpty == true
        guard clean else {
            throw ManagementError.unconfirmed("设备有其他未提交的 Wi-Fi 修改，请先在原管理页面保存或撤销。")
        }
    }

    private func stageWifi(_ networks: [WifiNetwork]) async throws {
        for network in networks {
            _ = try await rpc(
                "uci", "set",
                params: JSONObject([
                    "config": "wireless", "section": network.id,
                    "values": ["ssid": network.ssid, "key": network.password, "hidden": network.hidden ? "1" : "0"],
                ]))
            _ = try await rpc(
                "uci", "set",
                params: JSONObject([
                    "config": "wireless", "section": network.radio,
                    "values": ["disabled": network.enabled ? "0" : "1", "channel": network.channel == "auto" ? "0" : network.channel],
                ]))
        }
    }

    func sendSMS(number: String, message: String) async throws {
        try SMSValidation.validate(number: number, message: message)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yy;MM;dd;HH;mm;ss"
        let offset = Double(TimeZone.current.secondsFromGMT()) / 3600
        let timestamp = formatter.string(from: Date()) + String(format: ";%+g", offset)
        let payload: [String: Any] = [
            "number": number, "sms_time": timestamp, "id": "-1",
            "message_body": message.utf16.map {
                String(format: "%04X", $0)
            }.joined(),
            "encode_type": "UNICODE",
        ]
        _ = try await rpc("zwrt_wms", "zte_libwms_send_sms", params: JSONObject(payload))
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 500_000_000)
            let result = try await rpc("zwrt_wms", "zwrt_wms_get_cmd_status", params: JSONObject(["sms_cmd": 4]))
            switch result.int("sms_cmd_status_result") {
            case 3: return
            case 2: throw ManagementError.unconfirmed("设备报告短信发送失败。")
            default: continue
            }
        }
        throw ManagementError.unconfirmed("发送状态尚未确认，请检查发件箱，勿重复发送。")
    }

    func coreVersion() async throws -> CoreUpdateInfo {
        let value = try await management("GET", "api/mihomo/binary/version", body: nil).object("data")
        return CoreUpdateInfo(
            current: value?.string("local_version") ?? "未知", latest: value?.string("remote_version") ?? "未知",
            available: value?.bool("has_update") ?? false)
    }

    func coreDirectory() async throws -> String {
        let value = try await management("GET", "api/mihomo/dir", body: nil)
        guard let path = value.object("data")?.string("mihomo_dir"),
            path.hasPrefix("/"), !path.contains(".."), !path.contains("\n")
        else {
            throw ManagementError.unconfirmed("无法确认核心安装目录。")
        }
        return path
    }

    func rollbackCore() async throws {
        let state = try await management("GET", "api/mihomo/install/status", body: nil).object("data")?.string("state")
        guard ["idle", "done", "failed", "canceled"].contains(state ?? "") else {
            throw ManagementError.unconfirmed("安装任务未确认结束，暂不能回滚核心。")
        }
        let directory = try await coreDirectory()
        let quoted = ShellValue.quote(directory)
        // 摘要 57 MB 核心、mihomo -t 及 mm.sh 启停（加载 IP 段约 30 秒）远超单次调用 5 秒上限，走后台任务。
        _ = try await runBackgroundScript(
            directory: directory + "/.flowdeck-jobs", name: "rollback-core", title: "核心回滚",
            script: """
            set -eu
            cd \(quoted)
            test -s mihomo.u60-before-update
            sha256sum -c mihomo.u60-before-update.sha256 >/dev/null
            ./mihomo.u60-before-update -t -d . >/dev/null 2>&1
            cp -p mihomo mihomo.failed
            cp -p mihomo.u60-before-update mihomo.restore-candidate
            chmod 755 mihomo.restore-candidate
            was_running=0
            if test -s mihomo.pid && kill -0 "$(cat mihomo.pid)" 2>/dev/null; then was_running=1; fi
            recover_previous() {
                trap - EXIT HUP INT TERM
                # 恢复路径不能再被 set -e 中断：复制失败也要按原状态重新启动代理。
                set +e
                sh ./mm.sh stop >/dev/null 2>&1
                if cp -p mihomo.failed mihomo.recovery-candidate; then mv mihomo.recovery-candidate mihomo; fi
                if test "$was_running" -eq 1; then sh ./mm.sh start; fi
                exit 1
            }
            trap recover_previous EXIT HUP INT TERM
            sh ./mm.sh stop
            mv mihomo.restore-candidate mihomo
            if test "$was_running" -eq 1; then sh ./mm.sh start; fi
            trap - EXIT HUP INT TERM
            """)
    }

    /// 只修改 Wi-Fi 的 deny 列表；已有 allow 列表时拒绝覆盖，避免影响其他接入设备。
    func setClientBlocked(mac: String, blocked: Bool) async throws {
        guard mac.range(of: "^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$", options: .regularExpression) != nil else {
            throw ManagementError.invalid("客户端 MAC 格式无效。")
        }
        try await requireCleanWirelessTransaction()
        let before = try await rpc("uci", "get", params: JSONObject(["config": "wireless"])).object("values")
        var changes: [(String, [String], String)] = []
        for section in ["main_2g", "main_5g"] {
            guard let entry = before?.object(section) else {
                throw ManagementError.unsupported("固件没有该 Wi-Fi 接口。")
            }
            let mode = entry.string("macfilter") ?? "disable"
            guard ["disable", "disabled", "deny", "0"].contains(mode) else {
                throw ManagementError.unsupported("设备已使用白名单，不能直接覆盖为黑名单。")
            }
            changes.append((section, entry.strings("denymaclist"), mode))
        }
        do {
            for (section, list, _) in changes {
                var addresses = Set(
                    list.map {
                        $0.uppercased()
                    })
                if blocked {
                    addresses.insert(mac.uppercased())
                } else {
                    addresses.remove(mac.uppercased())
                }
                _ = try await rpc(
                    "uci", "set",
                    params: JSONObject([
                        "config": "wireless", "section": section,
                        "values": ["macfilter": "deny", "denymaclist": addresses.sorted()],
                    ]))
            }
            _ = try await rpc("uci", "commit", params: JSONObject(["config": "wireless"]))
        } catch {
            for (section, list, mode) in changes {
                _ = try? await rpc(
                    "uci", "set",
                    params: JSONObject([
                        "config": "wireless", "section": section,
                        "values": ["macfilter": mode, "denymaclist": list],
                    ]))
            }
            _ = try? await rpc("uci", "commit", params: JSONObject(["config": "wireless"]))
            throw error
        }
        _ = try await read("zwrt_wlan", "reload")
        let actual = try await blockedClients()
        guard actual.contains(mac.uppercased()) == blocked else {
            throw ManagementError.unconfirmed("已提交，但黑名单回读不符。")
        }
    }

    func blockedClients() async throws -> Set<String> {
        let values = try await rpc("uci", "get", params: JSONObject(["config": "wireless"])).object("values")
        return Set(
            ["main_2g", "main_5g"].flatMap { section in
                values?.object(section)?.string("macfilter") == "deny" ? values?.object(section)?.strings("denymaclist") ?? [] : []
            }.map { $0.uppercased() })
    }
}

/// Shell 仅用于固定设备维护脚本；所有动态值按 POSIX 单引号编码。
/// 设备后台任务脚本。子进程的输入输出都重定向，rpcd 不必等它结束；
/// 结束码先写临时文件再改名，轮询不会读到半截状态。名称只用内部固定值。
enum BackgroundJob {
    static func launchScript(directory: String, name: String, script: String) -> String {
        """
        set -eu
        umask 077
        mkdir -p \(ShellValue.quote(directory))
        cd \(ShellValue.quote(directory))
        test ! -L '\(name).sh'
        if test -f '\(name).pid' && kill -0 "$(cat '\(name).pid')" 2>/dev/null; then echo FLOWDECK_JOB_RUNNING; exit 0; fi
        rm -f '\(name).done' '\(name).done.tmp' '\(name).out'
        printf '%s\\n' \(ShellValue.quote(script)) > '\(name).sh'
        ( trap '' HUP; if sh '\(name).sh' > '\(name).out' 2>&1; then code=0; else code=$?; fi; echo "$code" > '\(name).done.tmp'; mv '\(name).done.tmp' '\(name).done'; rm -f '\(name).pid' ) </dev/null >/dev/null 2>&1 &
        echo $! > '\(name).pid'
        echo FLOWDECK_JOB_STARTED
        """
    }

    static func pollScript(directory: String, name: String) -> String {
        """
        cd \(ShellValue.quote(directory)) 2>/dev/null || { echo FLOWDECK_JOB_LOST; exit 0; }
        if test -f '\(name).done'; then
            printf 'FLOWDECK_JOB_DONE %s\\n' "$(cat '\(name).done')"
            tail -c 4000 '\(name).out' 2>/dev/null || true
        elif test -f '\(name).pid' && kill -0 "$(cat '\(name).pid')" 2>/dev/null; then
            echo FLOWDECK_JOB_PENDING
        else
            echo FLOWDECK_JOB_LOST
        fi
        """
    }
}

enum ShellValue {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum SMSValidation {
    static func validate(number: String, message: String) throws {
        guard !number.isEmpty, number.count <= 32, number.allSatisfy({ "0123456789+*#".contains($0) }) else {
            throw ManagementError.invalid("号码只能包含数字、+、*、#，最多 32 位。")
        }
        guard (1...70).contains(message.utf16.count), !message.contains("\0") else {
            throw ManagementError.invalid("请输入最多 70 个 UTF-16 单元的单条短信。")
        }
    }
}
