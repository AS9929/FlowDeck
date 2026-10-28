import XCTest

@testable import FlowDeck

/// 服务层的目标、凭据与回读边界；全部使用隔离本机存储或替身，不访问真实设备。
final class ServiceBoundaryTests: XCTestCase {
    @MainActor
    func testContextRejectsOldTargetBeforeCredentialCommit() throws {
        let suite = "service-fixture-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DeviceStore(defaults: defaults)
        let first = DeviceProfile(name: "first")
        let second = DeviceProfile(name: "second")
        store.save(first, secret: "", webPassword: "")
        let context = try DeviceServiceContext(store, revision: store.clientRevision)
        store.save(second, secret: "", webPassword: "")
        defer {
            store.remove(first)
            store.remove(second)
        }
        XCTAssertThrowsError(try context.service((any WebSSHAPI).self))
        XCTAssertThrowsError(try context.rememberFactoryPassword("fixture-not-saved"))
        XCTAssertEqual(store.factoryPassword(for: first), "")
        XCTAssertEqual(store.factoryPassword(for: second), "")
    }

    @MainActor
    func testCredentialCommitRespectsLeaseAndAllowsOwner() throws {
        let suite = "service-fixture-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DeviceStore(defaults: defaults)
        let profile = DeviceProfile(name: "fixture")
        store.save(profile, secret: "", webPassword: "")
        defer { store.remove(profile) }
        let context = try DeviceServiceContext(store, revision: store.clientRevision)
        let lease = try DeviceOperationGate.begin("fixture")
        do {
            defer { DeviceOperationGate.end(lease) }
            XCTAssertThrowsError(try context.rememberFactoryPassword("blocked"))
            try DeviceOperationGate.$owner.withValue(lease) {
                try context.rememberFactoryPassword("fixture-saved")
            }
            XCTAssertEqual(store.factoryPassword(for: profile), "fixture-saved")
        }
    }

    @MainActor
    func testDemoDiagnosticsRemainLocalAndReportUntestedUDP() async throws {
        let suite = "service-fixture-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DeviceStore(defaults: defaults)
        store.demoMode = true
        let context = try DeviceServiceContext(store, revision: store.clientRevision)
        let report = try await DeviceDiagnosticsService(context: context, progress: { _, _ in }).run()
        XCTAssertTrue(report.demo)
        XCTAssertTrue(report.checks.contains { $0.id == "management" })
        XCTAssertEqual(report.checks.first { $0.id == "udp" }?.outcome, .unavailable)
    }

    func testDemoBackupIsExplicitlyNonRestorableAndChecksumMatchesFile() async throws {
        let result = try await FactoryBackupService(
            api: DemoWebSSH.shared, profile: nil, password: "", demo: true
        ).run()
        defer { try? FileManager.default.removeItem(at: result.url) }
        let data = try Data(contentsOf: result.url)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("not a restorable device backup"))
        XCTAssertEqual(DeviceIdentity.digest(data), result.checksum)
    }

    @MainActor
    func testAlreadyCurrentWebSSHDoesNotEnterInstallFlow() async throws {
        let service = WebSSHMaintenanceService(
            api: DemoWebSSH.shared, demo: true,
            progress: { _, _ in
                XCTFail("Already-current update must not enter restart polling")
            })
        let result = try await service.manageWebSSH(update: true)
        XCTAssertTrue(result.alreadyCurrent)
        XCTAssertEqual(result.version, "20260909")
    }

    @MainActor
    func testRecoveryRecordRemainsDeviceScopedAndDemoCanResume() async throws {
        let suite = "service-fixture-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DeviceStore(defaults: defaults)
        store.demoMode = true
        let context = try DeviceServiceContext(store, revision: store.clientRevision)
        var pending = false
        let recovery = WebSSHRecoveryService(
            context: context, storageID: store.storageID, defaults: defaults,
            pending: { pending = $0 }, progress: { _, _ in })
        do {
            try await recovery.prepare(sendCommand: false)
            XCTFail("Cannot observe a recovery belonging to another or missing device")
        } catch {
            XCTAssertTrue(error is ManagementError)
        }
        try await recovery.prepare(sendCommand: true)
        XCTAssertTrue(pending)
        XCTAssertEqual(defaults.string(forKey: "recovery.device"), store.storageID)
        try await recovery.prepare(sendCommand: false)
        let restored = try await recovery.waitForRecovery()
        XCTAssertTrue(restored)
        XCTAssertTrue(defaults.bool(forKey: "recovery.pending"), "Foreground coordinator owns clearing the tracking state")
    }

    func testMarkReadRequiresMatchingReadbackAndSendsOnlyOnce() async throws {
        let message = SMSMessage(id: 4, number: "fixture", date: "", content: "", tag: "1")
        let api = MessageReadbackFixture(confirmed: true)
        let actual = try await UFIFactoryOperations.markRead(message, page: 2, password: "fixture", api: api)
        XCTAssertFalse(actual.unread)
        let calls = await api.calls
        XCTAssertEqual(calls, ["mark:4", "read:2"])
    }

    func testMarkReadDoesNotTreatUnchangedRecordAsSuccessOrRetry() async {
        let message = SMSMessage(id: 4, number: "fixture", date: "", content: "", tag: "1")
        let api = MessageReadbackFixture(confirmed: false)
        do {
            _ = try await UFIFactoryOperations.markRead(message, page: 0, password: "fixture", api: api)
            XCTFail("Unchanged unread flag must not be reported as success")
        } catch {
            XCTAssertTrue(error is ManagementError)
        }
        let calls = await api.calls
        XCTAssertEqual(calls, ["mark:4", "read:0"])
    }
}

private actor MessageReadbackFixture: UFIMessagesService {
    let confirmed: Bool
    private(set) var calls: [String] = []

    init(confirmed: Bool) {
        self.confirmed = confirmed
    }

    func readMessages(page: Int, password: String) async throws -> [SMSMessage] {
        calls.append("read:\(page)")
        return [SMSMessage(id: 4, number: "fixture", date: "", content: "", tag: confirmed ? "0" : "1")]
    }

    func performFactoryAction(_ action: UFIFactoryAction, password: String) async throws {
        guard case .markMessageRead(let id) = action else {
            throw ManagementError.invalid("Unexpected action")
        }
        calls.append("mark:\(id)")
    }

    func messageStorage(password: String) async throws -> UFISMSStorage {
        throw ManagementError.invalid("Unexpected storage request")
    }

    func sendMessage(number: String, text: String, password: String) async throws {
        throw ManagementError.invalid("Unexpected send")
    }

    func deleteMessage(id: Int, password: String) async throws {
        throw ManagementError.invalid("Unexpected delete")
    }
}
