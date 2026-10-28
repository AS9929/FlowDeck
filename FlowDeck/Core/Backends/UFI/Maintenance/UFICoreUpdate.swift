import Foundation

/// 只接受 Mihomo 官方稳定版的 Android ARM64 资产及 GitHub 提供的 SHA-256。
struct UFICoreRelease: Sendable, Equatable, Codable {
    let version: String
    let url: URL
    let checksum: String
    let size: Int

    init(json: JSONObject) throws {
        guard json.bool("draft") == false, json.bool("prerelease") == false,
            let version = json.string("tag_name"),
            version.range(of: "^v[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil,
            let assets = json.raw["assets"] as? [[String: Any]]
        else {
            throw ManagementError.invalid("官方版本信息不完整。")
        }
        let name = "mihomo-android-arm64-v8-" + version + ".gz"
        guard let asset = assets.first(where: { $0["name"] as? String == name }),
            let size = asset["size"] as? Int, (1...80_000_000).contains(size),
            let digest = asset["digest"] as? String, digest.hasPrefix("sha256:"),
            let urlText = asset["browser_download_url"] as? String,
            urlText == "https://github.com/MetaCubeX/mihomo/releases/download/\(version)/\(name)",
            let url = URL(string: urlText)
        else {
            throw ManagementError.invalid("未找到带官方校验值的 Android ARM64 内核。")
        }
        let checksum = String(digest.dropFirst(7))
        guard checksum.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw ManagementError.invalid("官方 SHA-256 格式无效。")
        }
        self.version = version
        self.url = url
        self.checksum = checksum
        self.size = size
    }

    static func latest() async throws -> Self {
        let url = URL(string: "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
            let object = JSONObject(data: data)
        else {
            throw ManagementError.unconfirmed("暂时无法获取官方版本，请检查手机网络后重试。")
        }
        return try Self(json: object)
    }
}

/// 后台事务不含用户配置或密钥。断开 App 后仍完成校验或恢复，并留下固定状态码供回读。
enum UFICoreUpdateScript {
    static let root = "/data/local/flowdeck-config"

