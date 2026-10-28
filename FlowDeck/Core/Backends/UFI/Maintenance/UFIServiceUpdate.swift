import Foundation

/// 只检索作者完整版 WEB APK 目录，排除手机端 PE/独立版及其他同名 APK。
struct UFIServiceRelease: Sendable {
    let name: String
    let size: Int
    let version: String
    var url: URL { URL(string: "https://pan.kanokano.cn/d/UFI-TOOLS-UPDATE/" + name)! }

    static func latest() async throws -> Self {
        var request = URLRequest(url: URL(string: "https://pan.kanokano.cn/api/fs/list")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "path": "/UFI-TOOLS-UPDATE", "password": "", "page": 1, "per_page": 0, "refresh": false,
        ])
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let object = JSONObject(data: data),
            object.int("code") == 200, let rows = object.object("data")?.raw["content"] as? [[String: Any]]
        else {
            throw ManagementError.unconfirmed("作者更新目录暂不可用，请稍后重试或导入已下载的完整版 APK。")
        }
        return try parse(rows)
    }

    static func parse(_ rows: [[String: Any]]) throws -> Self {
        let values = rows.compactMap { row -> Self? in
            guard row["is_dir"] as? Bool == false, let name = row["name"] as? String,
                name.range(of: "^UFI-TOOLS_WEB_V[0-9]+\\.[0-9]+\\.[0-9]+_[0-9]{8}_[0-9]{4}\\.apk$", options: .regularExpression) != nil,
                let size = row["size"] as? Int, (1...UFIPackageTransfer.maximumBytes).contains(size)
            else { return nil }
            let version = String(name.dropFirst("UFI-TOOLS_WEB_V".count).split(separator: "_")[0])
            return Self(name: name, size: size, version: version)
        }
        guard let latest = values.max(by: { $0.name.compare($1.name, options: .numeric) == .orderedAscending }) else {
            throw ManagementError.unconfirmed("作者目录未提供受支持的完整版 APK。")
        }
        return latest
    }

    func download() async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
            try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize == size
        else {
            throw ManagementError.unconfirmed("APK 下载大小不符，未准备安装。")
        }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let data = try Data(contentsOf: temporary)
        try data.write(to: target, options: .atomic)
        return target
    }
}

struct UFIServicePackage: Sendable {
    let path: String
    let checksum: String
    let version: String
    let code: Int
    let installedCode: Int
}

struct UFIServiceUpdateState: Sendable {
    let version: String
    let status: String
    let backup: Bool
    var needsRecovery: Bool { ["interrupted", "orphaned", "recovery-required"].contains(status) }
    var running: Bool { ["starting", "installing", "reconnecting", "recovering"].contains(status) }
}

/// 更新脚本在 root 会话独立执行，APK 替换中管理端断开不会终止事务。
/// 回退只尝试 Android 允许的覆盖安装，不卸载、不清数据、不绕过签名或降级保护。
enum UFIServiceUpdateScript {
    static let root = UFIPackageTransfer.directory
    static func make(package: UFIServicePackage?, helper: String) throws -> String {
        let rollback = package == nil
        let source = try package.map { try UFIPackageTransfer.path(checksum: $0.checksum) } ?? root + "/ufi.previous.apk"
        guard helper.range(of: "^/data/local/flowdeck-config/bridge-[a-f0-9]{64}\\.dex$", options: .regularExpression) != nil else {
            throw ManagementError.invalid("APK 校验组件路径无效。")
        }
        return """
            #!/system/bin/sh
            set -eu
            umask 077
            root='\(root)'
            source='\(source)'
            state() { echo "$1" > "$root/ufi-status.new"; mv "$root/ufi-status.new" "$root/ufi-status"; }
            \(UFIJobJournal.preamble(.ufi))
            locked=0
            complete=0
            operation=/data/local/flowdeck-config/operation
            finish() {
                trap - EXIT HUP INT TERM
                set +e
                if test "$complete" = 0; then state rejected; fi
                \(UFIJobJournal.unlock)
                rm -rf "$root/ufi-job"
            }
            trap finish EXIT
            trap 'exit 1' HUP INT TERM
            \(UFIJobJournal.lock)
            \(package.map { "test \"$(sha256sum \"$source\" | cut -d ' ' -f1)\" = '\($0.checksum)'" } ?? "(cd \"$root\" && sha256sum -c ufi.previous.sha256 >/dev/null)") || { state rejected; exit 1; }
            meta=$(CLASSPATH=\(helper) app_process /system/bin FlowDeckPackage "$source")
            echo "$meta" | grep -qx 'status=verified' || { state rejected; exit 1; }
            candidate_code=$(echo "$meta" | sed -n 's/^code=//p')
            installed_code=$(echo "$meta" | sed -n 's/^installed_code=//p')
            \(rollback ? "test \"$candidate_code\" -lt \"$installed_code\"" : "test \"$candidate_code\" -gt \"$installed_code\"")
            \(rollback ? "" : "old=$(pm path com.minikano.f50_sms | sed -n 's/^package://p' | head -1)\ntest -f \"$old\"\ncp \"$old\" \"$root/ufi.previous.new\"\nchmod 600 \"$root/ufi.previous.new\"\nmv \"$root/ufi.previous.new\" \"$root/ufi.previous.apk\"\n(cd \"$root\" && sha256sum ufi.previous.apk > ufi.previous.sha256)")
            echo "$candidate_code" > "$journal/expected-code"
            state installing
            if pm install -r \(rollback ? "-d" : "") "$source" > "$root/ufi-install-result" 2>&1; then
                state reconnecting
                am start -n com.minikano.f50_sms/.MainActivity --ez silent true >/dev/null 2>&1 || true
                sleep 3
                expected=$(echo "$meta" | sed -n 's/^code=//p')
                actual=$(dumpsys package com.minikano.f50_sms | sed -n 's/.*versionCode=\\([0-9]*\\).*/\\1/p' | head -1)
                if test "$expected" = "$actual"; then state done; else state unconfirmed; fi
            else
                state rejected
                am start -n com.minikano.f50_sms/.MainActivity --ez silent true >/dev/null 2>&1 || true
            fi
            complete=1
            """
    }
}

