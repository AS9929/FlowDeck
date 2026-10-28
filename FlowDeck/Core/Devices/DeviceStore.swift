import Foundation
import Observation

/// 设备库与当前会话的唯一可观察入口，统一处理迁移、选择、凭据及访问门槛。
@MainActor
@Observable
final class DeviceStore {
    private(set) var devices: [DeviceProfile] = []
    let defaults: UserDefaults
    private var storedReadOnly: Bool
    var readOnly: Bool {
        get { storedReadOnly }
        set {
            guard allowMutation() else { return }
            storedReadOnly = newValue
            defaults.set(newValue, forKey: "management.readOnly")
        }
    }
    private(set) var currentID: UUID?
    private var storedDemoMode = false
    /// 变更演示状态也会替换客户端，必须遵守操作互斥。
    var demoMode: Bool {
        get { storedDemoMode }
        set {
            guard allowMutation() else { return }
            storedDemoMode = newValue
            defaults.set(newValue, forKey: Keys.demo)
            defaults.set(true, forKey: Keys.explicitDemo)
            persist()
            rebuildClient()
        }
    }
    private(set) var connectionIssue: DeviceAccessIssue?
    private var opaqueRecords: [Any] = []
    private var originalRecords: [UUID: [String: Any]] = [:]
    private var corruptLibrary = false
    private(set) var storageWarning: String?

    private(set) var client: any MihomoAPI = DemoMihomo.shared
    private(set) var webClient: any WebSSHAPI = DemoWebSSH.shared
    /// 每次换设备或换凭据都会变化，页面据此重新加载。
    private(set) var clientRevision = 0
    private(set) var matchingMessage: String?
    private(set) var reachableAt: [UUID: Date] = [:]
    private(set) var matchingAt: Date?

    /// 只接收已通过身份校验的实时快照；清除过期的自动识别失败提示。
    func recordReachable() {
        guard !demoMode, let currentID else { return }
        reachableAt[currentID] = Date()
        matchingMessage = nil
    }

    var storageID: String { demoMode ? "demo" : current?.fingerprint ?? currentID?.uuidString ?? "unpaired" }

    func factoryPassword(for device: DeviceProfile) -> String {
        KeychainStore.get(account: device.factoryPasswordAccount) ?? ""
    }

    func saveFactoryPassword(_ value: String, for device: DeviceProfile) {
        guard allowMutation() else { return }
        KeychainStore.set(value, account: device.factoryPasswordAccount)
    }

    /// 原厂读取成功后的凭据提交，和记录修改使用相同操作互斥及会话边界。
    func saveFactoryPasswordChecked(_ value: String, session: DeviceSession) throws {
        try session.validate(in: self)
        guard let profile = session.profile, !session.demo else { return }
        // 已保存的同一密码不构成变更；读取不会因其他页面持有写锁而失败。
        guard KeychainStore.get(account: profile.factoryPasswordAccount) != value else { return }
        try requireMutation()
        try KeychainStore.setChecked(value, account: profile.factoryPasswordAccount)
    }

    /// 按当前可达设备的指纹匹配，不能只依靠所有 U60 共用的 192.168.0.1。
    func matchConnectedDevice() async {
        guard !demoMode, !devices.isEmpty else { return }
        let revision = clientRevision
        let startedAt = Date()
        matchingMessage = nil
        var matches: [DeviceProfile] = []
        var failures = 0
        var identityMismatch = false
        for device in devices where device.id == currentID && device.fingerprint != nil {
            guard !Task.isCancelled, revision == clientRevision else { return }
            guard let client = probeManagementClient(device, password: webPassword(for: device)),
                let snapshot = try? await client.snapshot()
            else {
                failures += 1
                continue
            }
            if snapshot.identityFingerprint == device.fingerprint {
                matches.append(device)
                reachableAt[device.id] = Date()
            } else {
                identityMismatch = true
            }
        }
        guard revision == clientRevision else { return }
        matchingAt = Date()
        if matches.count == 1 {
            matchingMessage = nil
            // 识别只确认手动选择的设备，不改变任何打开的编辑页面的目标。
        } else {
            // 自动检查失败期间可能已有正常轮询返回，不能用旧失败覆盖新的在线证据。
            if let currentID, let latest = reachableAt[currentID], latest >= startedAt { return }
            if !matches.isEmpty {
                matchingMessage = "多份连接记录对应同一台设备，请手动选择。"
            } else if identityMismatch {
                matchingMessage = "管理地址可达，但身份与保存记录不同。请添加这台设备。"
            } else if failures > 0 {
                matchingMessage = "未能读取设备身份。请检查本地网络权限、管理地址及 WebSSH 凭据后重试。"
            } else {
                matchingMessage = "保存记录缺少硬件身份，请编辑连接并重新验证。"
            }
        }
    }

