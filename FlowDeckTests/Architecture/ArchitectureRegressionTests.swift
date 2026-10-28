import XCTest

@testable import FlowDeck

/// 评审缺陷的行为回归。使用独立偏好、随机凭据账户和 HTTP 替身，不连接真实设备。
final class ArchitectureRegressionTests: XCTestCase {
    @MainActor
    private func withStore(_ body: (DeviceStore, UserDefaults) throws -> Void) rethrows {
        let name = "ArchitectureRegression.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(DeviceStore(defaults: defaults), defaults)
    }

    @MainActor
    func testUnknownBackendAndFutureFieldsSurviveSavingAnotherDevice() throws {
        try withStore { _, defaults in
            let known = DeviceProfile(name: "known")
            let future = DeviceProfile(name: "future")
            var rows = try JSONSerialization.jsonObject(with: JSONEncoder().encode([known, future])) as! [[String: Any]]
            rows[1]["backend"] = "future-adapter"
            rows[1]["schemaVersion"] = 5
            rows[1]["adapterOptions"] = ["layout": "future-v3"]
            defaults.set(try JSONSerialization.data(withJSONObject: rows), forKey: "devices.v1")
            let store = DeviceStore(defaults: defaults)
            XCTAssertEqual(store.devices.count, 2)
            store.select(store.devices[1])
            XCTAssertEqual(store.accessIssue(for: .webSSH), .unsupportedBackend)
            XCTAssertTrue(store.webClient is UnavailableClient)
            let replacement = DeviceProfile(name: "replacement")
            defer { store.remove(replacement) }
            store.save(replacement, secret: "")
            let saved = try JSONSerialization.jsonObject(with: defaults.data(forKey: "devices.v1")!) as! [[String: Any]]
            XCTAssertEqual(saved.count, 3)
            let retained = try XCTUnwrap(saved.first { $0["backend"] as? String == "future-adapter" })
            XCTAssertEqual(retained["schemaVersion"] as? Int, 5)
            XCTAssertEqual(retained["adapterOptions"] as? [String: String], ["layout": "future-v3"])
        }
    }

    @MainActor
    func testMalformedRecordPreservedAndUnreadableLibraryNeverOverwritten() throws {
        try withStore { _, defaults in
            let known = DeviceProfile(name: "known")
            let valid = try JSONSerialization.jsonObject(with: JSONEncoder().encode(known))
            defaults.set(try JSONSerialization.data(withJSONObject: [valid, ["broken": true]]), forKey: "devices.v1")
            let store = DeviceStore(defaults: defaults)
            XCTAssertEqual(store.devices.count, 1)
            XCTAssertNotNil(store.storageWarning)
            store.save(known, secret: "")
            let saved = try JSONSerialization.jsonObject(with: defaults.data(forKey: "devices.v1")!) as! [[String: Any]]
            XCTAssertTrue(saved.contains { $0["broken"] as? Bool == true })
            store.remove(known)
            let corrupt = Data("invalid-json".utf8)
            defaults.set(corrupt, forKey: "devices.v1")
            let damaged = DeviceStore(defaults: defaults)
            XCTAssertThrowsError(try damaged.saveVerified(known, secret: "", webPassword: "", factoryPassword: ""))
            damaged.save(known, secret: "")
            XCTAssertEqual(defaults.data(forKey: "devices.v1"), corrupt)
        }
    }

