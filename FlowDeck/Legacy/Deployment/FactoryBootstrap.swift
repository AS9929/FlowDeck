import Foundation

/// MU5250 B28 的离线首次引导。只补充 rc.local，不改 USB、分区或原厂服务。
/// 服务先绑定回环地址并完成随机凭据初始化，确认后才开放局域网管理端口。
enum FactoryBootstrap {
    static let firmware = "BD_FLYMODEMMU5250V1.0.0B28"
    static let binaryDigest = "758f20a172ac6f79046d86215744084f5cd45cc3b0f35dd99c2bd97325572df9"
    static let marker = "# FLOWDECK_BOOTSTRAP_V1"
    static let directory = "/data/kano_plugins/webssh"

    static func binary() throws -> Data {
        guard let url = Bundle.main.url(forResource: "BootstrapWebSSH", withExtension: "bin") else {
            throw ManagementError.invalid("此版本不提供首次部署载荷，请先通过电脑部署设备。")
        }
        let data = try Data(contentsOf: url)
        guard DeviceIdentity.digest(data) == binaryDigest else {
            throw ManagementError.invalid("离线管理服务资源摘要不一致。")
        }
        return data
    }

    static func startup(original: String, binary: Data, password: String) throws -> String {
        guard !original.contains("kano_plugins"), !original.contains(marker),
            original.utf8.count < 128 * 1024, (12...63).contains(password.utf8.count),
            DeviceIdentity.digest(binary) == binaryDigest
        else { throw ManagementError.invalid("检测到已有部署、密码长度不符或启动脚本不适配，未生成首次安装包。") }
        let random: () throws -> String = {
            try FactoryEncryption.randomBytes(count: 24).map { String(format: "%02x", $0) }.joined()
        }
        let initialization: [String: Any] = [
            "db_type": "sqlite", "db_file": "gowebssh.db", "username": "admin", "password": password,
            "jwt_secret": try random(), "session_secret": try random(),
            "sshd_host": "127.0.0.1", "sshd_port": 2222, "sshd_user": "root", "sshd_pwd": try random(),
        ]
        let initializationData = try JSONSerialization.data(withJSONObject: initialization, options: [.sortedKeys])
        let launcher = """
            #!/bin/sh
            umask 077
            cd /data/kano_plugins/webssh || exit 1
            if [ -f webssh.pid ]; then
                pid=$(cat webssh.pid)
                if [ "$(readlink /proc/$pid/exe 2>/dev/null)" = "$PWD/webssh" ]; then exit 0; fi
            fi
            nohup ./webssh -ConfigDir "$PWD" >> startup.log 2>&1 < /dev/null &
            echo $! > webssh.pid
            """
        let future = "#!/bin/sh\n# FLOWDECK_MANAGED_V1\n(sh /data/kano_plugins/webssh/start-webssh.sh &)\n" + original
        func encoded(_ string: String) -> String { Data(string.utf8).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]) }
        let payload = binary.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        // 后台运行以免阻塞原厂启动；失败不替换 rc.local，保留导入前原件供恢复。
        return """
            #!/bin/sh
            \(marker)
            (
                sleep 20
                umask 077
                d=/data/kano_plugins/webssh
                mkdir -p /data/flowdeck-bootstrap
                mkdir /data/flowdeck-bootstrap/attempted 2>/dev/null || exit 0
                exec >> /data/flowdeck-bootstrap/result.log 2>&1
                set -eu
                command -v base64 >/dev/null
                command -v sha256sum >/dev/null
                command -v curl >/dev/null
                test ! -e "$d"
                mkdir -p "$d/.GoWebSSH"
                cd "$d"
                base64 -d > webssh.part <<'FLOWDECK_BINARY'
            \(payload)
            FLOWDECK_BINARY
                echo '\(binaryDigest)  webssh.part' | sha256sum -c -
                chmod 700 webssh.part
                mv webssh.part webssh
                base64 -d > start-webssh.sh <<'FLOWDECK_LAUNCHER'
            \(encoded(launcher))
            FLOWDECK_LAUNCHER
                chmod 700 start-webssh.sh
                printf 'address = "127.0.0.1"\\nport = "8899"\\n' > .GoWebSSH/GoWebSSH.toml
                base64 -d > init.json <<'FLOWDECK_INIT'
            \(initializationData.base64EncodedString())
            FLOWDECK_INIT
                sh start-webssh.sh
                ready=0
                for attempt in 1 2 3 4 5 6 7 8 9 10; do
                    if curl -fsS --max-time 3 http://127.0.0.1:8899/api/sys/is_init > /dev/null; then ready=1; break; fi
                    sleep 2
                done
                test "$ready" = 1
                curl -fsS --max-time 30 -H 'Content-Type: application/json' --data-binary @init.json \\
                    http://127.0.0.1:8899/api/sys/init > init-result.json
                grep -Eq '"code"[[:space:]]*:[[:space:]]*0([,}])' init-result.json
                chmod 600 .GoWebSSH/GoWebSSH.toml
                rm -f init.json init-result.json
                kill "$(cat webssh.pid)"
                sleep 2
                sed 's/^address = .*/address = "0.0.0.0"/' .GoWebSSH/GoWebSSH.toml > .GoWebSSH/config.next
                mv .GoWebSSH/config.next .GoWebSSH/GoWebSSH.toml
                base64 -d > /data/flowdeck-bootstrap/rc.local.original <<'FLOWDECK_ORIGINAL'
            \(encoded(original))
            FLOWDECK_ORIGINAL
                base64 -d > /etc/rc.local.flowdeck-next <<'FLOWDECK_FUTURE'
            \(encoded(future))
            FLOWDECK_FUTURE
                chmod 755 /etc/rc.local.flowdeck-next
                sh -n /etc/rc.local.flowdeck-next
                mv /etc/rc.local.flowdeck-next /etc/rc.local
                sh start-webssh.sh
                echo 'FLOWDECK_BOOTSTRAP_COMPLETE'
            ) &
            \(original)
            """
    }
}
