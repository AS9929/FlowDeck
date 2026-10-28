import XCTest

@testable import FlowDeck

final class MihomoTests: XCTestCase {
    /// 节选自 Mihomo `GET /proxies` 的返回格式。
    private let proxiesJSON = """
        {"proxies":{
          "GLOBAL":{"name":"GLOBAL","type":"Selector","now":"Proxies","all":["DIRECT","REJECT","Proxies","自动选择","日本","Claude","CN","Final"],"history":[]},
          "Proxies":{"name":"Proxies","type":"Selector","now":"🇯🇵 [华为沪日] | IDCF 东一","all":["自动选择","🇯🇵 [华为沪日] | IDCF 东一","🇯🇵 [华为沪日] | IDCF Osaka"],"history":[]},
          "自动选择":{"name":"自动选择","type":"URLTest","now":"🇯🇵 [华为沪日] | IDCF Osaka","all":["🇯🇵 [华为沪日] | IDCF 东一","🇯🇵 [华为沪日] | IDCF Osaka"],"history":[]},
          "日本":{"name":"日本","type":"Selector","now":"🇯🇵 [华为沪日] | IDCF Osaka","all":["🇯🇵 [华为沪日] | IDCF 东一","🇯🇵 [华为沪日] | IDCF Osaka"],"history":[]},
          "Claude":{"name":"Claude","type":"Selector","now":"日本","all":["Proxies","日本"],"history":[],"icon":""},
          "CN":{"name":"CN","type":"Selector","now":"DIRECT","all":["DIRECT"],"history":[]},
          "Final":{"name":"Final","type":"Selector","now":"Proxies","all":["Proxies","DIRECT"],"history":[],"hidden":false},
          "DIRECT":{"name":"DIRECT","type":"Direct","history":[]},
          "REJECT":{"name":"REJECT","type":"Reject","history":[]},
          "🇯🇵 [华为沪日] | IDCF 东一":{"name":"🇯🇵 [华为沪日] | IDCF 东一","type":"Shadowsocks","udp":true,"history":[{"time":"2026-10-04T10:00:00Z","delay":72}]},
          "🇯🇵 [华为沪日] | IDCF Osaka":{"name":"🇯🇵 [华为沪日] | IDCF Osaka","type":"Shadowsocks","history":[{"time":"2026-10-04T10:00:00Z","delay":0}]}
        }}
        """

    private func decode() throws -> [String: MihomoProxy] {
        try JSONDecoder().decode(ProxiesResponse.self, from: Data(proxiesJSON.utf8)).proxies
    }

    func testDecodesGroupsAndNodes() throws {
        let p = try decode()
        XCTAssertEqual(p.count, 11)
        XCTAssertTrue(p["Proxies"]!.isSelectable)
        XCTAssertFalse(p["自动选择"]!.isSelectable)
        XCTAssertEqual(p["🇯🇵 [华为沪日] | IDCF 东一"]!.lastDelay, 72)
        XCTAssertNil(p["Claude"]!.icon, "空字符串的 icon 应视为没有图标")
    }

    func testGroupOrderFollowsGlobalAndHidesAutoSelect() throws {
        let p = try decode()
        let names = PolicyStore.orderedGroups(from: p, mode: .rule, hidden: ["自动选择"]).map(\.name)
        XCTAssertEqual(names, ["Proxies", "日本", "Claude", "CN", "Final"])
        let global = PolicyStore.orderedGroups(from: p, mode: .global, hidden: ["自动选择"]).map(\.name)
        XCTAssertEqual(global.first, "GLOBAL")
    }

    func testResolveFollowsNestedGroups() throws {
        let p = try decode()
        XCTAssertEqual(PolicyStore.resolve("Claude", in: p)?.name, "🇯🇵 [华为沪日] | IDCF Osaka")
        XCTAssertEqual(PolicyStore.resolve("Final", in: p)?.name, "🇯🇵 [华为沪日] | IDCF 东一")
        XCTAssertEqual(PolicyStore.resolve("CN", in: p)?.name, "DIRECT")
    }