    private enum Keys {
        static let devices = "devices.v1"
        static let current = "devices.current"
        static let demo = "demoMode"
        static let explicitDemo = "demo.explicitSelection.v1"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storedReadOnly = defaults.bool(forKey: "management.readOnly")
        // 单条迁移失败不能清空整库；未来字段及不认识的记录原样保留。
        if let data = defaults.data(forKey: Keys.devices) {
            if let rows = (try? JSONSerialization.jsonObject(with: data)) as? [Any] {
                for row in rows {
                    if let object = row as? [String: Any],
                        let encoded = try? JSONSerialization.data(withJSONObject: object),
                        let profile = try? JSONDecoder().decode(DeviceProfile.self, from: encoded),
                        !devices.contains(where: { $0.id == profile.id })
                    {
                        devices.append(profile)
                        originalRecords[profile.id] = object
                    } else {
                        opaqueRecords.append(row)
                    }
                }
                if !opaqueRecords.isEmpty { storageWarning = "部分设备记录无法识别，已保留原始数据。" }
            } else {
                corruptLibrary = true
                storageWarning = "设备库无法读取，已保护原始数据；请从备份恢复，不能直接覆盖。"
            }
        }
        if let raw = defaults.string(forKey: Keys.current) {
            currentID = UUID(uuidString: raw)
        }
        // 旧版会自动开启演示，迁移时不把这个默认值当作用户选择。
        // launch argument 仅用于明确选择演示的 UI 测试和预览。
        let explicitSelection =
            defaults.bool(forKey: Keys.explicitDemo)
            || defaults.volatileDomain(forName: UserDefaults.argumentDomain)[Keys.demo] != nil
        storedDemoMode = explicitSelection && defaults.bool(forKey: Keys.demo)
        if currentID == nil { currentID = devices.first?.id }
        rebuildClient()
    }

    var current: DeviceProfile? { devices.first { $0.id == currentID } }

    var needsDeployment: Bool {
        guard !demoMode, let current, let record = DeploymentFiles.load(current.id) else { return false }
        return record.fingerprint == current.fingerprint && record.phase != "complete"
    }

    var isConfigured: Bool {
        guard let d = current else { return false }
        return !(KeychainStore.get(account: d.secretAccount) ?? "").isEmpty
    }

    var isWebConfigured: Bool {
        guard let d = current else { return false }
        return !webPassword(for: d).isEmpty
    }

    /// 演示模式或真实设备已配置好对应凭据时，相关功能才可用。
    var webAvailable: Bool { accessIssue(for: .webSSH) == nil }
    var mihomoAvailable: Bool { accessIssue(for: .mihomo) == nil }

    func accessIssue(for requirement: DeviceAccessRequirement) -> DeviceAccessIssue? {
        if let connectionIssue, !demoMode { return connectionIssue }
        return DeviceAccessIssue.resolve(
            requirement: requirement, demo: demoMode, hasDevice: current != nil,
            verified: current?.needsVerification == false,
            hasMihomo: isConfigured, hasWebSSH: isWebConfigured
        )
    }

    /// 页面和系统入口共用前置检查；写入仍须额外读取设备指纹，不能仅凭保存记录授权。
    func requireAccess(_ requirement: DeviceAccessRequirement) throws {
        if let issue = accessIssue(for: requirement) {
            throw ManagementError.invalid(issue.message)
        }
    }

    func secret(for device: DeviceProfile) -> String {
        KeychainStore.get(account: device.secretAccount) ?? ""
    }

    func webPassword(for device: DeviceProfile) -> String {
        KeychainStore.get(account: device.webPasswordAccount) ?? ""
    }

    func save(_ device: DeviceProfile, secret: String, webPassword: String) {
        guard allowMutation() else { return }
        KeychainStore.set(webPassword, account: device.webPasswordAccount)
        save(device, secret: secret)
    }

    func save(_ device: DeviceProfile, secret: String) {
        guard allowMutation() else { return }
        if let i = devices.firstIndex(where: { $0.id == device.id }) {
            devices[i] = device
        } else {
            devices.append(device)
        }
        KeychainStore.set(secret, account: device.secretAccount)
        currentID = device.id
        persist()
        rebuildClient()
    }

    /// 三路凭据全部写入成功后才发布设备记录；部分失败时恢复原凭据。
    func saveVerified(_ device: DeviceProfile, secret: String, webPassword: String, factoryPassword: String) throws {
        try requireMutation()
        let values = [(device.secretAccount, secret), (device.webPasswordAccount, webPassword), (device.factoryPasswordAccount, factoryPassword)]
        let previous = values.map { ($0.0, KeychainStore.get(account: $0.0) ?? "") }
        do {
            for (account, value) in values { try KeychainStore.setChecked(value, account: account) }
        } catch {
            for (account, value) in previous { try? KeychainStore.setChecked(value, account: account) }
            throw error
        }
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
        currentID = device.id
        matchingMessage = nil
        reachableAt[device.id] = Date()
        persist()
        if demoMode { demoMode = false } else { rebuildClient() }
    }