extension UFIClient {
    func serviceUpdateState() async throws -> UFIServiceUpdateState {
        try await verifyWifiFirmware()
        let system = try await request("api/baseDeviceInfo")
        let output = try await shell(
            """
            \(UFIJobJournal.inspect(.ufi))
            printf 'status='; cat \(UFIServiceUpdateScript.root)/ufi-status 2>/dev/null; echo
            if (cd \(UFIServiceUpdateScript.root) && sha256sum -c ufi.previous.sha256 >/dev/null 2>&1); then echo backup=1; fi
            """, root: true)
        let fields = Self.fields(output)
        return UFIServiceUpdateState(
            version: system.string("app_ver") ?? "未知", status: UFIJobJournal.resolvedStatus(fields["status"] ?? "idle", health: fields["job_health"]),
            backup: fields["backup"] == "1")
    }

    func prepareServicePackage(_ data: Data, progress: @Sendable (Double) async -> Void) async throws -> UFIServicePackage {
        guard expectedFingerprint != nil else { throw ManagementError.deviceChanged }
        try await verifyWifiFirmware()
        let checksum = DeviceIdentity.digest(data)
        let path = try await UFIPackageTransfer.send(
            data: data, checksum: checksum,
            command: { try await self.shell($0, root: true) }, progress: progress)
        let helper = try await UFISecureConfigChannel { try await self.shell($0, root: true) }.prepare()
        let metadata = Self.fields(try await shell("CLASSPATH=\(helper) app_process /system/bin FlowDeckPackage \(path)", root: true))
        guard metadata["status"] == "verified", let version = metadata["version"],
            let code = metadata["code"].flatMap(Int.init), let installed = metadata["installed_code"].flatMap(Int.init)
        else {
            throw ManagementError.invalid("APK 包名或签名与已安装 UFI 不一致，已拒绝安装。请使用同一作者的完整版。")
        }
        return UFIServicePackage(path: path, checksum: checksum, version: version, code: code, installedCode: installed)
    }

    func installServicePackage(_ package: UFIServicePackage?) async throws {
        guard expectedFingerprint != nil else { throw ManagementError.deviceChanged }
        try await verifyWifiFirmware()
        if let package, package.code <= package.installedCode {
            throw ManagementError.invalid("所选 APK 不是更高版本；回退请使用设备上保留的备份。")
        }
        let helper = try await UFISecureConfigChannel { try await self.shell($0, root: true) }.prepare()
        let script = try UFIServiceUpdateScript.make(package: package, helper: helper)
        let root = UFIServiceUpdateScript.root
        let output = try await shell(
            """
            set -eu
            umask 077; mkdir -p \(root); chmod 700 \(root)
            if mkdir \(root)/ufi-job 2>/dev/null; then
                if printf '%s' '\(Data(script.utf8).base64EncodedString())' | base64 -d > \(root)/ufi-job.sh; then
                    \(UFIJobJournal.preamble(.ufi))
                    echo starting > \(root)/ufi-status
                    nohup sh \(root)/ufi-job.sh >/dev/null 2>&1 </dev/null &
                    echo job=started
                else
                    rmdir \(root)/ufi-job
                    echo job=failed
                fi
            else
                echo job=busy
            fi
            """, root: true)
        guard Self.fields(output)["job"] == "started" else { throw ManagementError.unconfirmed("已有 UFI 更新任务，请读取状态，不要重复提交。") }
    }
}

extension UFIClient {
    /// APK 安装由系统包管理器负责；重启后只核对版本和清理自己的任务，不自动降级或重装。
    func recoverServiceUpdate() async throws {
        try await verifyWifiFirmware()
        try await runRecoveryScript(Self.interruptedServiceRecoveryScript)
    }

    /// 固定的恢复程序独立暴露给隔离故障测试，不包含用户数据。
    static var interruptedServiceRecoveryScript: String {
        """
        \(UFIJobJournal.recoveryGuard(.ufi))
        root='\(UFIServiceUpdateScript.root)'
        expected=$(cat "$journal/expected-code" 2>/dev/null || true)
        actual=$(dumpsys package com.minikano.f50_sms | sed -n 's/.*versionCode=\\([0-9]*\\).*/\\1/p' | head -1)
        test -n "$actual"
        if test -n "$expected" && test "$actual" = "$expected"; then
            echo done > "$root/ufi-status"
        else
            echo unconfirmed > "$root/ufi-status"
        fi
        \(UFIJobJournal.releaseRecovered)
        """
    }
}
