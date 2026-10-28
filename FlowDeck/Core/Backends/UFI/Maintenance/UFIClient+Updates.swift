import Foundation

/// 软件更新入口与通用设备会话分离，统一复用设备身份和服务适配校验。

extension UFIClient {
    /// 读取安装目录中的固定备份及摘要，不把普通文件存在当成可恢复。
    func coreUpdateState() async throws -> UFICoreState {
        try await verifyServiceAdapter()
        let result = Self.fields(
            try await shell(
                """
                \(UFIJobJournal.inspect(.core))
                printf 'version='; /data/clash/Proxy/Clash.Core -v 2>/dev/null | head -1
                printf 'status='; cat /data/local/flowdeck-config/core-status 2>/dev/null; echo
                cd /data/clash/Proxy
                if sha256sum -c .flowdeck-core.previous.sha256 >/dev/null 2>&1; then echo backup=1; else echo backup=0; fi
                """, root: true))
        return UFICoreState(
            version: result["version"] ?? "未知", backupAvailable: result["backup"] == "1",
            status: UFIJobJournal.resolvedStatus(result["status"] ?? "idle", health: result["job_health"]))
    }

    /// release 为 nil 时恢复备份；设备上的互斥目录防止重复启动后台事务。
    func startCoreUpdate(_ release: UFICoreRelease?, package: Data? = nil, progress: @Sendable (Double) async -> Void = { _ in }) async throws {
        try await verifyServiceAdapter()
        // 回滚通过管理通道读取磁盘配置；核心停机/API 损坏不能阻止恢复。
        let port = try await coreRecoveryPort()
        if let package {
            guard let release else { throw ManagementError.invalid("恢复备份不能附带安装包。") }
            _ = try await UFIPackageTransfer.send(
                data: package, checksum: release.checksum,
                command: { try await self.shell($0, root: true) }, progress: progress)
        }
        let script = try UFICoreUpdateScript.make(release: release, port: port, localPackage: package != nil)
        let root = UFICoreUpdateScript.root
        let encoded = Data(script.utf8).base64EncodedString()
        let result = try await shell(
            """
            set -eu
            umask 077
            mkdir -p \(root)
            chmod 700 \(root)
            if mkdir \(root)/core-job 2>/dev/null; then
                if printf '%s' '\(encoded)' | base64 -d > \(root)/core-job.sh; then
                    \(UFIJobJournal.preamble(.core))
                    echo starting > \(root)/core-status
                    nohup sh \(root)/core-job.sh >/dev/null 2>&1 </dev/null &
                    echo flowdeck_job=started
                else
                    rmdir \(root)/core-job
                    echo flowdeck_job=failed
                fi
            else
                echo flowdeck_job=busy
            fi
            """, root: true)
        guard Self.fields(result)["flowdeck_job"] == "started" else {
            throw ManagementError.unconfirmed("已有核心任务或遗留任务目录，请重新读取状态，勿重复更新。")
        }
    }
}

extension UFIClient {
    /// 只输出两个顶层端口字段，配置密钥不经过日志或普通 shell 响应。
    func coreRecoveryPort() async throws -> Int {
        let output = try await shell(
            """
            awk '/^(mixed-port|port):[ \t]*[0-9]+([ \t]*(#.*)?)?$/ {
                key=$1; sub(/:$/, "", key); print key "=" $2
            }' /data/clash/Proxy/config.yaml
            """, root: true)
        let fields = Self.fields(output)
        for key in ["mixed-port", "port"] {
            if let value = fields[key].flatMap(Int.init), (1...65535).contains(value) { return value }
        }
        throw ManagementError.unconfirmed("磁盘配置未提供可确认的 HTTP 代理端口，请修正 mixed-port 或 port 后恢复。")
    }

    /// 断电后显式恢复：先检查任务归属与原核心摘要，再恢复；不自动重做升级。
    func recoverCoreUpdate() async throws {
        try await verifyServiceAdapter()
        try await runRecoveryScript(Self.interruptedCoreRecoveryScript)
    }

    /// 固定的恢复程序独立暴露给隔离故障测试，不包含用户数据。
    static var interruptedCoreRecoveryScript: String {
        """
        \(UFIJobJournal.recoveryGuard(.core))
        root='\(UFICoreUpdateScript.root)'
        core=/data/clash/Proxy/Clash.Core
        service=/data/clash/Scripts/Clash.Service
        status=$(cat "$root/core-status")
        case "$status" in
            starting|downloading|checking|failed-before-switch|done|rolled-back) ;;
            switching|verifying|recovery-unconfirmed)
                (cd "$journal" && sha256sum -c recovery.sha256 >/dev/null)
                actual=$(sha256sum "$core" | cut -d ' ' -f1)
                old=$(cut -d ' ' -f1 "$journal/recovery.sha256")
                candidate=$(cat "$journal/candidate.sha256")
                test "$actual" = "$old" || test "$actual" = "$candidate"
                timeout 15 "$journal/recovery" -t -d /data/clash/Proxy -f /data/clash/Proxy/config.yaml >/dev/null 2>&1
                "$service" stop >/dev/null 2>&1
                cp -p "$journal/recovery" "$journal/restoring"
                mv "$journal/restoring" "$core"
                test "$(sha256sum "$core" | cut -d ' ' -f1)" = "$old"
                if test "$(cat "$journal/was-running")" = 1; then
                    "$service" start >/dev/null 2>&1
                    sleep 3
                    pidof Clash.Core >/dev/null
                fi
                ;;
            *) echo recovery=unknown-stage; exit 0 ;;
        esac
        echo interrupted-recovered > "$root/core-status"
        \(UFIJobJournal.releaseRecovered)
        """
    }

    static func checkRecovery(_ output: String) throws {
        guard Self.fields(output)["recovery"] == "done" else {
            throw ManagementError.unconfirmed("任务恢复未完成。若为当前开机期间的孤儿任务，请先重启设备；旧版或其他任务的锁需人工核对，App 不会强行删除。")
        }
    }
}