    static func make(release: UFICoreRelease?, port: Int, localPackage: Bool = false) throws -> String {
        guard (1...65535).contains(port) else { throw ManagementError.invalid("代理端口无效。") }
        let preparation: String
        if let release {
            let acquisition =
                localPackage
                ? "cp " + (try UFIPackageTransfer.path(checksum: release.checksum)) + " \"$work/core.gz\""
                : "\"$curl\" --fail --silent --location --proto '=https' --proto-redir '=https' --max-time 180 --max-filesize \(release.size) '\(release.url.absoluteString)' -o \"$work/core.gz\""
            preparation = """
                state downloading
                \(acquisition)
                test "$(stat -c %s "$work/core.gz")" = '\(release.size)'
                echo '\(release.checksum)  '"$work/core.gz" | sha256sum -c - >/dev/null
                gzip -dc "$work/core.gz" > "$work/candidate"
                chmod 700 "$work/candidate"
                timeout 5 "$work/candidate" -v 2>/dev/null | grep -qF ' \(release.version) '
                """
        } else {
            preparation = """
                state checking
                cd /data/clash/Proxy
                sha256sum -c .flowdeck-core.previous.sha256 >/dev/null
                cp -p .flowdeck-core.previous "$work/candidate"
                """
        }
        return """
            #!/system/bin/sh
            set -eu
            umask 077
            root='\(root)'
            work="$root/core-job"
            operation="$root/operation"
            core=/data/clash/Proxy/Clash.Core
            service=/data/clash/Scripts/Clash.Service
            curl=/data/data/com.minikano.f50_sms/files/curl
            \(UFIJobJournal.preamble(.core))
            locked=0
            changed=0
            was_running=0
            succeeded=0
            state() {
                echo "$1" > "$root/core-status.new"
                mv "$root/core-status.new" "$root/core-status"
            }
            finish() {
                trap - EXIT HUP INT TERM
                set +e
                if test "$succeeded" = 0; then
                    if test "$changed" = 1; then
                        "$service" stop >/dev/null 2>&1
                        cp -p "$work/recovery" "$work/restoring" && mv "$work/restoring" "$core"
                        if test "$was_running" = 1; then
                            "$service" start >/dev/null 2>&1
                            sleep 3
                        fi
                        recovered=0
                        if cmp -s "$core" "$work/recovery"; then
                            if test "$was_running" = 1; then
                                pidof Clash.Core >/dev/null && recovered=1
                            else
                                pidof Clash.Core >/dev/null || recovered=1
                            fi
                        fi
                        if test "$recovered" = 1; then
                            state rolled-back
                        else
                            state recovery-unconfirmed
                        fi
                    else
                        state failed-before-switch
                    fi
                fi
                # 恢复未确认时保留恢复文件和任务证据，供重新开机后受控恢复。
                if test "$(cat "$root/core-status")" != recovery-unconfirmed; then
                    \(UFIJobJournal.unlock)
                    rm -rf "$work"
                fi
            }
            trap finish EXIT
            trap 'exit 1' HUP INT TERM
            test "$(getprop ro.product.cpu.abi)" = arm64-v8a
            \(preparation)
            state checking
            \(UFIJobJournal.lock)
            timeout 15 "$work/candidate" -t -d /data/clash/Proxy -f /data/clash/Proxy/config.yaml >/dev/null 2>&1
            cp -p "$core" "$work/recovery"
            (cd "$work" && sha256sum recovery > recovery.sha256)
            sha256sum "$work/candidate" | cut -d ' ' -f1 > "$work/candidate.sha256"
            \(release == nil ? "" : "cp -p \"$core\" /data/clash/Proxy/.flowdeck-core.previous\n(cd /data/clash/Proxy && sha256sum .flowdeck-core.previous > .flowdeck-core.previous.sha256)")
            if pidof Clash.Core >/dev/null; then
                was_running=1
            fi
            \(release == nil ? "was_running=1" : "")
            echo "$was_running" > "$work/was-running"
            state switching
            changed=1
            "$service" stop >/dev/null 2>&1
            mv "$work/candidate" "$core"
            if test "$was_running" = 1; then
                "$service" start >/dev/null 2>&1
                state verifying
                ready=0
                for attempt in 1 2 3 4 5 6; do
                    sleep 2
                    if pidof Clash.Core >/dev/null; then
                        code=$("$curl" --silent --output /dev/null --max-time 5 \\
                            --proxy http://127.0.0.1:\(port) --write-out '%{http_code}' https://www.gstatic.com/generate_204) || code=0
                        if test "$code" = 204; then
                            ready=1
                            break
                        fi
                    fi
                done
                test "$ready" = 1
            else
                if pidof Clash.Core >/dev/null; then
                    exit 1
                fi
            fi
            succeeded=1
            state done
            """
    }
}

struct UFICoreState: Sendable {
    let version: String
    let backupAvailable: Bool
    let status: String

    var shortVersion: String {
        guard let range = version.range(of: "v[0-9]+\\.[0-9]+\\.[0-9]+", options: .regularExpression) else {
            return "未知版本"
        }
        return String(version[range])
    }

    var needsRecovery: Bool { ["interrupted", "orphaned", "recovery-required"].contains(status) }

    var running: Bool { ["starting", "downloading", "checking", "switching", "verifying", "recovering"].contains(status) }
    var statusTitle: String {
        switch status {
        case "interrupted": return "设备重启中断了任务，请核对并恢复"
        case "orphaned": return "任务进程已退出，请重启设备后恢复"
        case "recovery-required": return "任务记录不完整，需要人工核对"
        case "interrupted-recovered": return "中断任务已处理，请回读服务状态"
        case "recovering": return "正在核对并恢复中断任务"
        case "starting": return "准备更新任务"
        case "downloading": return "下载官方内核"
        case "checking": return "检查摘要与配置兼容性"
        case "switching": return "切换代理核心"
        case "verifying": return "验证代理出口"
        case "done": return "设备任务完成"
        case "rolled-back": return "更新失败，已恢复原核心"
        case "failed-before-switch": return "准备失败，原核心未替换"
        case "recovery-unconfirmed": return "恢复尚未确认，请检查设备"
        default: return "暂无更新任务"
        }
    }
}
