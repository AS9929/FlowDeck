import Foundation

/// 设备后台任务的持久记录。只读探测不清锁；恢复必须确认设备已重启，排除孤儿子进程仍在写入。
/// boot ID + PID + 启动时钟用于区分当前任务、PID 复用及断电遗留。
enum UFIJobJournal {
    enum Kind: String {
        case core, ufi
        var root: String { self == .core ? UFICoreUpdateScript.root : UFIServiceUpdateScript.root }
        var job: String { root + "/" + rawValue + "-job" }
    }

    static let operation = "/data/local/flowdeck-config/operation"

    static func preamble(_ kind: Kind) -> String {
        """
        journal='\(kind.job)'
        boot=$(cat /proc/sys/kernel/random/boot_id)
        ticks=$(awk '{print $22}' /proc/$$/stat)
        test -n "$boot" && test -n "$ticks"
        printf '%s %s %s\\n' "$boot" "$$" "$ticks" > "$journal/owner.new"
        mv "$journal/owner.new" "$journal/owner"
        """
    }

    /// 活跃状态必须有对应进程；无进程不能继续显示无限进度。
    static func inspect(_ kind: Kind) -> String {
        """
        journal='\(kind.job)'
        health=none
        if test -d "$journal"; then
            health=unknown
            if test -f "$journal/owner"; then
                read saved_boot saved_pid saved_ticks < "$journal/owner"
                boot=$(cat /proc/sys/kernel/random/boot_id)
                if test "$saved_boot" != "$boot"; then
                    health=interrupted
                elif test -r "/proc/$saved_pid/stat" && test "$(awk '{print $22}' /proc/$saved_pid/stat)" = "$saved_ticks"; then
                    health=alive
                else
                    health=orphaned
                fi
            fi
        fi
        if test -f "$journal/recovery-lock/owner"; then
            read recovery_boot recovery_pid recovery_ticks < "$journal/recovery-lock/owner"
            if test "$recovery_boot" = "$(cat /proc/sys/kernel/random/boot_id)" && test -r "/proc/$recovery_pid/stat" && test "$(awk '{print $22}' /proc/$recovery_pid/stat)" = "$recovery_ticks"; then
                health=recovering
            fi
        fi
        printf 'job_health=%s\\n' "$health"
        """
    }

    /// 兼容旧任务时保留证据，不把缺少 owner 的旧目录当成可安全删除。
    static func resolvedStatus(_ status: String, health: String?) -> String {
        switch health {
        case "alive": return status
        case "recovering": return "recovering"
        case "interrupted": return "interrupted"
        case "orphaned": return "orphaned"
        case "unknown": return "recovery-required"
        default:
            let active = ["starting", "downloading", "checking", "switching", "verifying", "installing", "reconnecting"]
            return active.contains(status) ? "recovery-required" : status
        }
    }

    static func recoveryGuard(_ kind: Kind) -> String {
        """
        set -eu
        umask 077
        journal='\(kind.job)'
        test -f "$journal/owner" || { echo recovery=unknown-owner; exit 0; }
        read saved_boot saved_pid saved_ticks < "$journal/owner"
        test -n "$saved_boot"
        boot=$(cat /proc/sys/kernel/random/boot_id)
        test "$saved_boot" != "$boot" || { echo recovery=restart-required; exit 0; }
        # 两个客户端不能同时执行恢复；锁仅在本次恢复结束时释放。
        if test -d "$journal/recovery-lock"; then
            recovery_boot=$(cat "$journal/recovery-lock/boot" 2>/dev/null || true)
            test -n "$recovery_boot" && test "$recovery_boot" != "$boot" || { echo recovery=recovery-busy; exit 0; }
            rm -f "$journal/recovery-lock/boot" "$journal/recovery-lock/owner"
            rmdir "$journal/recovery-lock"
        fi
        mkdir "$journal/recovery-lock" 2>/dev/null || { echo recovery=recovery-busy; exit 0; }
        echo "$boot" > "$journal/recovery-lock/boot"
        ticks=$(awk '{print $22}' /proc/$$/stat)
        printf '%s %s %s\\n' "$boot" "$$" "$ticks" > "$journal/recovery-lock/owner"
        trap 'rm -f "$journal/recovery-lock/boot" "$journal/recovery-lock/owner"; rmdir "$journal/recovery-lock" 2>/dev/null || true' EXIT
        trap 'exit 1' HUP INT TERM
        operation='\(operation)'
        # 恢复期间同样占用设备操作锁，其他维护流程不能插入。
        if mkdir "$operation" 2>/dev/null; then
            printf '%s' "$journal" > "$operation/owner"
        else
            test "$(cat "$operation/owner" 2>/dev/null)" = "$journal" || { echo recovery=foreign-lock; exit 0; }
        fi
        """
    }

    static var lock: String {
        """
        mkdir "$operation"
        printf '%s' "$journal" > "$operation/owner"
        locked=1
        """
    }

    static var unlock: String {
        """
        if test "$locked" = 1 && test "$(cat "$operation/owner" 2>/dev/null)" = "$journal"; then
            rm -f "$operation/owner"
            rmdir "$operation"
        fi
        """
    }

    static var releaseRecovered: String {
        """
        if test -d "$operation"; then
            rm -f "$operation/owner"
            rmdir "$operation"
        fi
        rm -rf "$journal"
        echo recovery=done
        """
    }
}

extension UFIClient {
    /// 恢复含配置校验和服务启动，不能放在 UFI 的 8 秒请求窗口内执行。
    /// 后台只保存固定脚本及状态码；断线后从任务记录继续核对，不自动重新提交。
    func runRecoveryScript(_ script: String) async throws {
        let path = UFICoreUpdateScript.root + "/recovery-" + UUID().uuidString.lowercased()
        let encoded = Data(script.utf8).base64EncodedString()
        _ = try await shell(
            """
            set -eu
            umask 077
            printf '%s' '\(encoded)' | base64 -d > '\(path).sh'
            nohup sh -c 'sh "\(path).sh" > "\(path).result" 2>&1; echo recovery_finished=1 >> "\(path).result"' >/dev/null 2>&1 </dev/null &
            """, root: true)
        for _ in 0..<60 {
            try await Task.sleep(for: .seconds(2))
            let result = try await shell("cat '\(path).result' 2>/dev/null", root: true)
            if Self.fields(result)["recovery_finished"] == "1" {
                // 只清理本次公开状态文件，不清理任务锁或恢复材料。
                _ = try? await shell("rm -f '\(path).sh' '\(path).result'", root: true)
                try Self.checkRecovery(result)
                return
            }
        }
        throw ManagementError.unconfirmed("恢复仍未确认，请稍后重新读取设备状态，勿重复提交。")
    }
}
