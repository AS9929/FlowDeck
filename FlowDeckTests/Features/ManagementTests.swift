import Security
import XCTest

@testable import FlowDeck

/// 新管理通道的状态回读、补偿恢复与凭据协议回归。全部替身运行，不访问真实路由器。
final class ManagementTests: XCTestCase {
    @MainActor
    func testMultipleDevicesAtSameAddressRemainIndependent() throws {
        let store = DeviceStore(defaults: UserDefaults(suiteName: "test.FlowDeck." + UUID().uuidString)!)
        let originalSelection = store.current
        let originalDemo = store.demoMode
        let originalCount = store.devices.count
        let first = DeviceProfile(name: "测试随身设备")
        var second = DeviceProfile(name: "测试家中设备")
        store.demoMode = true
        defer {
            store.remove(first)
            store.remove(second)
            if let originalSelection { store.select(originalSelection) }
            store.demoMode = originalDemo
        }

        try store.saveVerified(first, secret: "first-test-secret", webPassword: "first-test-password", factoryPassword: "")
        try store.saveVerified(second, secret: "second-test-secret", webPassword: "second-test-password", factoryPassword: "")
        XCTAssertEqual(store.devices.count, originalCount + 2)
        XCTAssertEqual(first.host, second.host)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(store.secret(for: first), "first-test-secret")
        XCTAssertEqual(store.secret(for: second), "second-test-secret")

        second.name = "已重命名设备"
        try store.saveVerified(second, secret: "second-test-secret", webPassword: "second-test-password", factoryPassword: "")
        XCTAssertEqual(store.devices.count, originalCount + 2)
        store.select(first)
        XCTAssertEqual(store.currentID, first.id)
        let reloaded = DeviceStore(defaults: store.defaults)
        XCTAssertEqual(reloaded.currentID, first.id)
        XCTAssertEqual(reloaded.devices.first(where: { $0.id == second.id })?.name, second.name)
        store.remove(second)
        XCTAssertEqual(store.currentID, first.id)
        XCTAssertTrue(store.devices.contains { $0.id == first.id })
    }

    @MainActor
    func testComponentVersionChecksRemainIndependent() async {
        let suite = "test.FlowDeck.Components." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let devices = DeviceStore(defaults: defaults)
        devices.demoMode = true
        let manager = ManagementStore()

        await manager.checkUpdates(devices)
        XCTAssertNotNil(manager.versions)
        XCTAssertEqual(manager.webVersion, "尚未检查")
        XCTAssertEqual(manager.operationTitle, "检查 Mihomo 核心版本")
        XCTAssertNil(manager.error)
        let coreVersion = manager.versions?.current

        await manager.checkWebSSHVersion(devices)
        XCTAssertTrue(manager.webVersion.contains("20260909"))
        XCTAssertEqual(manager.versions?.current, coreVersion)
        XCTAssertEqual(manager.operationTitle, "检查 WebSSH 版本")
        XCTAssertNil(manager.error)

        manager.clearDeviceResults()
        XCTAssertNil(manager.versions)
        XCTAssertEqual(manager.webVersion, "尚未检查")
    }

    func testConfigDifferenceCountsTextAndSections() {
        let difference = ConfigurationDifference(before: "mode: rule\ndns:\n  enable: true", after: "mode: global\ndns:\n  enable: true\nipv6: false")
        XCTAssertEqual(difference.inserted, 2)
        XCTAssertEqual(difference.removed, 1)
        XCTAssertEqual(difference.changedSections, ["ipv6", "mode"])
        let same = ConfigurationDifference(before: "a: 1", after: "a: 1")
        XCTAssertEqual(same.inserted + same.removed, 0)
    }

    @MainActor
    func testChangedConfigAfterPreviewIsRejectedBeforeWriting() async throws {
        let api = DemoWebSSH()
        let before = try await api.loadConfig()
        let store = DeviceStatusStore(api: api)
        store.authorizeWrite = {}
        var result: DeviceStatusStore.ImportStep?
        await store.importConfig("mode: global", expectedChecksum: "outdated") { result = $0 }
        guard case .failed(let reason) = result else { return XCTFail("过期预览应阻止写入") }
        XCTAssertTrue(reason.contains("发生了变化"))
        let actual = try await api.loadConfig()
        XCTAssertEqual(actual, before)
    }

    @MainActor
    func testMaintenanceHistorySeparatesSuccessAndFailure() async {
        let manager = ManagementStore()
        await manager.run("失败动作") { throw ManagementError.invalid("测试失败") }
        XCTAssertEqual(manager.recentOperations.first?.succeeded, false)
        await manager.run("成功动作") {}
        XCTAssertEqual(manager.recentOperations.first?.succeeded, true)
        XCTAssertEqual(manager.recentOperations.count, 2)
    }

