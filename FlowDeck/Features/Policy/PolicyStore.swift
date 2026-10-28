import Foundation
import Observation

/// 分流页和总览共用的代理状态。所有写入都先调接口、再回读确认。
@MainActor
@Observable
final class PolicyStore {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded(Date)
        case failed(String)
    }

    private(set) var proxies: [String: MihomoProxy] = [:]
    private(set) var mode: OutboundMode = .rule
    private(set) var state: LoadState = .idle
    private(set) var coreVersion: String?

    var expanded: Set<String> = []
    /// 单组展开由调用方包在 withAnimation 里；批量展开、深链接定位直接赋值，不播放逐组动画。
    func toggleExpanded(_ name: String) {
        if expanded.contains(name) {
            expanded.remove(name)
        } else {
            expanded.insert(name)
        }
    }

    func setExpanded(_ groups: Set<String>) {
        expanded = groups
    }

    var revealGroup: String?
    private(set) var testing: Set<String> = []
    private(set) var selecting: Set<String> = []
    private(set) var testedAt: [String: Date] = [:]
    private var deviceID: String
    private let defaults: UserDefaults
    private(set) var preferredGroup: String?

    var primaryGroup: String? {
        PreferredPolicyGroup.resolve(in: proxies, mode: mode, preferred: preferredGroup)
    }

    var availablePrimaryGroups: [MihomoProxy] {
        Self.orderedGroups(from: proxies, mode: .rule, hidden: [])
    }

    func setPreferredGroup(_ name: String?) {
        guard name == nil || availablePrimaryGroups.contains(where: { $0.name == name }) else { return }
        preferredGroup = name
        PreferredPolicyGroup.save(name, deviceID: deviceID, defaults: defaults)
    }
    var favoriteGroups: Set<String> = [] {
        didSet { defaults.set(Array(favoriteGroups), forKey: "favoriteGroups." + deviceID) }
    }

    var sortByDelay: Set<String> = []
    /// 不在列表里单独占一行的组。默认隐藏转换时额外生成的“自动选择”，和 Surge 保持一致；它仍是 Proxies 的选项。
    var hiddenGroups: Set<String> {
        didSet { defaults.set(Array(hiddenGroups), forKey: "hiddenGroups." + deviceID) }
    }
    /// 最近一次操作的结果，界面用它弹提示。
    var notice: String? {
        didSet { noticeID = UUID() }
    }
    /// 同文案的连续操作也重新计时，旧任务不能清除新的提示。
    private(set) var noticeID = UUID()

    var authorizeWrite: (() async throws -> Void)?
    private var generation = 0
    private var api: any MihomoAPI

    init(api: any MihomoAPI, deviceID: String = "default", defaults: UserDefaults = .standard) {
        self.api = api
        self.deviceID = deviceID
        self.defaults = defaults
        preferredGroup = PreferredPolicyGroup.saved(deviceID: deviceID, defaults: defaults)
        hiddenGroups = Set(defaults.stringArray(forKey: "hiddenGroups." + deviceID) ?? ["自动选择"])
        favoriteGroups = Set(defaults.stringArray(forKey: "favoriteGroups." + deviceID) ?? [])
    }

    func use(_ api: any MihomoAPI, deviceID: String = "default") {
        self.api = api
        self.deviceID = deviceID
        preferredGroup = PreferredPolicyGroup.saved(deviceID: deviceID, defaults: defaults)
        hiddenGroups = Set(defaults.stringArray(forKey: "hiddenGroups." + deviceID) ?? ["自动选择"])
        favoriteGroups = Set(defaults.stringArray(forKey: "favoriteGroups." + deviceID) ?? [])
        generation += 1
        testing.removeAll()
        selecting.removeAll()
        testedAt = [:]
        mode = .rule
        proxies = [:]
        expanded.removeAll()
        revealGroup = nil
        sortByDelay.removeAll()
        notice = nil
        coreVersion = nil
        state = .idle
    }

    var client: any MihomoAPI { api }

    // MARK: 派生数据

    /// 按 GLOBAL 的成员顺序（即配置文件顺序）列出策略组；全局模式下 GLOBAL 排在最上面。
    var orderedGroups: [MihomoProxy] {
        Self.orderedGroups(from: proxies, mode: mode, hidden: hiddenGroups)
    }

    nonisolated static func orderedGroups(from proxies: [String: MihomoProxy], mode: OutboundMode, hidden: Set<String>) -> [MihomoProxy] {
        let globalOrder = proxies["GLOBAL"]?.all ?? []
        var seen = Set<String>()
        var out: [MihomoProxy] = []
        if mode == .global, let g = proxies["GLOBAL"] {
            out.append(g)
            seen.insert("GLOBAL")
        }
        for name in globalOrder {
            guard let p = proxies[name], p.isGroup, !p.hidden, !hidden.contains(name), !seen.contains(name) else { continue }
            out.append(p)
            seen.insert(name)
        }
        // GLOBAL 里没列出的组（理论上不会出现）按名字补在最后。
        for p in proxies.values.sorted(by: { $0.name < $1.name })
        where p.isGroup && p.name != "GLOBAL" && !p.hidden && !hidden.contains(p.name) && !seen.contains(p.name) {
            out.append(p)
        }
        return out
    }

    /// 沿着 now 一路找到最终节点；DIRECT / REJECT 也算终点。
    func resolve(_ name: String) -> MihomoProxy? {
        Self.resolve(name, in: proxies)
    }

    nonisolated static func resolve(_ name: String, in proxies: [String: MihomoProxy]) -> MihomoProxy? {
        var current = proxies[name]
        var visited = Set<String>()
        while let proxy = current, proxy.isGroup {
            guard visited.insert(proxy.name).inserted, let next = proxy.now else { return nil }
            current = proxies[next]
        }
        return current
    }

    func delay(of name: String) -> Int? {
        guard let p = proxies[name] else { return nil }
        if p.isGroup { return resolve(name).flatMap { $0.isBuiltin ? nil : $0.lastDelay } }
        return p.isBuiltin ? nil : p.lastDelay
    }

    /// 常用策略组的选中节点。实际出口需独立探测，不能由策略组名推断。
    var exitNode: MihomoProxy? {
        guard let primaryGroup, let node = resolve(primaryGroup), !node.isBuiltin, !node.isGroup else { return nil }
        return node
    }

    // MARK: 读取

    private var refreshSequence = 0

    func refresh() async {
        refreshSequence += 1
        let sequence = refreshSequence
        let revision = generation
        if proxies.isEmpty { state = .loading }
        do {
            async let p = api.proxies()
            async let c = api.config()
            let (list, cfg) = try await (p, c)
            guard revision == generation, sequence == refreshSequence else { return }
            proxies = list
            mode = cfg.mode
            state = .loaded(Date())
            if coreVersion == nil {
                let version = try? await api.version().version
                guard revision == generation, sequence == refreshSequence else { return }
                coreVersion = version
            }
        } catch {
            guard revision == generation, sequence == refreshSequence else { return }
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: 写入

    /// 切换策略组的选择。默认保留已有连接；closeExisting 为 true 时断开经过该组的连接。
    func select(group: String, option: String, closeExisting: Bool = false) async {
        let lease: UUID
        do { lease = try DeviceOperationGate.begin("切换代理策略") } catch {
            notice = error.localizedDescription
            return
        }
        defer { DeviceOperationGate.end(lease) }

        guard let g = proxies[group], g.isSelectable else {
            notice = MihomoError.notSelectable(group).errorDescription
            return
        }
        guard !selecting.contains(group) else { return }
        let revision = generation
        let client = api
        selecting.insert(group)
        defer { if revision == generation { selecting.remove(group) } }
        do {
            guard let authorizeWrite else { throw ManagementError.invalid("写入授权尚未准备。") }
            try await authorizeWrite()
            guard revision == generation else { return }
            try await client.select(group: group, proxy: option)
            guard revision == generation else { return }
            var closed = 0
            var closeError: String?
            if closeExisting {
                do { closed = try await client.closeConnections(through: group) } catch { closeError = "节点已切换，旧连接未全部关闭，请到连接页检查" }
            }
            guard revision == generation else { return }
            await refresh()
            guard revision == generation else { return }
            if case .failed = state {
                notice = "已发送切换，回读失败，请刷新确认"
            } else if proxies[group]?.now == option {
                notice = closeError ?? (closeExisting ? "\(group) → \(Self.shortName(option))，已断开 \(closed) 个旧连接" : "\(group) → \(Self.shortName(option))")
            } else {
                notice = "已发送切换，设备尚未确认所选节点"
            }
        } catch {
            guard revision == generation else { return }
            notice = error.localizedDescription
        }
    }

    func setMode(_ newMode: OutboundMode) async {
        let lease: UUID
        do { lease = try DeviceOperationGate.begin("切换代理策略") } catch {
            notice = error.localizedDescription
            return
        }
        defer { DeviceOperationGate.end(lease) }

        let revision = generation
        let client = api
        do {
            guard let authorizeWrite else { throw ManagementError.invalid("写入授权尚未准备。") }
            try await authorizeWrite()
            guard revision == generation else { return }
            try await client.setMode(newMode)
            guard revision == generation else { return }
            await refresh()
            guard revision == generation else { return }
            if case .failed = state { notice = "已发送模式切换，回读失败，请刷新确认" } else { notice = mode == newMode ? "已切换为\(newMode.title)" : "已发送切换，但回读到的仍是\(mode.title)" }
        } catch {
            guard revision == generation else { return }
            notice = error.localizedDescription
        }
    }

    /// 测试单组延迟；失败不更新测试时间，也不能被批量入口覆盖为成功。
    @discardableResult
    func test(group: String) async -> Bool {
        guard !testing.contains(group) else { return false }
        let revision = generation
        let client = api
        testing.insert(group)
        defer { if revision == generation { testing.remove(group) } }
        do {
            let results = try await client.groupDelay(group: group, url: DelayTest.url, timeoutMs: DelayTest.timeoutMs)
            guard revision == generation else { return false }
            await refresh()
            guard revision == generation else { return false }
            testedAt[group] = Date()
            let available = results.values.filter { $0 > 0 }.count
            notice = "延迟测试完成：\(available)/\(results.count) 个响应；不代表带宽"
            return true
        } catch {
            guard revision == generation else { return false }
            notice = "延迟测试失败：" + error.localizedDescription
            return false
        }
    }

    func testAll() async {
        guard let primaryGroup else {
            notice = "请先在更多菜单中选择常用策略组。"
            return
        }
        await test(group: primaryGroup)
    }

    nonisolated static func shortName(_ name: String) -> String {
        if let r = name.range(of: " | ") { return String(name[r.upperBound...]) }
        return name
    }
}
