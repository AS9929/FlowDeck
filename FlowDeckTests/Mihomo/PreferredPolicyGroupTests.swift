import XCTest

@testable import FlowDeck

/// 非固定命名、失效偏好及规则模式多出口的边界；快捷操作不得任意选择业务组。
final class PreferredPolicyGroupTests: XCTestCase {
    private func proxies(_ groups: [String]) throws -> [String: MihomoProxy] {
        var records: [String: Any] = [
            "GLOBAL": ["name": "GLOBAL", "type": "Selector", "all": groups, "now": groups.first ?? "DIRECT"],
            "节点 A": ["name": "节点 A", "type": "ss", "history": []],
        ]
        for name in groups {
            records[name] = ["name": name, "type": "Selector", "all": ["节点 A"], "now": "节点 A"]
        }
        return try JSONDecoder().decode([String: MihomoProxy].self, from: JSONSerialization.data(withJSONObject: records))
    }

    func testSingleCustomNamedGroupAndLegacyConfiguration() throws {
        let custom = try proxies(["节点选择"])
        XCTAssertEqual(PreferredPolicyGroup.resolve(in: custom, mode: .rule, preferred: nil), "节点选择")
        let legacy = try proxies(["Proxies", "日本", "Claude"])
        XCTAssertEqual(PreferredPolicyGroup.resolve(in: legacy, mode: .rule, preferred: nil), "Proxies")
    }

    func testAmbiguousOrDeletedGroupNeverGuessesAnotherGroup() throws {
        let list = try proxies(["视频", "工作"])
        XCTAssertNil(PreferredPolicyGroup.resolve(in: list, mode: .rule, preferred: nil))
        XCTAssertEqual(PreferredPolicyGroup.resolve(in: list, mode: .rule, preferred: "工作"), "工作")
        XCTAssertNil(PreferredPolicyGroup.resolve(in: list, mode: .rule, preferred: "已移除"))
        XCTAssertNil(PreferredPolicyGroup.resolve(in: list, mode: .direct, preferred: "工作"))
        XCTAssertEqual(PreferredPolicyGroup.resolve(in: list, mode: .global, preferred: "工作"), "GLOBAL")
    }

    @MainActor
    func testSystemActionUsesExplicitGroupAndDoesNotGuess() throws {
        let list = try proxies(["视频", "工作"])
        XCTAssertNil(SystemActionRunner.nextNodeGroup(list))
        XCTAssertEqual(SystemActionRunner.nextNodeGroup(list, preferred: "工作"), "工作")
        XCTAssertNil(SystemActionRunner.nextNodeGroup(list, mode: .direct, preferred: "工作"))
    }

    @MainActor
    func testPreferencesAreDeviceScopedAndCanResetToAutomatic() throws {
        let suite = "PolicyPreference." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        PreferredPolicyGroup.save("工作", deviceID: "first", defaults: defaults)
        let store = PolicyStore(api: DemoMihomo.shared, deviceID: "first", defaults: defaults)
        XCTAssertEqual(store.preferredGroup, "工作")
        store.use(DemoMihomo.shared, deviceID: "second")
        XCTAssertNil(store.preferredGroup)
        store.use(DemoMihomo.shared, deviceID: "first")
        XCTAssertEqual(store.preferredGroup, "工作")
        store.setPreferredGroup(nil)
        XCTAssertNil(PreferredPolicyGroup.saved(deviceID: "first", defaults: defaults))
    }

    @MainActor
    func testCyclicGroupDoesNotAppearAsExitNode() throws {
        let records = ["loop": ["name": "loop", "type": "Selector", "all": ["loop"], "now": "loop"]] as [String: Any]
        let list = try JSONDecoder().decode([String: MihomoProxy].self, from: JSONSerialization.data(withJSONObject: records))
        XCTAssertNil(PolicyStore.resolve("loop", in: list))
        XCTAssertNil(SystemActionRunner.nextNodeGroup(list, preferred: "loop"))
    }
}
