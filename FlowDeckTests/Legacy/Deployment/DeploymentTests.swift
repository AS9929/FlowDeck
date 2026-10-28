import XCTest

@testable import FlowDeck

/// 首次部署的离线容器、配置边界和状态机测试；不连接任何真实设备。
final class DeploymentTests: XCTestCase {
    private let secret = String(repeating: "a", count: 48)
    private let source = "proxies: []\nproxy-groups: []\nrules:\n  - MATCH,DIRECT\n"

    func testDecryptsIndependentOpenSSLFixture() throws {
        let hex = "53616c7465645f5f010203040506070801471b5028f9490ddd37e1e07859e5aea8af41ab79a55e4d6868879e21dcf904"
        let bytes = stride(from: 0, to: hex.count, by: 2).map { offset -> UInt8 in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
        let decoded = try FactoryBackupArchive.crypt(Data(bytes), password: "fixture-password", encrypt: false)
        XCTAssertEqual(String(decoding: decoded, as: UTF8.self), "FlowDeck archive fixture\n")
        // 3DES 本身没有认证；错误密钥也可能碰巧满足填充。完整备份还必须通过 gzip、tar 和内层摘要。
        let wrong = try? FactoryBackupArchive.crypt(Data(bytes), password: "wrong", encrypt: false)
        XCTAssertNotEqual(wrong, decoded)
        XCTAssertThrowsError(try FactoryBackupArchive.replaceStartup(in: backupFixture(), password: "wrong") { $0 })
    }

    func testEncryptedAndGzipRoundTripRejectsTruncationAndTrailingData() throws {
        let original = Data(String(repeating: "配置验证\n", count: 100).utf8)
        let compressed = try FactoryBackupArchive.gzip(original, compress: true)
        let encrypted = try FactoryBackupArchive.crypt(compressed, password: "fixture", encrypt: true)
        let decrypted = try FactoryBackupArchive.crypt(encrypted, password: "fixture", encrypt: false)
        XCTAssertEqual(try FactoryBackupArchive.gzip(decrypted, compress: false), original)
        XCTAssertThrowsError(try FactoryBackupArchive.gzip(Data(compressed.dropLast()), compress: false))
        XCTAssertThrowsError(try FactoryBackupArchive.gzip(compressed + Data([0]), compress: false))
        XCTAssertThrowsError(try FactoryBackupArchive.crypt(Data(encrypted.dropLast()), password: "fixture", encrypt: false))
    }

    func testTarPreservesOriginalHeadersAndRejectsUnsafeRecords() throws {
        let entry = try FactoryBackupArchive.Entry(name: "etc/example", content: Data("value".utf8), mode: 0o640)
        let archive = FactoryBackupArchive.pack([entry])
        let restored = try FactoryBackupArchive.unpack(archive)
        XCTAssertEqual(FactoryBackupArchive.pack(restored), archive)
        XCTAssertThrowsError(try FactoryBackupArchive.unpack(FactoryBackupArchive.pack([entry, entry])))
        let unsafe = try FactoryBackupArchive.Entry(name: "../etc/example", content: Data())
        XCTAssertThrowsError(try FactoryBackupArchive.unpack(FactoryBackupArchive.pack([unsafe])))
        var corrupt = archive
        corrupt[100] = 57
        XCTAssertThrowsError(try FactoryBackupArchive.unpack(corrupt))
    }

    func testStartupReplacementPreservesOtherRecordsAndVerifiesInnerDigest() throws {
        let original = try backupFixture()
        let updated = try FactoryBackupArchive.replaceStartup(in: original, password: "fixture") { $0 + "\necho ready\n" }
        let inner = try innerEntries(updated)
        XCTAssertEqual(inner.count, 2)
        XCTAssertEqual(String(decoding: inner[0].content, as: UTF8.self), "#!/bin/sh\nexit 0\n\necho ready\n")
        let before = try innerEntries(original)
        XCTAssertEqual(inner[1].content, before[1].content)
        XCTAssertEqual(inner[1].header, before[1].header)
        XCTAssertThrowsError(try FactoryBackupArchive.replaceStartup(in: backupFixture(badDigest: true), password: "fixture") { $0 })
    }

    func testBootstrapUsesPinnedBinaryAndLocalInitializationBeforeLAN() throws {
        guard Bundle.main.url(forResource: "BootstrapWebSSH", withExtension: "bin") != nil else {
            throw XCTSkip("历史首次部署载荷不随开源管理客户端分发")
        }
        let binary = try FactoryBootstrap.binary()
        let script = try FactoryBootstrap.startup(original: "#!/bin/sh\nexit 0\n", binary: binary, password: "fixture-password")
        XCTAssertTrue(script.contains("127.0.0.1:8899/api/sys/init"))
        XCTAssertTrue(script.contains(FactoryBootstrap.binaryDigest))
        XCTAssertTrue(script.contains("mkdir /data/flowdeck-bootstrap/attempted"))
        let initialize = try XCTUnwrap(script.range(of: "127.0.0.1:8899/api/sys/init"))
        let publish = try XCTUnwrap(script.range(of: "address = \"0.0.0.0\""))
        XCTAssertLessThan(initialize.lowerBound, publish.lowerBound)
        XCTAssertFalse(script.contains("fixture-password"))
        XCTAssertThrowsError(try FactoryBootstrap.startup(original: "# kano_plugins", binary: binary, password: "fixture-password"))
        XCTAssertThrowsError(try FactoryBootstrap.startup(original: "exit 0", binary: Data(), password: "fixture-password"))
        XCTAssertThrowsError(try FactoryBootstrap.startup(original: "exit 0", binary: binary, password: "short"))
    }

    func testConfigurationAdaptsNetworkWithoutLosingPolicies() throws {
        let config = try DeploymentConfiguration.make(source: "port: 1234\nsecret: old\n" + source, host: "192.168.0.1", secret: secret)
        XCTAssertTrue(config.contains("port: 7890"))
        XCTAssertTrue(config.contains("listen: 0.0.0.0:1053"))
        XCTAssertTrue(config.contains("auto-route: false"))
        XCTAssertTrue(config.contains("MATCH,DIRECT"))
        XCTAssertFalse(config.contains("secret: old"))
        XCTAssertFalse(config.contains("port: 1234"))
    }

    func testConfigurationRejectsMissingRulesDuplicateKeysAndFileDependencies() {
        for invalid in ["proxies: []", source + "rules: []\n", source + "rule-providers:\n  local:\n    type: file\n"] {
            XCTAssertThrowsError(try DeploymentConfiguration.make(source: invalid, host: "192.168.0.1", secret: secret))
        }
        for host in ["192.168.0.999", "192..168.0.1", "192.168.0.1.", "192.168.0.1:9090", "127.0.0.1\nsecret: invalid"] {
            XCTAssertThrowsError(try DeploymentConfiguration.make(source: source, host: host, secret: secret))
        }
    }

    func testLocalProviderDetectionIgnoresCommentsAndFindsInlineEntries() throws {
        let commented = source + "# 旧版曾用 type: file\nrule-providers:\n  online:\n    type: http\n    url: https://example.com/a.list\n    path: ./a.list\n"
        XCTAssertNoThrow(try DeploymentConfiguration.make(source: commented, host: "192.168.0.1", secret: secret))
        let blocks = SurgeConverter.topLevelBlocks(
            "rule-providers:\n  \"local\":\n    type: 'file'\n  inline: {type: file, path: ./b.yaml}\nproxy-providers:\n  sub:\n    type: http\n")
        XCTAssertEqual(DeploymentConfiguration.localProviders(in: blocks), ["local", "inline"])
    }

    func testSurgeConfigurationConvertsToOnlineProvidersForDeployment() throws {
        let surge = """
            [Proxy]
            东京 = ss, 203.0.113.1, 40005, encrypt-method=aes-128-gcm, password=x
            [Proxy Group]
            Proxies = select, include-all-proxies=true
            Final = select, Proxies, DIRECT
            [Rule]
            RULE-SET,https://example.com/claude.list,Proxies
            USER-AGENT,Surge*,DIRECT
            FINAL,Final
            """
        XCTAssertTrue(DeploymentConfiguration.looksLikeSurge(surge))
        XCTAssertFalse(DeploymentConfiguration.looksLikeSurge(source))
        let converted = try DeploymentConfiguration.fromSurge(surge)
        XCTAssertTrue(converted.summary.contains("1 个在线规则集"))
        XCTAssertTrue(converted.summary.contains("忽略 2 条"))
        let config = try DeploymentConfiguration.make(source: converted.yaml, host: "192.168.0.1", secret: secret)
        XCTAssertTrue(config.contains("type: http"))
        XCTAssertFalse(config.contains("type: file"))
        XCTAssertTrue(config.contains("MATCH,Final"))
        XCTAssertTrue(config.contains("port: 7890"))
    }

    @MainActor
    func testBothDemoRoutesReachValidatedThenCompleteWithoutSavingDevices() async {
        let devices = DeviceStore(defaults: UserDefaults(suiteName: "test.FlowDeck." + UUID().uuidString)!)
        let before = devices.devices
        let readOnly = devices.readOnly
        devices.readOnly = false
        defer { devices.readOnly = readOnly }
        for route in DeploymentStore.Route.allCases {
            let store = DeploymentStore()
            store.route = route
            await store.inspect(devices)
            if route == .factory {
                await store.prepareFactory(devices)
                XCTAssertEqual(store.phase, "factoryPrepared")
                await store.applyFactory(devices)
                XCTAssertEqual(store.phase, "factorySubmitted")
                await store.reconnect(devices)
            }
            store.source = source
            await store.installProxy(devices)
            XCTAssertEqual(store.phase, "validated")
            await store.inspect(devices)
            XCTAssertEqual(store.phase, "validated", "重复检查不能丢失安装阶段")
            await store.activate(devices)
            XCTAssertEqual(store.phase, "complete")
            XCTAssertNil(store.error)
        }
        XCTAssertEqual(devices.devices.map(\.id), before.map(\.id))
    }

    @MainActor
    func testReadOnlyAndUninspectedDeviceCannotInstall() async {
        let devices = DeviceStore(defaults: UserDefaults(suiteName: "test.FlowDeck." + UUID().uuidString)!)
        let original = devices.readOnly
        defer { devices.readOnly = original }
        let store = DeploymentStore()
        store.source = source
        devices.readOnly = true
        await store.installProxy(devices)
        XCTAssertEqual(store.phase, "new")
        XCTAssertTrue(store.error?.contains("只读") == true)
        devices.readOnly = false
        await store.installProxy(devices)
        XCTAssertEqual(store.phase, "new")
        XCTAssertTrue(store.error?.contains("先检查") == true)
    }

    @MainActor
    func testRunningProxyAndExistingConfigAreNeverOverwritten() async throws {
        let devices = DeviceStore(defaults: UserDefaults(suiteName: "test.FlowDeck." + UUID().uuidString)!)
        let original = devices.readOnly
        devices.readOnly = false
        defer { devices.readOnly = original }
        let api = DemoWebSSH()
        let store = DeploymentStore(api: api)
        await store.inspect(devices)
        store.profile.fingerprint = nil
        store.simulation = false
        store.source = source
        await store.installProxy(devices)
        XCTAssertTrue(store.error?.contains("已在运行") == true)
        _ = try await api.control(.stop)
        let before = try await api.loadConfig()
        await store.installProxy(devices)
        XCTAssertTrue(store.error?.contains("已有配置") == true)
        let after = try await api.loadConfig()
        XCTAssertEqual(before, after)
    }

    @MainActor
    func testAnotherDeviceClearsInMemoryCredentialsAndIdentity() async {
        let store = DeploymentStore()
        await store.inspect(DeviceStore(defaults: UserDefaults(suiteName: "test.FlowDeck." + UUID().uuidString)!))
        let id = store.profile.id
        store.webPassword = "fixture-password"
        store.suffix = "fixture-suffix"
        store.useNewDevice()
        XCTAssertNotEqual(store.profile.id, id)
        XCTAssertNil(store.profile.fingerprint)
        XCTAssertEqual(store.phase, "new")
        XCTAssertTrue(store.webPassword.isEmpty && store.suffix.isEmpty)
    }

    private func backupFixture(badDigest: Bool = false) throws -> Data {
        let entries = [
            try FactoryBackupArchive.Entry(name: "etc/rc.local", content: Data("#!/bin/sh\nexit 0\n".utf8), mode: 0o755),
            try FactoryBackupArchive.Entry(name: "etc/settings", content: Data("private fixture".utf8), mode: 0o600),
        ]
        let inner = try FactoryBackupArchive.gzip(FactoryBackupArchive.pack(entries), compress: true)
        let outer = [
            try FactoryBackupArchive.Entry(name: FactoryBackupArchive.innerPath, content: inner),
            try FactoryBackupArchive.Entry(
                name: FactoryBackupArchive.digestPath, content: Data((badDigest ? "invalid" : FactoryBackupArchive.md5(inner)).utf8)),
        ]
        return try FactoryBackupArchive.crypt(FactoryBackupArchive.gzip(FactoryBackupArchive.pack(outer), compress: true), password: "fixture", encrypt: true)
    }

    private func innerEntries(_ encrypted: Data) throws -> [FactoryBackupArchive.Entry] {
        let plain = try FactoryBackupArchive.crypt(encrypted, password: "fixture", encrypt: false)
        let outer = try FactoryBackupArchive.unpack(FactoryBackupArchive.gzip(plain, compress: false))
        return try FactoryBackupArchive.unpack(FactoryBackupArchive.gzip(outer.first { $0.name == FactoryBackupArchive.innerPath }!.content, compress: false))
    }
}