    @MainActor
    func testAllRecordAndModeMutationsRespectActiveLease() throws {
        try withStore { _, defaults in
            let first = DeviceProfile(name: "first")
            let second = DeviceProfile(name: "second")
            defaults.set(try JSONEncoder().encode([first, second]), forKey: "devices.v1")
            let store = DeviceStore(defaults: defaults)
            let lease = try DeviceOperationGate.begin("fixture")
            defer { DeviceOperationGate.end(lease) }
            store.select(second)
            store.save(second, secret: "")
            store.save(second, secret: "", webPassword: "")
            XCTAssertThrowsError(try store.saveVerified(second, secret: "", webPassword: "", factoryPassword: ""))
            store.remove(first)
            store.demoMode = true
            store.readOnly = true
            let otherStore = DeviceStore(defaults: defaults)
            otherStore.select(second)
            XCTAssertEqual(store.currentID, first.id)
            XCTAssertEqual(otherStore.currentID, first.id)
            XCTAssertEqual(store.devices.count, 2)
            XCTAssertFalse(store.demoMode)
            XCTAssertFalse(store.readOnly)
            XCTAssertEqual(store.clientRevision, 1)
        }
    }

    @MainActor
    func testLeaseOwnerCanCommitItsVerifiedProfileAndSessionDetectsChange() throws {
        try withStore { store, _ in
            let original = store.session()
            let profile = DeviceProfile(name: "owner")
            defer { store.remove(profile) }
            let lease = try DeviceOperationGate.begin("fixture")
            do {
                defer { DeviceOperationGate.end(lease) }
                try DeviceOperationGate.$owner.withValue(lease) {
                    try store.saveVerified(profile, secret: "", webPassword: "", factoryPassword: "")
                }
                XCTAssertEqual(store.currentID, profile.id)
            }
            XCTAssertThrowsError(try original.validate(in: store))
            XCTAssertNil(original.profile, "原会话目标不可在 await 后跟着当前选择漂移")
        }
    }

    @MainActor
    func testInvalidEndpointInvalidatesBothClients() throws {
        try withStore { _, defaults in
            let valid = DeviceProfile(name: "valid")
            var invalid = DeviceProfile(name: "invalid")
            invalid.host = "["
            defaults.set(try JSONEncoder().encode([valid, invalid]), forKey: "devices.v1")
            let store = DeviceStore(defaults: defaults)
            XCTAssertTrue(store.webClient is WebSSHClient)
            store.select(invalid)
            XCTAssertTrue(store.webClient is UnavailableClient)
            XCTAssertTrue(store.client is UnavailableClient)
            XCTAssertEqual(store.accessIssue(for: .webSSH), .invalidEndpoint)
        }
        for host in ["", "host/path", "user@host", "host?other", "host#fragment"] {
            XCTAssertNil(DeviceEndpoint.url(host: host, port: 80))
        }
        XCTAssertNil(DeviceEndpoint.url(host: "192.168.0.1", port: 65536))
    }

    func testUnavailableClientsNeverReturnDemoData() async {
        do {
            _ = try await UnavailableClient().snapshot()
            XCTFail("失败会话不能返回快照")
        } catch {}
        do {
            _ = try await UnavailableClient().proxies()
            XCTFail("失败会话不能返回节点")
        } catch {}
    }

    func testMessageCapabilityDispatchesWithoutWebSSHTransport() async throws {
        let adapter = MessageCapabilityFixture()
        let capability: any MessageManagementAPI = adapter
        try await capability.sendSMS(number: "fixture-recipient", message: "fixture-body")
        let actual = await adapter.lastRecipient
        XCTAssertEqual(actual, "fixture-recipient")
    }

    func testRegistryHasNoImplicitFallbackAndCanResolveThirdAdapter() {
        let future = ManagementBackend(rawValue: "future-test")
        XCTAssertNil(BackendRegistry.descriptor(for: future))
        let descriptor = BackendDescriptor(
            id: future, presentation: .ufi, supportedModels: ["test-model"], features: [.status],
            makeClient: { _, _, _ in UnavailableClient() },
            verifyWrite: { _, _, _ in throw ManagementError.unsupported("read-only fixture") })
        let resolved = BackendRegistry.descriptor(for: future, in: BackendRegistry.descriptors + [descriptor])
        XCTAssertEqual(resolved?.id, future)
        XCTAssertEqual(resolved?.features, [.status])
        XCTAssertFalse(BackendRegistry.supportedIDs.contains(future), "测试适配器不得进入正式接入列表")
    }

