import Foundation
import Observation

/// 部署向导状态机。写入前重新读身份；首次安装、请求已发出及验收成功是不同阶段。
/// 原厂恢复与安装请求不自动重发。离开页面后保留检查点，重新进入只恢复查询。
@MainActor
@Observable
final class DeploymentStore {
    enum Route: String, CaseIterable, Identifiable {
        case managed = "已有 WebSSH"
        case factory = "原厂设备"
        var id: String { rawValue }
    }

    var route: Route = .managed
    var profile = DeviceProfile(name: "随身")
    var webPassword = ""
    var factoryPassword = ""
    var suffix = ""
    var source = ""
    var sourceName = ""
    var simulation = true
    private(set) var busy = false
    private(set) var message = "连接设备 Wi-Fi，选择当前设备状态。"
    private(set) var error: String?
    private(set) var phase = "new"
    private(set) var identity: FactoryDeploymentIdentity?
    private(set) var originalURL: URL?
    private(set) var preparedURL: URL?
    private(set) var progress: Double?
    private var configured = false
    private var secret = ""
    private var configDigest: String?
    private var originalDigest: String?
    private var preparedDigest: String?
    private let suppliedAPI: (any WebSSHAPI)?

    private let offlineResources: @Sendable () throws -> OfflineDeploymentResources

    init(
        api: (any WebSSHAPI)? = nil,
        offlineResources: @escaping @Sendable () throws -> OfflineDeploymentResources = {
            try OfflineDeploymentResources.bundled()
        }
    ) {
        suppliedAPI = api
        self.offlineResources = offlineResources
    }

    var factoryClient: FactoryClient {
        get throws { try FactoryClient(host: profile.host, password: factoryPassword) }
    }

    func load(_ devices: DeviceStore) {
        guard !configured else { return }
        configured = true
        simulation = devices.demoMode
        if let current = devices.current {
            profile = current
            webPassword = devices.webPassword(for: current)
            factoryPassword = devices.factoryPassword(for: current)
            secret = devices.secret(for: current)
            if let saved = DeploymentFiles.load(current.id), saved.host == current.host, saved.fingerprint == current.fingerprint {
                phase = saved.phase
                configDigest = saved.configDigest
                originalDigest = saved.originalDigest
                preparedDigest = saved.preparedDigest
                route = phase.hasPrefix("factory") ? .factory : .managed
                message = "找到未清除的部署记录。先检查设备状态，继续查询，不会自动重发安装。"
                if let folder = try? DeploymentFiles.directory(current.id) {
                    let original = folder.appendingPathComponent("original.bin")
                    let prepared = folder.appendingPathComponent("prepared.bin")
                    originalURL = FileManager.default.fileExists(atPath: original.path) ? original : nil
                    preparedURL = FileManager.default.fileExists(atPath: prepared.path) ? prepared : nil
                }
            }
        }
    }