    func testWifiQREscapesReservedCharacters() {
        var network = wifi("main_2g")
        network.ssid = "office;guest"
        network.password = "test:password"
        XCTAssertTrue(WifiShareView.payload(network).contains("S:office\\;guest;"))
        XCTAssertTrue(WifiShareView.payload(network).contains("P:test\\:password;"))
    }

    func testWifiValidationCountsUTF8Bytes() throws {
        var network = wifi("main_2g")
        network.ssid = String(repeating: "中", count: 10)
        XCTAssertNoThrow(try network.validate())
        network.ssid += "中文"
        XCTAssertThrowsError(try network.validate())
        network.ssid = "valid"
        network.password = "short"
        XCTAssertThrowsError(try network.validate())
        network.password = "long-enough"
        network.channel = "165"
        XCTAssertThrowsError(try network.validate())
    }

    func testWifiRejectsDisablingAllRadios() async {
        let api = DemoWebSSH()
        var networks = [wifi("main_2g"), wifi("main_5g")]
        networks[0].enabled = false
        networks[1].enabled = false
        do {
            try await api.saveWifiNetworks(networks)
            XCTFail("不应允许关闭全部无线频段")
        } catch { XCTAssertTrue(error is ManagementError) }
    }

    func testWifiReadWriteAndCommitFailureRecovery() async throws {
        let api = ManagementFixture(failure: .commit)
        let before = try await api.readWifiNetworks()
        var changed = before
        changed[0].ssid = "new-ssid"
        do {
            try await api.saveWifiNetworks(changed)
            XCTFail("模拟 commit 失败应抛出错误")
        } catch {}
        let actual = try await api.readWifiNetworks()
        XCTAssertEqual(actual, before)
        try await api.saveWifiNetworks(changed)
        let saved = try await api.readWifiNetworks()
        XCTAssertEqual(saved, changed)
    }

    func testWifiRecoverySurvivesReloadAndIsDeviceScoped() throws {
        let id = UUID().uuidString
        let before = [wifi("main_2g"), wifi("main_5g")]
        var after = before
        after[0].ssid = "changed"
        defer {
            try? WifiRecovery.clear(id)
        }
        try WifiRecovery(deviceID: id, before: before, requested: after).save()
        XCTAssertEqual(try WifiRecovery.load(id)?.before, before)
        XCTAssertEqual(try WifiRecovery.load(id)?.requested, after)
        XCTAssertNil(try WifiRecovery.load(UUID().uuidString))
        try WifiRecovery.clear(id)
        XCTAssertNil(try WifiRecovery.load(id))
    }

    func testBlacklistUsesDenyListOnBothBands() async throws {
        let api = DemoWebSSH()
        let mac = "AB:CD:EF:01:23:45"
        try await api.setClientBlocked(mac: mac, blocked: true)
        let values = try await api.rpc("uci", "get", params: JSONObject(["config": "wireless"])).object("values")
        for id in ["main_2g", "main_5g"] {
            XCTAssertEqual(values?.object(id)?.strings("denymaclist"), [mac])
            XCTAssertNil(values?.object(id)?.raw["maclist"])
        }
        try await api.setClientBlocked(mac: mac, blocked: false)
        let blocked = try await api.blockedClients()
        XCTAssertTrue(blocked.isEmpty)
    }

    func testBlacklistPreservesExistingAllowMode() async throws {
        let api = DemoWebSSH()
        _ = try await api.rpc(
            "uci", "set",
            params: JSONObject([
                "section": "main_2g", "values": ["macfilter": "allow", "allowmaclist": ["11:22:33:44:55:66"]],
            ]))
        do {
            try await api.setClientBlocked(mac: "AB:CD:EF:01:23:45", blocked: true)
            XCTFail("不能覆盖白名单")
        } catch {}
        let values = try await api.rpc("uci", "get", params: JSONObject()).object("values")?.object("main_2g")
        XCTAssertEqual(values?.string("macfilter"), "allow")
        XCTAssertEqual(values?.strings("allowmaclist"), ["11:22:33:44:55:66"])
    }

    func testSMSRejectsOversizedUnicodeAndInvalidNumbers() {
        XCTAssertNoThrow(try SMSValidation.validate(number: "+8610010", message: String(repeating: "中", count: 70)))
        XCTAssertThrowsError(try SMSValidation.validate(number: "10010", message: String(repeating: "😀", count: 36)))
        XCTAssertThrowsError(try SMSValidation.validate(number: "100;cmd", message: "hello"))
        XCTAssertThrowsError(try SMSValidation.validate(number: "10010", message: ""))
    }

