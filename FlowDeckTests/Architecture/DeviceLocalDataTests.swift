import XCTest

@testable import FlowDeck

/// 最后一条硬件引用移除时清理敏感副本；同硬件的其他连接仍存在时保留恢复能力。
@MainActor
final class DeviceLocalDataTests: XCTestCase {
    func testSharedRecoverySurvivesFirstRemovalAndIsClearedAfterLast() throws {
        let suite = "DeviceLocalData." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DeviceStore(defaults: defaults)
        let identity = UUID().uuidString
        var first = DeviceProfile(name: "first")
        first.fingerprint = identity
        first.backend = .ufiTools
        var second = DeviceProfile(name: "second")
        second.fingerprint = identity
        store.save(first, secret: "", webPassword: "")
        store.save(second, secret: "", webPassword: "")
        defer {
            store.remove(first)
            store.remove(second)
        }
        let point = UFIWifiAccessPoint(
            chip: "0", index: "0", enabled: true, authMode: "WPA2PSK",
            ssid: "fixture", password: "fixture-password", hidden: false, maxClients: 10)
        try UFIWifiRecovery(deviceID: identity, before: point, requested: point).save()
        try UFISMSDraft(number: "fixture", text: "private draft").save(deviceID: identity)
        try KeychainStore.setChecked("fixture-backup", account: "ufi.apn.backup." + identity)
        PreferredPolicyGroup.save("工作", deviceID: identity, defaults: defaults)
        store.remove(first)
        XCTAssertNotNil(try UFIWifiRecovery.load(identity))
        XCTAssertNotNil(UFISMSDraft.load(deviceID: identity))
        store.remove(second)
        XCTAssertNil(try UFIWifiRecovery.load(identity))
        XCTAssertNil(UFISMSDraft.load(deviceID: identity))
        XCTAssertNil(KeychainStore.get(account: "ufi.apn.backup." + identity))
        XCTAssertNil(PreferredPolicyGroup.saved(deviceID: identity, defaults: defaults))
        XCTAssertTrue(store.devices.isEmpty)
    }

    func testUnchangedCredentialReadIsAllowedDuringWriteLease() throws {
        let suite = "CredentialRead." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DeviceStore(defaults: defaults)
        let profile = DeviceProfile(name: "fixture")
        store.save(profile, secret: "", webPassword: "")
        defer { store.remove(profile) }
        let context = try DeviceServiceContext(store, revision: store.clientRevision)
        try context.rememberFactoryPassword("saved")
        let lease = try DeviceOperationGate.begin("fixture")
        defer { DeviceOperationGate.end(lease) }
        XCTAssertNil(try context.rememberFactoryPasswordWarning("saved"))
        XCTAssertNotNil(try context.rememberFactoryPasswordWarning("changed"))
        XCTAssertEqual(store.factoryPassword(for: profile), "saved")
    }

    func testChangedSessionCannotDowngradeIdentityFailureToWarning() throws {
        let suite = "StaleCredential." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DeviceStore(defaults: defaults)
        let context = try DeviceServiceContext(store, revision: store.clientRevision)
        store.demoMode.toggle()
        XCTAssertThrowsError(try context.rememberFactoryPasswordWarning("fixture"))
    }
}