    private func operation(_ title: String, action: () async throws -> Void) async {
        guard !busy else { return }
        let lease: UUID
        do { lease = try DeviceOperationGate.begin(title) } catch {
            self.error = error.localizedDescription
            return
        }
        defer { DeviceOperationGate.end(lease) }
        busy = true
        error = nil
        message = title
        defer {
            busy = false
            progress = nil
        }
        do {
            try await DeviceOperationGate.$owner.withValue(lease) { try await action() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    var canEditConnection: Bool {
        !busy && (simulation || (["new", "ready", "factoryDetected"].contains(phase) && originalURL == nil && configDigest == nil))
    }

    /// 只退回尚未写入的连接检查，保留当前设备身份，不能借修改 IP 绕过身份绑定。
    func editConnection() {
        guard canEditConnection else { return }
        phase = "new"
        identity = nil
        error = nil
        message = "修改连接信息后重新检查设备。"
    }

    /// 新设备使用独立记录，原设备的备份和进度仍保留，重新选择原设备后可以继续。
    func useNewDevice() {
        guard !busy else { return }
        profile = DeviceProfile(name: "新设备")
        webPassword = ""
        factoryPassword = ""
        secret = ""
        suffix = ""
        source = ""
        sourceName = ""
        identity = nil
        originalURL = nil
        preparedURL = nil
        configDigest = nil
        originalDigest = nil
        preparedDigest = nil
        phase = "new"
        error = nil
        message = "请连接新设备的 Wi-Fi，并填写其管理凭据。"
    }

    private func savePhase(_ value: String) throws {
        if !simulation {
            guard let fingerprint = profile.fingerprint else { throw ManagementError.deviceChanged }
            try DeploymentFiles.checkpoint(
                .init(
                    fingerprint: fingerprint, phase: value, host: profile.host,
                    configDigest: configDigest, originalDigest: originalDigest, preparedDigest: preparedDigest), id: profile.id)
        }
        phase = value
    }

    private func requireWritable(_ devices: DeviceStore) throws {
        guard !devices.readOnly else { throw ManagementError.invalid("只读模式已开启，请关闭后再部署。") }
        guard !Task.isCancelled else { throw CancellationError() }
    }

    private func webAPI() throws -> any WebSSHAPI {
        if let suppliedAPI { return suppliedAPI }
        guard let url = profile.webURL, url.host == profile.host, (1...65535).contains(profile.webPort), !webPassword.isEmpty else {
            throw ManagementError.invalid("请填写有效的管理地址和 WebSSH 密码。")
        }
        return WebSSHClient(baseURL: url, username: profile.webUser, password: webPassword)
    }

    private func verify(_ api: any WebSSHAPI) async throws {
        let snapshot = try await api.snapshot()
        guard snapshot.model == "MU5250", snapshot.firmware == FactoryBootstrap.firmware,
            let actual = DeviceIdentity.fingerprint(model: snapshot.model, imei: snapshot.imei)
        else { throw ManagementError.unsupported("本安装方案当前仅适配 MU5250 B28。") }
        if let expected = profile.fingerprint, expected != actual { throw ManagementError.deviceChanged }
        profile.fingerprint = actual
        profile.model = "MU5250"
    }

    private func persistCredentials(_ devices: DeviceStore) throws {
        if secret.isEmpty {
            secret = try FactoryEncryption.randomBytes(count: 24).map { String(format: "%02x", $0) }.joined()
        }
        try devices.saveVerified(profile, secret: secret, webPassword: webPassword, factoryPassword: factoryPassword)
    }

    func inspect(_ devices: DeviceStore) async {
        await operation("正在核对型号、身份和服务状态…") {
            if simulation {
                profile.fingerprint = "demo-deployment"
                if phase == "new" { phase = route == .factory ? "factoryDetected" : "ready" }
                message = "演示：MU5250 B28，\(route.rawValue)。演示过程不会连接或改写设备。"
                return
            }
            if route == .factory {
                let actual = try await factoryClient.deploymentIdentity()
                if let expected = profile.fingerprint, expected != actual.fingerprint { throw ManagementError.deviceChanged }
                identity = actual
                profile.fingerprint = actual.fingerprint
                profile.model = "MU5250"
                if phase == "new" { phase = "factoryDetected" }
                message = "已验证 MU5250 B28。首次开放请使用电脑辅助流程；当前不开放手机恢复写入。"
            } else {
                let api = try webAPI()
                try await verify(api)
                let state = try await api.mihomoStatus()
                let existing = try await api.loadConfig()
                guard !state.running, existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ownsConfiguration(existing) else {
                    message = "设备已有代理或配置。请选择“已部署 Mihomo”并填写已有 Secret；未覆盖任何凭据和配置。"
                    return
                }
                try persistCredentials(devices)
                if !state.running && phase == "new" { try savePhase("ready") }
                if ["coreRequested", "dataRequested"].contains(phase) {
                    let path = phase == "coreRequested" ? "api/mihomo/install/status" : "api/mihomo/data/update/status"
                    let remote = try await api.management("GET", path, body: nil).object("data")?.string("state")
                    if ["failed", "canceled", "idle"].contains(remote ?? "") {
                        try savePhase("ready")
                    }
                }
                message =
                    state.running
                    ? "代理已在运行。首次部署不会覆盖现有服务，请使用代理配置或更新管理。"
                    : "身份已验证。导入 Mihomo YAML 后可安装；已有配置会阻止首次部署覆盖。"
            }
        }
    }

    func prepareFactory(_ devices: DeviceStore) async {
        await operation("备份并准备离线首次安装包…") {
            try requireWritable(devices)
            if simulation {
                phase = "factoryPrepared"
                message = "演示：原厂备份与安装包已校验。实际流程还需保存原件并确认重启。"
                return
            }
            throw ManagementError.unsupported("纯 Wi-Fi 首次初始化尚未完成实机验收，请先通过电脑安装 WebSSH。")
        }
    }

    func applyFactory(_ devices: DeviceStore, restoreOriginal: Bool = false) async {
        await operation(restoreOriginal ? "正在提交原始备份恢复…" : "正在提交首次安装包…") {
            try requireWritable(devices)
            if simulation {
                phase = restoreOriginal ? "factoryRestored" : "factorySubmitted"
                message = "演示：设备正在重启。连接设备 Wi-Fi 后继续检查管理通道。"
                return
            }
            throw ManagementError.unsupported("原厂首次安装与恢复暂不开放手机写入，请使用已验证的电脑流程。")
        }
    }

    func reconnect(_ devices: DeviceStore) async {
        await operation("正在检查管理通道…") {
            if simulation {
                phase = "ready"
                route = .managed
                message = "演示：WebSSH 初始化和身份验证通过，可继续安装 Mihomo。"
                return
            }
            let api = try webAPI()
            try await verify(api)
            try persistCredentials(devices)
            try savePhase("ready")
            route = .managed
            message = "WebSSH 认证与设备身份一致。管理通道已就绪，可以继续安装代理。"
        }
    }

    /// 首次安装只允许没有运行服务、没有现成配置的设备。已有二进制可沿用，避免重复下载。
    func installProxy(_ devices: DeviceStore) async {
        await operation("正在检查首次安装条件…") {
            try requireWritable(devices)
            guard ["ready", "coreRequested", "dataRequested", "configWritten"].contains(phase) else {
                throw ManagementError.invalid("请先检查设备；已校验的配置可直接进入启用步骤。")
            }
            if simulation {
                guard !source.isEmpty else { throw ManagementError.invalid("请先导入配置，或选择演示配置。") }
                for step in ["核心安装", "规则数据", "配置校验"] {
                    message = "演示：\(step)"
                    try await Task.sleep(for: .milliseconds(350))
                }
                phase = "validated"
                message = "演示：配置校验通过，尚未启用代理。"
                return
            }
            let api = try webAPI()
            try await verify(api)
            guard profile.fingerprint != nil else { throw ManagementError.deviceChanged }
            let state = try await api.mihomoStatus()
            guard !state.running else { throw ManagementError.invalid("代理已在运行，首次部署不会覆盖它。") }
            let existingConfig = try await api.loadConfig()
            guard existingConfig.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ownsConfiguration(existingConfig) else {
                throw ManagementError.invalid("设备已有配置。请使用Mihomo → 配置进行管理，首次部署不会覆盖。")
            }
            profile.mihomoPort = 9090
            try persistCredentials(devices)
            let content = try DeploymentConfiguration.make(source: source, host: profile.host, secret: secret)
            let previousConfig = existingConfig
            let directory = try await api.coreDirectory()
            guard directory == "/data/kano_plugins/mihomo" else {
                throw ManagementError.unsupported("安装目录与当前适配方案不一致，未写入。")
            }
            let preflight = try await api.runMaintenanceScript(
                """
                set -eu
                test "$(id -u)" = 0
                test "$(uname -m)" = aarch64
                for tool in iptables ip6tables ipset ip sha256sum; do command -v "$tool" >/dev/null; done
                test -c /dev/net/tun
                available=$(df -Pk /data | awk 'NR==2 { print $4; }')
                case "$available" in ''|*[!0-9]*) exit 1;; esac
                test "$available" -ge 262144
                echo FLOWDECK_READY
                """)
            guard preflight.contains("FLOWDECK_READY") else { throw ManagementError.unsupported("架构、TUN 或可用空间检查未通过。") }
            let revision = devices.clientRevision
            try savePhase("coreRequested")
            try await OfflineDeployment.install(api: api, id: profile.id, resources: offlineResources()) {
                try self.requireWritable(devices)
                guard revision == devices.clientRevision else { throw ManagementError.deviceChanged }
                try await self.verify(api)
                guard !(try await api.mihomoStatus()).running,
                    try await api.loadConfig() == previousConfig
                else { throw ManagementError.invalid("安装期间设备配置已变化或代理已启动，没有覆盖。") }
            } progress: { label, value in
                self.message = label
                self.progress = value
            }
            try await verifyArtifacts(api)
            try requireWritable(devices)
            try await verify(api)
            guard try await api.loadConfig() == previousConfig else {
                throw ManagementError.invalid("安装期间设备配置已变化，没有覆盖。")
            }
            // 保存候选配置不启动代理；检查失败可修改文件再重试，不报告安装成功。
            configDigest = DeviceIdentity.digest(Data(content.utf8))
            try savePhase("configWritten")
            try await api.saveConfig(content)
            _ = try await api.runMaintenanceScript("chmod 600 /data/kano_plugins/mihomo/config.yaml")
            // B28 原厂把北京时间写进 UTC，系统时间普遍偏快约 8 小时；原部署方案不改系统时间，
            // 由配置中的 NTP（write-to-system: false）在运行时校正。mihomo -t 不依赖时间，这里只提示不拦截。
            let clockNote = await clockOffsetNote(api)
            let check = try await api.checkConfig()
            guard check.ok else { throw ManagementError.invalid("配置校验未通过：" + check.message) }
            try savePhase("validated")
            message = "核心与配置校验通过。尚未接管流量，点击启用后验证控制接口与出口。" + clockNote
        }
    }

    /// 首次安装固定为归档中审核过的 ARM64 核心和透明代理脚本。
    /// 随 App 固定携带的资源执行前仍再次检查，防止安装后被其他管理端替换。
    private func verifyArtifacts(_ api: any WebSSHAPI) async throws {
        // 57 MB 核心的摘要可能超过 WebSSH 单次调用的 5 秒上限，走后台任务。
        let output = try await api.runBackgroundScript(
            directory: OfflineDeployment.jobDirectory, name: "verify-artifacts", title: "核心与脚本复核",
            script: """
                cd /data/kano_plugins/mihomo || exit 1
                if echo 'c80df2ca5159567804da883401e0118908fc1155e05df2baf3dbd4d3ecfc3754  mihomo
                2ff8b4a960c63aee18a314d92173f3c0b25e8373ff090353865a2a5da174fdbb  mm.sh' | sha256sum -c - >/dev/null 2>&1; then
                    echo FLOWDECK_ARTIFACTS_VERIFIED
                fi
                """)
        guard output.contains("FLOWDECK_ARTIFACTS_VERIFIED") else {
            throw ManagementError.unsupported("核心或脚本与本版适配资源不一致，未启用代理。当前支持 Mihomo v1.19.32；资源变化后需更新 App 适配。")
        }
    }

    /// 读取失败也不阻断安装，只是不给提示。
    private func clockOffsetNote(_ api: any WebSSHAPI) async -> String {
        guard let output = try? await api.runMaintenanceScript("date +%s"),
            let epoch = Double(output.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return "" }
        let offset = abs(epoch - Date().timeIntervalSince1970)
        guard offset >= 120 else { return "" }
        let hours = offset / 3600
        let amount = hours >= 1 ? String(format: "约 %.1f 小时", hours) : "\(Int(offset / 60)) 分钟"
        return "设备时间与手机相差\(amount)，启用后由 Mihomo NTP 校正，不修改系统时间；若出口验证失败，可再手动同步。"
    }

    private func ownsConfiguration(_ content: String) -> Bool {
        guard let configDigest else { return false }
        return DeviceIdentity.digest(Data(content.utf8)) == configDigest
    }

    /// 设备时间同步是独立、显式的操作，不通过“检查设备”偷偷修改时钟。
    func synchronizeClock(_ devices: DeviceStore) async {
        await operation("同步手机时间") {
            try requireWritable(devices)
            guard phase != "new" else { throw ManagementError.invalid("请先验证设备身份。") }
            if simulation {
                message = "演示：设备时间已同步"
                return
            }
            let api = try webAPI()
            try await verify(api)
            let result = try await NetworkDiagnostics.synchronizeClock(api: api)
            guard result.outcome == .passed else { throw ManagementError.unconfirmed(result.detail) }
            message = result.detail
        }
    }

    func activate(_ devices: DeviceStore) async {
        await operation("启动并验证代理…") {
            try requireWritable(devices)
            guard phase == "validated" || phase == "activationRequested" else { throw ManagementError.invalid("请先完成配置校验。") }
            if simulation {
                phase = "complete"
                message = "演示完成：控制接口与 HTTP 出口通过。实际手机联网和 UDP 仍需单独验证。"
                return
            }
            let api = try webAPI()
            try await verify(api)
            guard ownsConfiguration(try await api.loadConfig()) else {
                throw ManagementError.invalid("配置已被其他管理端修改，首次部署已停止。请到Mihomo → 配置中管理并校验。")
            }
            try await verifyArtifacts(api)
            guard (try await api.checkConfig()).ok else { throw ManagementError.invalid("设备配置校验失败，未启动。") }
            try savePhase("activationRequested")
            let state = try await api.mihomoStatus()
            var autostartRequested = false
            do {
                if !state.running { _ = try await api.control(.start) }
                guard let url = profile.mihomoURL else { throw ManagementError.invalid("代理地址无效。") }
                _ = try await MihomoClient(baseURL: url, secret: secret).version()
                guard try await api.connectivity() else { throw ManagementError.unconfirmed("设备 HTTP 出口未验证通过。") }
                try requireWritable(devices)
                try await verify(api)
                autostartRequested = true
                try await api.setAutostart(true)
                try savePhase("complete")
                // 暂存与后台任务文件只在验收通过后清理；清理失败不影响已完成的部署。
                _ = try? await api.runMaintenanceScript(OfflineDeployment.cleanupScript)
                message = "控制 API、HTTP 出口已通过，自启动已开启。请用手机实际访问验证；UDP 未做端到端检测。"
            } catch {
                // 补偿前也必须核对身份：Wi-Fi 换网不能把停用命令发给同 IP 的另一台设备。
                let originalError = error.localizedDescription
                var recovery = "保留原本运行的服务。"
                do {
                    try await verify(api)
                    if autostartRequested { try await api.setAutostart(state.autostart) }
                    if !state.running {
                        _ = try await api.control(.stop)
                        let stopped = try await api.mihomoStatus()
                        recovery = stopped.running ? "停用尚未确认，请检查设备。" : "已确认停用本次启动的代理。"
                    }
                } catch {
                    recovery = "未能确认恢复状态，请重新连接原设备并检查服务。"
                }
                throw ManagementError.unconfirmed("验收未通过。" + recovery + " 原因：" + originalError)
            }
        }
    }
}