    func testSMSSendsUTF16AndDoesNotRetrySubmission() async throws {
        let api = ManagementFixture(failure: .sms)
        do {
            try await api.sendSMS(number: "10010", message: "A😀")
            XCTFail("设备发送失败应抛出错误")
        } catch {}
        let sent = await api.sentSMS
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.string("message_body"), "0041D83DDE00")
        XCTAssertEqual(sent.first?.string("encode_type"), "UNICODE")
    }

    func testFactoryPINEncryptionMatchesOpenSSL() throws {
        let result = try FactoryEncryption.encryptPIN("1234", key: Data(repeating: 0x11, count: 32), iv: Data(repeating: 0x22, count: 16))
        XCTAssertEqual(result, "IiIiIiIiIiIiIiIiIiIiItVzc2HIaNJMNjoOerQMelM=")
        XCTAssertThrowsError(try FactoryEncryption.encryptPIN("1234", key: Data(), iv: Data()))
        XCTAssertThrowsError(try FactoryEncryption.wrapKey(Data(repeating: 1, count: 32), publicPEM: "invalid"))
    }

    func testFactoryPasswordUsesNestedUppercaseSHA256() {
        let expected = DeviceIdentity.digest(Data((DeviceIdentity.digest(Data("test".utf8)).uppercased() + "salt").utf8)).uppercased()
        XCTAssertEqual(FactoryClient.passwordDigest("test", salt: "salt"), expected)
    }

    func testIdentityRejectsMissingOrInvalidHardwareAndDistinguishesDevices() {
        XCTAssertNil(DeviceIdentity.fingerprint(model: "MU5250", imei: ""))
        XCTAssertNil(DeviceIdentity.fingerprint(model: nil, imei: "868000001234567"))
        XCTAssertNil(DeviceIdentity.fingerprint(model: "MU5250", imei: "not-an-imei-at-all"))
        XCTAssertNotEqual(
            DeviceIdentity.fingerprint(model: "MU5250", imei: "868000001234567"),
            DeviceIdentity.fingerprint(model: "MU5250", imei: "868000001234568"))
    }

    func testHistoryRetainsFiveAndDeduplicatesCurrent() throws {
        let id = UUID().uuidString
        for index in 0..<7 {
            try ConfigHistory.save("configuration-\(index)", deviceID: id)
        }
        try ConfigHistory.save("configuration-6", deviceID: id)
        let history = try ConfigHistory.list(deviceID: id)
        XCTAssertEqual(history.count, 5)
        XCTAssertEqual(history.first?.content, "configuration-6")
        XCTAssertEqual(history.last?.content, "configuration-2")
        XCTAssertEqual(history.first?.checksum, DeviceIdentity.digest(Data("configuration-6".utf8)))
        XCTAssertTrue(try ConfigHistory.list(deviceID: UUID().uuidString).isEmpty)
    }

    @MainActor
    func testImportRestoresPreviousFileAfterCheckTransportFailure() async throws {
        let api = ManagementFixture(failure: .check)
        let before = try await api.loadConfig()
        let store = DeviceStatusStore(api: api)
        store.authorizeWrite = {}
        store.historyDeviceID = UUID().uuidString
        var steps: [DeviceStatusStore.ImportStep] = []
        await store.importConfig("rules:\n  - MATCH,DIRECT") {
            steps.append($0)
        }
        guard case .rolledBack = steps.last else {
            return XCTFail("期望回滚，实际 \(steps)")
        }
        let after = try await api.loadConfig()
        XCTAssertEqual(after, before)
        XCTAssertNil(store.busy)
    }

    @MainActor
    func testImportRestoresStoppedStateAfterRestartFailure() async throws {
        let api = ManagementFixture(failure: .restart)
        _ = try await api.control(.stop)
        let store = DeviceStatusStore(api: api)
        store.authorizeWrite = {}
        store.historyDeviceID = UUID().uuidString
        var steps: [DeviceStatusStore.ImportStep] = []
        await store.importConfig("rules:\n  - MATCH,DIRECT") {
            steps.append($0)
        }
        guard case .rolledBack = steps.last else {
            return XCTFail("期望恢复旧状态")
        }
        let state = try await api.mihomoStatus()
        XCTAssertFalse(state.running)
    }

    func testAPNCRUDAndRoamingReadback() async throws {
        let api = DemoWebSSH()
        try await api.saveAPN(APNProfile(values: JSONObject(["profilename": "Test APN", "wanapn": "internet.example", "pdpType": 3, "pppAuthMode": 0])))
        let profiles = try await api.apnProfiles()
        let id = try XCTUnwrap(
            profiles.first {
                $0.name == "Test APN"
            }?.id)
        try await api.selectAPN(id)
        let mode = try await api.read("zwrt_apn_object", "get_apn_mode")
        XCTAssertEqual(mode.int("apn_mode"), 1)
        try await api.selectAPN(nil)
        try await api.setRoaming(true)
        try await api.setDirectPower(true)
        let roaming = try await api.read("zwrt_data", "get_wwaniface")
        XCTAssertEqual(roaming.int("roam_enable"), 1)
    }

    func testBandMaskSupportsAbove64AndDoesNotUseSupportedBandList() {
        let bands = [1, 3, 48, 66, 71]
        XCTAssertEqual(BandSelection.lte(BandSelection.mask(bands)), Set(bands))
        XCTAssertNil(BandSelection.lte("1,3,48"))
        XCTAssertEqual(BandSelection.nr("1, 3, 78"), [1, 3, 78])
    }

    @MainActor
    func testReadOnlyBlocksDeviceWrite() async {
        let devices = DeviceStore(defaults: UserDefaults(suiteName: "test.FlowDeck." + UUID().uuidString)!)
        let previous = devices.readOnly
        devices.readOnly = true
        defer {
            devices.readOnly = previous
        }
        do {
            _ = try await ManagementStore().verifiedAPI(devices)
            XCTFail("只读应拒绝写入")
        } catch { XCTAssertTrue(error is ManagementError) }
    }

    func testRollbackRefusesActiveInstaller() async {
        let api = ManagementFixture(failure: .installing)
        do {
            try await api.rollbackCore()
            XCTFail("不能与安装器并发覆盖核心")
        } catch {}
        let scripts = await api.executedScripts
        XCTAssertEqual(scripts, 0)
    }

    func testFactoryPublicKeyWrapRoundTrip() throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let raw = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        func field(_ tag: UInt8, _ content: Data) -> Data {
            let count = content.count
            let length: [UInt8] = count < 128 ? [UInt8(count)] : [0x82, UInt8(count >> 8), UInt8(count & 255)]
            return Data([tag] + length) + content
        }
        let algorithm = Data([0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00])
        let spki = field(0x30, algorithm + field(0x03, Data([0]) + raw))
        let pem = "-----BEGIN PUBLIC KEY-----" + spki.base64EncodedString() + "-----END PUBLIC KEY-----"
        let key = Data(repeating: 0x17, count: 32)
        let ciphertext = try FactoryEncryption.wrapKey(key, publicPEM: pem)
        let data = try XCTUnwrap(Data(base64Encoded: ciphertext))
        let plaintext = try XCTUnwrap(SecKeyCreateDecryptedData(privateKey, .rsaEncryptionPKCS1, data as CFData, nil)) as Data
        XCTAssertEqual(String(data: plaintext, encoding: .utf8), String(repeating: "17", count: 32))
    }

    func testPINRejectsInvalidInputBeforeLogin() {
        XCTAssertNoThrow(try FactoryClient.validatePIN(action: "enable", pin: "1234", newPIN: "", puk: ""))
        XCTAssertThrowsError(try FactoryClient.validatePIN(action: "enable", pin: "１２３４", newPIN: "", puk: ""))
        XCTAssertThrowsError(try FactoryClient.validatePIN(action: "change", pin: "1234", newPIN: "12", puk: ""))
        XCTAssertThrowsError(try FactoryClient.validatePIN(action: "puk", pin: "1234", newPIN: "", puk: "1234567"))
    }

    @MainActor
    func testQuickNodeSelectionStaysWithinCurrentGroup() async throws {
        let proxies = try await DemoMihomo().proxies()
        let group = try XCTUnwrap(SystemActionRunner.nextNodeGroup(proxies))
        let next = try XCTUnwrap(SystemActionRunner.nextNode(in: group, proxies: proxies))
        XCTAssertTrue(proxies[group]?.all?.contains(next) == true)
        XCTAssertNotEqual(next, proxies[group]?.now)
        XCTAssertFalse(proxies[next]?.isGroup ?? true)
    }

    func testSnapshotCacheRemovesSensitiveIdentifiers() async throws {
        let id = UUID().uuidString
        let snapshot = try await DemoWebSSH().snapshot()
        defer { DeviceSnapshotCache.remove(id) }
        try DeviceSnapshotCache.save(snapshot, deviceID: id)
        let cached = try XCTUnwrap(DeviceSnapshotCache.load(id))
        XCTAssertNil(cached.snapshot.imei)
        XCTAssertNil(cached.snapshot.iccid)
        XCTAssertNil(cached.snapshot.imsi)
        XCTAssertNil(cached.snapshot.msisdn)
        XCTAssertEqual(cached.snapshot.battery, snapshot.battery)
        XCTAssertNil(DeviceSnapshotCache.load(UUID().uuidString))
    }

    @MainActor
    func testDeviceSwitchDiscardsInflightSnapshot() async throws {
        let store = DeviceStatusStore(api: DemoWebSSH(), deviceID: UUID().uuidString)
        store.authorizeWrite = {}
        let request = Task { await store.refreshSnapshot() }
        try await Task.sleep(nanoseconds: 10_000_000)
        store.use(DemoWebSSH(), deviceID: UUID().uuidString)
        await request.value
        XCTAssertNil(store.snapshot)
        XCTAssertNil(store.snapshotAt)
    }

    private func wifi(_ id: String) -> WifiNetwork {
        WifiNetwork(id: id, ssid: "U60", password: "example-pass", hidden: false, enabled: true, channel: "auto", encryption: "psk2+ccmp")
    }
}

