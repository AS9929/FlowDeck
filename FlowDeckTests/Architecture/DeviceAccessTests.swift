import XCTest

@testable import FlowDeck

/// 接入边界只使用独立偏好与示例客户端，不连接真实设备。
final class DeviceAccessTests: XCTestCase {
    func testAccessMatrixSeparatesIdentityAndServices() {
        for requirement in [DeviceAccessRequirement.device, .mihomo, .webSSH] {
            XCTAssertEqual(resolve(requirement, device: false), .noDevice)
            XCTAssertEqual(resolve(requirement, verified: false), .unverified)
            XCTAssertNil(resolve(requirement, demo: true, device: false, verified: false))
        }
        XCTAssertNil(resolve(.device, mihomo: false, web: false))
        XCTAssertEqual(resolve(.mihomo, mihomo: false), .missingMihomo)
        XCTAssertNil(resolve(.webSSH, mihomo: false))
        XCTAssertEqual(resolve(.webSSH, web: false), .missingWebSSH)
        XCTAssertNil(resolve(.mihomo, web: false))
    }

    @MainActor
    func testNewInstallAndLegacyAutomaticDemoStayUnbound() throws {
        try withDefaults { defaults in
            XCTAssertFalse(DeviceStore(defaults: defaults).demoMode)
            defaults.set(true, forKey: "demoMode")
            let store = DeviceStore(defaults: defaults)
            XCTAssertFalse(store.demoMode)
            XCTAssertFalse(store.webAvailable)
            XCTAssertFalse(store.mihomoAvailable)
            XCTAssertThrowsError(try store.requireAccess(.device))
        }
    }

    @MainActor
    func testExplicitDemoPersistsAndCanExitWithoutDevice() {
        withDefaults { defaults in
            let store = DeviceStore(defaults: defaults)
            store.demoMode = true
            XCTAssertTrue(store.webAvailable)
            XCTAssertTrue(DeviceStore(defaults: defaults).demoMode)
            store.demoMode = false
            XCTAssertFalse(DeviceStore(defaults: defaults).demoMode)
            XCTAssertEqual(store.accessIssue(for: .device), .noDevice)
        }
    }

    @MainActor
    func testRemovingLastRecordDoesNotEnterDemo() throws {
        try withDefaults { defaults in
            let profile = DeviceProfile(name: "测试设备")
            defaults.set(try JSONEncoder().encode([profile]), forKey: "devices.v1")
            let store = DeviceStore(defaults: defaults)
            XCTAssertEqual(store.accessIssue(for: .device), .unverified)
            store.remove(profile)
            XCTAssertNil(store.current)
            XCTAssertFalse(store.demoMode)
            XCTAssertEqual(store.accessIssue(for: .webSSH), .noDevice)
        }
    }

    @MainActor
    func testWritePreflightRejectsBeforeDemoSnapshotCanBeUsed() async {
        let name = "DeviceAccessTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = DeviceStore(defaults: defaults)
        do {
            _ = try await ManagementStore().verifiedAPI(store)
            XCTFail("未绑定不可借由占位客户端写入")
        } catch {
            XCTAssertEqual(error.localizedDescription, DeviceAccessIssue.noDevice.message)
        }
        store.demoMode = true
        do {
            _ = try await ManagementStore().verifiedAPI(store)
        } catch {
            XCTFail("主动演示应可体验：\(error)")
        }
        store.readOnly = true
        do {
            _ = try await ManagementStore().verifiedAPI(store)
            XCTFail("演示也须遵守只读保护")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("只读"))
        }
    }

    @MainActor
    func testDeepLinkDestinationsKeepLocalPagesAvailable() {
        for destination in [ManagementDestination.settings, .devices, .pairing, .system] {
            XCTAssertNil(destination.accessRequirement)
        }
        XCTAssertNotNil(ManagementDestination.service.accessRequirement)
        XCTAssertNotNil(ManagementDestination.backup.accessRequirement)
        XCTAssertNotNil(ManagementDestination.runtime.accessRequirement)
    }

    private func resolve(
        _ requirement: DeviceAccessRequirement, demo: Bool = false,
        device: Bool = true, verified: Bool = true, mihomo: Bool = true, web: Bool = true
    ) -> DeviceAccessIssue? {
        DeviceAccessIssue.resolve(
            requirement: requirement, demo: demo, hasDevice: device,
            verified: verified, hasMihomo: mihomo, hasWebSSH: web
        )
    }

    private func withDefaults(_ work: (UserDefaults) throws -> Void) rethrows {
        let name = "DeviceAccessTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try work(defaults)
    }
}