    func remove(_ device: DeviceProfile) {
        guard allowMutation() else { return }
        let storageID = device.fingerprint ?? device.id.uuidString
        let lastReference = !devices.contains {
            $0.id != device.id && ($0.fingerprint ?? $0.id.uuidString) == storageID
        }
        do {
            if lastReference { try DeviceLocalData.removeShared(storageID: storageID, defaults: defaults) }
            for account in [device.secretAccount, device.webPasswordAccount, device.factoryPasswordAccount] {
                try KeychainStore.setChecked("", account: account)
            }
        } catch {
            matchingMessage = "本机数据未完全清除，设备记录已保留，请重试。" + error.localizedDescription
            return
        }
        originalRecords.removeValue(forKey: device.id)
        devices.removeAll { $0.id == device.id }
        if currentID == device.id { currentID = devices.first?.id }
        persist()
        rebuildClient()
    }

    func select(_ device: DeviceProfile) {
        guard allowMutation(), devices.contains(where: { $0.id == device.id }) else { return }
        matchingMessage = nil
        guard currentID != device.id else { return }
        currentID = device.id
        persist()
        rebuildClient()
    }

    /// 用给定的地址和 Secret 临时建一个客户端，只做只读的连接测试。
    func probeClient(host: String, port: Int, secret: String) -> MihomoClient? {
        guard let url = URL(string: "http://\(host):\(port)") else { return nil }
        return MihomoClient(baseURL: url, secret: secret)
    }

    func probeWebClient(host: String, port: Int, user: String, password: String) -> WebSSHClient? {
        guard let url = URL(string: "http://\(host):\(port)") else { return nil }
        return WebSSHClient(baseURL: url, username: user, password: password)
    }

    /// 根据保存的管理后端构造客户端；已绑定设备的 UFI 请求始终携带期望身份。
    func probeManagementClient(_ device: DeviceProfile, password: String) -> (any WebSSHAPI)? {
        BackendRegistry.descriptor(for: device.backend)?.makeClient(
            device, password, secret(for: device))
    }

    var usesUFI: Bool {
        !demoMode && current.flatMap { BackendRegistry.descriptor(for: $0.backend) }?.presentation == .ufi
    }

    /// 读取一次客户端与目标；异步验证及后续执行必须复用此上下文。
    func session() -> DeviceSession {
        DeviceSession(
            profile: current, revision: clientRevision, demo: demoMode,
            mihomo: client, management: webClient)
    }

    private func requireMutation() throws {
        try DeviceOperationGate.requireMutationAccess()
        guard !corruptLibrary else {
            throw ManagementError.invalid(storageWarning ?? "设备库需要恢复。")
        }
    }

    private func allowMutation() -> Bool {
        do {
            try requireMutation()
            return true
        } catch {
            matchingMessage = error.localizedDescription
            return false
        }
    }

    private func rebuildClient() {
        connectionIssue = nil
        if demoMode {
            client = DemoMihomo.shared
            webClient = DemoWebSSH.shared
        } else {
            // 先失效再构造，任何失败都不能留下上一台设备或演示客户端。
            client = UnavailableClient()
            webClient = UnavailableClient()
            if let device = current {
                if BackendRegistry.descriptor(for: device.backend) == nil || device.schemaVersion > 1 {
                    connectionIssue = .unsupportedBackend
                } else if let url = device.mihomoURL,
                    let management = probeManagementClient(device, password: webPassword(for: device))
                {
                    client = MihomoClient(baseURL: url, secret: secret(for: device))
                    webClient = management
                } else {
                    connectionIssue = .invalidEndpoint
                }
            }
        }
        clientRevision += 1
    }

    private func persist() {
        guard !corruptLibrary else { return }
        var rows = opaqueRecords
        for device in devices {
            guard let data = try? JSONEncoder().encode(device),
                let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            var original = originalRecords[device.id] ?? [:]
            // 只更新本版本拥有的字段，保留未来适配器写入的扩展信息。
            for (key, value) in fields { original[key] = value }
            for key in ["fingerprint", "model"] where fields[key] == nil { original.removeValue(forKey: key) }
            rows.append(original)
        }
        if let data = try? JSONSerialization.data(withJSONObject: rows) {
            defaults.set(data, forKey: Keys.devices)
        }
        defaults.set(currentID?.uuidString, forKey: Keys.current)
    }
}