    func testPathSegmentsAreFullyEncoded() {
        let client = MihomoClient(baseURL: URL(string: "http://192.168.0.1:9090")!, secret: "x")
        let url = client.makeURL(
            ["proxies", "🇯🇵 [华为沪日] | IDCF 东一", "delay"],
            query: [URLQueryItem(name: "timeout", value: "5000")])
        let s = url.absoluteString
        XCTAssertTrue(s.hasPrefix("http://192.168.0.1:9090/proxies/"))
        XCTAssertFalse(s.contains(" "))
        XCTAssertFalse(s.contains("|"))
        XCTAssertTrue(s.hasSuffix("/delay?timeout=5000"))
        let group = client.makeURL(["proxies", "a/b"]).absoluteString
        XCTAssertTrue(group.hasSuffix("/proxies/a%2Fb"), "组名里的斜杠不能被当成路径分隔")
    }

    func testConnectionDecodingAndKind() throws {
        let json = """
            {"downloadTotal":10,"uploadTotal":2,"connections":[
              {"id":"1","metadata":{"network":"tcp","sourceIP":"192.168.0.105","destinationIP":"1.1.1.1","destinationPort":"443","host":"claude.ai"},
               "upload":1,"download":2,"start":"2026-10-04T10:00:00Z","chains":["🇯🇵 [华为沪日] | IDCF 东一","日本","Claude"],"rule":"RuleSet","rulePayload":"claude"},
              {"id":"2","metadata":{"network":"udp","sourceIP":"192.168.0.105","destinationIP":"8.8.8.8","destinationPort":53,"host":""},
               "upload":0,"download":0,"chains":["DIRECT"],"rule":"GeoIP","rulePayload":"CN"}
            ]}
            """
        let r = try JSONDecoder().decode(ConnectionsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.connections.count, 2)
        XCTAssertEqual(r.connections[0].chainText, "Claude → 日本 → 🇯🇵 [华为沪日] | IDCF 东一")
        XCTAssertEqual(r.connections[0].target, "claude.ai:443")
        XCTAssertEqual(r.connections[1].kind, .direct)
        XCTAssertEqual(r.connections[1].metadata.destinationPort, "53")
    }