    func testRollbackStartsWithoutMihomoAPI() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArchitectureUpdateProtocol.self]
        let snapshot = try UFIClient.snapshot(from: ArchitectureUpdateProtocol.identity)
        let client = UFIClient(
            baseURL: URL(string: "http://architecture.invalid")!, password: "fixture",
            expectedFingerprint: snapshot.identityFingerprint, mihomo: nil, configuration: configuration)
        try await client.startCoreUpdate(nil)
    }

    func testJournalSeparatesLiveLostAndRestartedJobs() {
        XCTAssertEqual(UFIJobJournal.resolvedStatus("switching", health: "alive"), "switching")
        XCTAssertEqual(UFIJobJournal.resolvedStatus("switching", health: "interrupted"), "interrupted")
        XCTAssertEqual(UFIJobJournal.resolvedStatus("installing", health: "orphaned"), "orphaned")
        XCTAssertEqual(UFIJobJournal.resolvedStatus("starting", health: "unknown"), "recovery-required")
        XCTAssertEqual(UFIJobJournal.resolvedStatus("starting", health: "none"), "recovery-required")
        XCTAssertFalse(UFICoreState(version: "", backupAvailable: true, status: "interrupted").running)
        XCTAssertTrue(UFICoreState(version: "", backupAvailable: true, status: "interrupted").needsRecovery)
    }

    func testExportJournalScriptsForHostFaultInjection() throws {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JournalFixtures")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try UFIClient.interruptedCoreRecoveryScript.write(to: directory.appendingPathComponent("core-restore.sh"), atomically: true, encoding: .utf8)
        try UFIClient.interruptedServiceRecoveryScript.write(to: directory.appendingPathComponent("ufi-restore.sh"), atomically: true, encoding: .utf8)
        for kind in [UFIJobJournal.Kind.core, .ufi] {
            try UFIJobJournal.inspect(kind).write(to: directory.appendingPathComponent(kind.rawValue + "-inspect.sh"), atomically: true, encoding: .utf8)
            let recovery = UFIJobJournal.recoveryGuard(kind) + "\n" + UFIJobJournal.releaseRecovered
            try recovery.write(to: directory.appendingPathComponent(kind.rawValue + "-recover.sh"), atomically: true, encoding: .utf8)
        }
    }
}

/// 只接受身份、服务摘要、端口读取和启动回滚；不允许访问真实主机。
private final class ArchitectureUpdateProtocol: URLProtocol {
    static let identity = "model=F50\nserial=REGRESSIONF50001\nfirmware=F50_FLYMODEM_ZYV1.0.0B09"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let size = stream.read(&buffer, maxLength: buffer.count)
                if size <= 0 { break }
                data.append(contentsOf: buffer.prefix(size))
            }
        }
        let command = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["command"] as? String ?? ""
        let object: [String: Any]
        if request.url?.path == "/api/user_shell" {
            object = ["result": ["done": true, "content": Self.identity]]
        } else if command.contains("id -u; sha256sum") {
            object = ["result": "0\ne559d31d1578bcea782efd561959e8dd2aadffea05e5fcbf0d401bf36c2031d6  /data/clash/Scripts/Clash.Service"]
        } else if command.contains("awk '/^(mixed-port|port)") {
            object = ["result": "mixed-port=7890\nport=0"]
        } else if command.contains("flowdeck_job=started") {
            object = ["result": "flowdeck_job=started"]
        } else {
            XCTFail("Unexpected command in isolated fixture")
            object = ["result": ""]
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: object))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// 第三种传输的能力替身，不需要实现 UCI、shell 或其他无关设备功能。
private actor MessageCapabilityFixture: MessageManagementAPI {
    private(set) var lastRecipient: String?

    func sms() async throws -> [SMSMessage] { [] }

    func markSMSRead(id: Int) async throws {}

    func sendSMS(number: String, message: String) async throws {
        lastRecipient = number
    }
}
