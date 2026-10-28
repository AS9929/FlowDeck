import Foundation

/// WebSSH 核心与管理服务事务。保留原备份、任务状态、补偿及回读顺序，不持有页面状态。
/// 调用方在操作租约内完成身份核验；超时不自动重发安装或重启命令。
@MainActor
struct WebSSHMaintenanceService {
    let api: any WebSSHAPI
    let demo: Bool
    let progress: (String, Double) async -> Void

    func updateCore(rollback: Bool) async throws -> CoreUpdateInfo {
        let wasRunning = try await api.mihomoStatus().running
        if rollback {
            try await api.rollbackCore()
        } else {
            let directory = try await api.coreDirectory()
            let existing = try await api.management("GET", "api/mihomo/install/status", body: nil).object("data")?.string("state")
            guard !["starting", "downloading", "installing"].contains(existing ?? "") else {
                throw ManagementError.invalid("设备已有核心安装任务，请等待完成后重新检查。")
            }
            // 复制并摘要 57 MB 核心可能超过单次调用 5 秒上限，走后台任务。
            _ = try await api.runBackgroundScript(
                directory: directory + "/.flowdeck-jobs", name: "snapshot-core", title: "更新前备份核心",
                script: """
                    set -eu
                    cd \(ShellValue.quote(directory))
                    test -x mihomo
                    cp -p mihomo mihomo.u60-before-update
                    cp -p config.yaml config.u60-before-update.yaml
                    sha256sum mihomo.u60-before-update > mihomo.u60-before-update.sha256
                    """)
            var installerFinished = false
            do {
                _ = try await api.management("POST", "api/mihomo/install", body: nil)
                let deadline = Date().addingTimeInterval(180)
                while Date() < deadline {
                    try await Task.sleep(nanoseconds: demo ? 100_000_000 : 1_000_000_000)
                    let data = try await api.management("GET", "api/mihomo/install/status", body: nil).object("data")
                    let state = data?.string("state") ?? "unknown"
                    await progress("设备核心更新 · \(state)", Double(data?.int("percent") ?? 0) / 100)
                    if ["done", "failed", "canceled"].contains(state) {
                        installerFinished = true
                        guard state == "done" else {
                            throw ManagementError.unconfirmed("设备安装任务失败。")
                        }
                        break
                    }
                }
                guard installerFinished else {
                    throw ManagementError.unconfirmed("安装超时，请重新检查设备安装状态。")
                }
                guard try await api.checkConfig().ok else {
                    throw ManagementError.unconfirmed("更新后配置校验失败。")
                }
                if wasRunning {
                    guard try await api.connectivity() else {
                        throw ManagementError.unconfirmed("更新后出口验证失败。")
                    }
                }
            } catch {
                // 安装进程未确认结束时不能覆盖二进制，防止与设备下载器并发写入。
                guard installerFinished else {
                    throw ManagementError.unconfirmed("安装状态未确认。旧核心已保留，待安装任务结束后使用“恢复上一个核心”。")
                }
                try await api.rollbackCore()
                if !wasRunning {
                    _ = try await api.control(.stop)
                }
                let restored = try await api.mihomoStatus()
                guard restored.running == wasRunning else {
                    throw ManagementError.unconfirmed("更新失败，回滚后的运行状态未确认。")
                }
                throw ManagementError.unconfirmed("更新未通过校验，已恢复旧核心和原运行状态。")
            }
        }
        if !wasRunning {
            _ = try await api.control(.stop)
        }
        let service = try await api.mihomoStatus()
        guard service.running == wasRunning, !wasRunning || service.apiReachable else {
            throw ManagementError.unconfirmed("核心操作已执行，运行状态尚未恢复。")
        }
        return try await api.coreVersion()
    }

    struct ServiceResult {
        let version: String
        let alreadyCurrent: Bool
    }

    func manageWebSSH(update: Bool) async throws -> ServiceResult {
        let version = try await api.management("GET", "api/update/version", body: nil).object("data")
        let current = version?.string("current_version")
        let latest = version?.string("latest_version")
        if update, current == latest, current != nil {
            return ServiceResult(version: current ?? "未知", alreadyCurrent: true)
        }
        if update {
            _ = try await api.management("POST", "api/update/run", body: JSONObject())
        } else {
            _ = try await api.runMaintenanceScript(Self.webSSHRestartScript)
        }
        await progress("等待管理服务重新连接", 0.3)
        let deadline = Date().addingTimeInterval(demo ? 5 : 180)
        var offline = false
        while Date() < deadline {
            try await Task.sleep(nanoseconds: demo ? 300_000_000 : 2_000_000_000)
            do {
                let value = try await api.management("GET", "api/update/version", body: nil).object("data")
                if update {
                    let result = try await api.management("GET", "api/update/status", body: nil).object("data")
                    if ["failed", "canceled"].contains(result?.string("state") ?? "") {
                        throw ManagementError.unconfirmed("管理服务更新失败，请检查设备网络后重试。")
                    }
                    guard value?.string("current_version") == latest else {
                        continue
                    }
                } else if !offline && !demo {
                    let marker = try await api.runMaintenanceScript("cat /tmp/u60-webssh-restart.done 2>/dev/null || true")
                    guard marker.trimmingCharacters(in: .whitespacesAndNewlines) == "done" else {
                        continue
                    }
                }
                _ = try await api.snapshot()
                let confirmedVersion = value?.string("current_version") ?? "未知"
                if update && !demo {
                    // 原更新器不更新自定义启动脚本的 PID 文件，按真实可执行路径重新记录。
                    _ = try await api.runMaintenanceScript(
                        """
                        set -eu
                        binary=/data/kano_plugins/webssh/webssh
                        for process in /proc/[0-9]*; do
                            if [ "$(readlink "$process/exe" 2>/dev/null || true)" = "$binary" ]; then
                                basename "$process" > /data/kano_plugins/webssh/webssh.pid
                                break
                            fi
                        done
                        """)
                }
                return ServiceResult(version: confirmedVersion, alreadyCurrent: false)
            } catch let error as ManagementError {
                throw error
            } catch {
                offline = true
            }
        }
        throw ManagementError.unconfirmed("管理服务尚未恢复，不能确认成功。请通过已保存的 USB／SSH 救援流程检查 WebSSH。")
    }

    /// 延迟执行使当前 HTTP 有机会返回；只停止已核对路径的进程，保留配置与日志。
    static let webSSHRestartScript = """
        set -eu
        directory=/data/kano_plugins/webssh
        test -x "$directory/webssh"
        test -f "$directory/start-webssh.sh"
        rm -f /tmp/u60-webssh-restart.done
        nohup /bin/sh -c '
            sleep 2
            directory=/data/kano_plugins/webssh
            pid=$(cat "$directory/webssh.pid" 2>/dev/null || true)
            if [ -n "$pid" ] && [ "$(readlink /proc/$pid/exe)" = "$directory/webssh" ]; then
                kill "$pid"
                sleep 2
            fi
            sh "$directory/start-webssh.sh" && echo done > /tmp/u60-webssh-restart.done
        ' >/tmp/u60-webssh-restart.log 2>&1 </dev/null &
        """
}