    func testConfigModeParsing() throws {
        let c = try JSONDecoder().decode(MihomoConfig.self, from: Data(#"{"mode":"Rule","port":7890}"#.utf8))
        XCTAssertEqual(c.mode, .rule)
    }

    func testDemoSelectRejectsNonSelectable() async throws {
        let demo = DemoMihomo()
        do {
            try await demo.select(group: "自动选择", proxy: "DIRECT")
            XCTFail("url-test 组不应允许手动选择")
        } catch {
            XCTAssertEqual(error as? MihomoError, .notSelectable("自动选择"))
        }
        try await demo.select(group: "Claude", proxy: "香港")
        let p = try await demo.proxies()
        XCTAssertEqual(p["Claude"]?.now, "香港")
    }

    @MainActor
    func testTrafficDisconnectDoesNotKeepOldRateOrPretendZero() {
        let monitor = TrafficMonitor()
        monitor.accept(TrafficSample(up: 2048, down: 4096))
        XCTAssertEqual(monitor.downText, "4")
        let lastDate = monitor.updatedAt
        monitor.invalidate()
        XCTAssertEqual(monitor.downText, "—")
        XCTAssertEqual(monitor.upText, "—")
        XCTAssertEqual(monitor.updatedAt, lastDate)
        monitor.accept(TrafficSample(up: 0, down: 0))
        XCTAssertEqual(monitor.downText, "0")
    }

    @MainActor
    func testTrafficStaleSampleIsNotLive() {
        let monitor = TrafficMonitor()
        monitor.accept(TrafficSample(up: 500, down: 900), at: Date().addingTimeInterval(-10))
        XCTAssertEqual(monitor.downText, "—")
        XCTAssertTrue(monitor.caption(at: Date()).contains("重连"))
    }

    @MainActor
    func testPolicyPresentationIsScopedPerDevice() {
        let a = UUID().uuidString
        let b = UUID().uuidString
        defer {
            for id in [a, b] {
                UserDefaults.standard.removeObject(forKey: "hiddenGroups." + id)
                UserDefaults.standard.removeObject(forKey: "favoriteGroups." + id)
            }
        }
        let store = PolicyStore(api: DemoMihomo())
        store.authorizeWrite = {}
        store.use(DemoMihomo(), deviceID: a)
        store.hiddenGroups = ["Apple"]
        store.favoriteGroups = ["日本"]
        store.use(DemoMihomo(), deviceID: b)
        XCTAssertFalse(store.hiddenGroups.contains("Apple"))
        XCTAssertTrue(store.favoriteGroups.isEmpty)
        store.use(DemoMihomo(), deviceID: a)
        XCTAssertEqual(store.hiddenGroups, ["Apple"])
        XCTAssertEqual(store.favoriteGroups, ["日本"])
    }

    func testWidgetDistinguishesStaleFailedAndDemo() {
        var snapshot = WidgetSnapshot.placeholder
        snapshot.demo = false
        let now = snapshot.updatedAt
        XCTAssertEqual(snapshot.statusText(at: now), "最近已读取")
        XCTAssertEqual(snapshot.statusText(at: now.addingTimeInterval(120)), "待刷新")
        snapshot.connectionMessage = "unavailable"
        XCTAssertEqual(snapshot.statusText(at: now), "连接待检查")
        snapshot.demo = true
        XCTAssertEqual(snapshot.statusText(at: now), "演示数据")
    }

    @MainActor
    func testWidgetLinkDismissesSettingsAndOpensPolicy() {
        let router = AppRouter()
        router.sheet = .settings
        router.open(AppIdentity.url(for: "policy"))
        XCTAssertNil(router.sheet)
        XCTAssertEqual(router.tab, 1)
        router.open(AppIdentity.url(for: "service"))
        XCTAssertEqual(router.sheet, .service)
    }

    func testTrafficFormatting() {
        XCTAssertEqual(TrafficMonitor.split(4_404_019).0, "4.2")
        XCTAssertEqual(TrafficMonitor.split(4_404_019).1, "MB/s")
        XCTAssertEqual(TrafficMonitor.split(2048).1, "KB/s")
    }

    /// 换设备不能把上一台的展开、排序和结果提示带到同名策略组。
    @MainActor
    func testChangingDeviceResetsPolicyPresentation() async {
        let store = PolicyStore(api: DemoMihomo())
        store.authorizeWrite = {}
        await store.refresh()
        store.expanded = ["Proxies", "日本"]
        store.sortByDelay = ["日本"]
        store.notice = "旧设备结果"

        store.use(DemoMihomo())

        XCTAssertTrue(store.expanded.isEmpty)
        XCTAssertTrue(store.sortByDelay.isEmpty)
        XCTAssertTrue(store.proxies.isEmpty)
        XCTAssertNil(store.notice)
        XCTAssertEqual(store.state, .idle)
    }

    /// 同样的结果连续出现，也必须让提示条取消旧计时、重新获得完整展示时间。
    @MainActor
    func testRepeatedNoticesHaveDistinctIdentities() {
        let policy = PolicyStore(api: DemoMihomo())
        policy.authorizeWrite = {}
        policy.notice = "测速完成"
        let firstPolicyNotice = policy.noticeID
        policy.notice = "测速完成"
        XCTAssertNotEqual(policy.noticeID, firstPolicyNotice)

        let status = DeviceStatusStore(api: DemoWebSSH())
        status.authorizeWrite = {}
        status.notice = "配置检查通过"
        let firstDeviceNotice = status.noticeID
        status.notice = "配置检查通过"
        XCTAssertNotEqual(status.noticeID, firstDeviceNotice)
    }

}