/// 在真实业务调用顺序中注入一次失败，验证补偿路径，不与实现细节逐行镜像。
private actor ManagementFixture: WebSSHAPI {
    enum Failure {
        case commit, check, restart, sms, installing
    }
    let base = DemoWebSSH()
    let failure: Failure
    var consumed = false
    var sentSMS: [JSONObject] = []
    var executedScripts = 0
    init(failure: Failure) {
        self.failure = failure
    }

    func rpc(_ service: String, _ method: String, params: JSONObject) async throws -> JSONObject {
        if method == "exec" {
            executedScripts += 1
        }
        if method == "zte_libwms_send_sms" {
            sentSMS.append(params)
        }
        if failure == .sms, method == "zwrt_wms_get_cmd_status" {
            return JSONObject(["sms_cmd_status_result": 2])
        }
        if failure == .commit, method == "commit", !consumed {
            consumed = true
            throw URLError(.networkConnectionLost)
        }
        return try await base.rpc(service, method, params: params)
    }
    func management(_ method: String, _ path: String, body: JSONObject?) async throws -> JSONObject {
        if failure == .installing, path == "api/mihomo/install/status" {
            return JSONObject(["data": ["state": "installing"]])
        }
        return try await base.management(method, path, body: body)
    }
    func mihomoStatus() async throws -> MihomoServiceStatus {
        try await base.mihomoStatus()
    }
    func control(_ action: ProxyAction) async throws -> String {
        if failure == .restart, action == .restart, !consumed {
            consumed = true
            throw URLError(.networkConnectionLost)
        }
        return try await base.control(action)
    }
    func setAutostart(_ enabled: Bool) async throws {
        try await base.setAutostart(enabled)
    }
    func connectivity() async throws -> Bool {
        try await base.connectivity()
    }
    func loadConfig() async throws -> String {
        try await base.loadConfig()
    }
    func saveConfig(_ content: String) async throws {
        try await base.saveConfig(content)
    }
    func checkConfig() async throws -> ConfigCheckResult {
        if failure == .check, !consumed {
            consumed = true
            throw URLError(.timedOut)
        }
        return try await base.checkConfig()
    }
    func dataVersion() async throws -> DataVersion {
        try await base.dataVersion()
    }
    func startDataUpdate() async throws -> DataUpdateStatus {
        try await base.startDataUpdate()
    }
    func dataUpdateStatus() async throws -> DataUpdateStatus {
        try await base.dataUpdateStatus()
    }
    func snapshot() async throws -> DeviceSnapshot {
        try await base.snapshot()
    }
    func clients() async throws -> [LANClient] {
        try await base.clients()
    }
    func sms() async throws -> [SMSMessage] {
        try await base.sms()
    }
    func markSMSRead(id: Int) async throws {
        try await base.markSMSRead(id: id)
    }
    func wifiSettings() async throws -> [String: WifiRadioSettings] {
        try await base.wifiSettings()
    }
    func setWifi(_ settings: [String: WifiRadioSettings]) async throws {
        try await base.setWifi(settings)
    }
    func setNetworkMode(_ mode: NetworkMode) async throws {
        try await base.setNetworkMode(mode)
    }
    func lockLTEBands(_ bands: [Int]) async throws {
        try await base.lockLTEBands(bands)
    }
    func lockNRBands(_ bands: [Int]) async throws {
        try await base.lockNRBands(bands)
    }
    func reboot() async throws {
        try await base.reboot()
    }
}
