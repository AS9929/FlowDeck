import XCTest

@testable import FlowDeck

/// 射频格式、消息状态和恢复包边界；设备用例仅读取，不切换频段、Wi-Fi 或小区。
final class UFIRadioArchiveTests: XCTestCase {
    func testBandsDistinguishAutomaticMissingAndMalformed() throws {
        XCTAssertEqual(try UFIRadioState.bands(""), [])
        XCTAssertEqual(try UFIRadioState.bands("78,1"), [1, 78])
        for value: Any? in [nil, 1, "1,,3", "1,1", "0", "-1", "78;reboot", "0xff", "1.5", "1025"] {
            XCTAssertThrowsError(try UFIRadioState.bands(value))
        }
    }

    func testRadioRequiresSupportedNRAndValidCells() throws {
        let state = try UFIRadioState(JSONObject(["lte_band_lock": "", "nr_band_lock": "", "locked_cell_info": []]), supportedNR: [78])
        XCTAssertEqual(try state.bandForm([78], technology: .nr)["nr_band_lock"], "78")
        XCTAssertThrowsError(try state.bandForm([79], technology: .nr))
        XCTAssertThrowsError(try state.bandForm([99], technology: .lte))
        for cell in [
            UFILockedCell(technology: .lte, pci: 504, frequency: 100),
            UFILockedCell(technology: .nr, pci: 1008, frequency: 100),
            UFILockedCell(technology: .nr, pci: 1, frequency: -1),
        ] {
            XCTAssertThrowsError(try cell.form())
        }
        XCTAssertEqual(try UFILockedCell(technology: .nr, pci: 1007, frequency: 3_279_165).form()["rat"], "16")
    }

    func testMessagesIncludeOutgoingFailureAndDrafts() throws {
        let rows = (0...4).map { tag in
            ["id": String(tag), "number": "10010", "tag": String(tag), "content": Data("测试".utf8).base64EncodedString()]
        }
        let messages = try UFIDeviceParser.messages(JSONObject(["messages": rows]))
        XCTAssertEqual(messages.filter(UFIMailbox.inbox.contains).count, 2)
        XCTAssertEqual(messages.filter(UFIMailbox.sent.contains).map(\.id), [2])
        XCTAssertEqual(messages.filter(UFIMailbox.failed.contains).map(\.id), [3])
        XCTAssertEqual(messages.filter(UFIMailbox.drafts.contains).map(\.id), [4])
        XCTAssertEqual(messages.filter(\.unread).map(\.id), [1])
    }

    private func archive() throws -> UFISettingsArchive {
        let points = ["0", "1"].map { chip in
            UFIWifiAccessPoint(
                chip: chip, index: "0", enabled: true, authMode: "WPA2PSK", isolation: nil,
                ssid: "fixture", password: "secret-wifi", hidden: false, maxClients: 10)
        }
        var raw: [String: Any] = ["apn_mode": "auto", "default_APN_size": "0"]
        for index in 0..<20 { raw["APN_config\(index)"] = "" }
        return try UFISettingsArchive(
            version: 1, fingerprint: "fixture-device", firmware: "F50_FLYMODEM_ZYV1.0.0B09",
            createdAt: Date(), wifi: points, apns: UFIAPNState(JSONObject(raw)), configuration: "secret: private-token\n")
    }

    func testRestoreDraftPreservesLiveWifiCapabilitiesAndAPNSlots() throws {
        let saved = try archive().wifi[0]
        let current = UFIWifiAccessPoint(
            chip: saved.chip, index: saved.index, enabled: false, authMode: saved.authMode,
            isolation: "1", ssid: saved.ssid, password: saved.password,
            hidden: saved.hidden, maxClients: saved.maxClients)
        let wifi = try UFISettingsRestore.wifi(saved, current: current)
        XCTAssertFalse(wifi.enabled)
        XCTAssertEqual(wifi.isolation, "1")
        XCTAssertThrowsError(try UFISettingsRestore.wifi(archive().wifi[1], current: current))

        var profile = UFIAPNProfile.draft(index: 0)
        profile.name = "Restored"
        profile.apn = "example.net"
        var raw: [String: Any] = ["apn_mode": "auto", "default_APN_size": "2"]
        for index in 0..<20 {
            raw["APN_config\(index)"] = ""
        }
        var occupied = profile.ipv4
        occupied[0] = "Existing"
        occupied[7] = "IPv4v6"
        raw["APN_config2"] = occupied.joined(separator: "($)")
        let state = try UFIAPNState(JSONObject(raw))
        let draft = try UFISettingsRestore.apn(profile, current: state)
        XCTAssertEqual(draft.index, 3)
        XCTAssertEqual(draft.ipv4, profile.ipv4)
        XCTAssertEqual(state.profiles.first?.name, "Existing")
        raw["default_APN_size"] = "20"
        XCTAssertThrowsError(try UFISettingsRestore.apn(profile, current: UFIAPNState(JSONObject(raw))))
    }

    func testArchiveRoundTripTamperWrongPasswordAndDevice() throws {
        let original = try archive()
        let data = try SettingsArchiveCipher.seal(original, password: "test-password-123")
        XCTAssertNil(data.range(of: Data("private-token".utf8)))
        XCTAssertNil(data.range(of: Data("secret-wifi".utf8)))
        let restored = try SettingsArchiveCipher.open(data, password: "test-password-123", fingerprint: "fixture-device")
        XCTAssertEqual(restored.wifi, original.wifi)
        XCTAssertEqual(restored.configuration, original.configuration)
        XCTAssertThrowsError(try SettingsArchiveCipher.open(data, password: "wrong-password-123", fingerprint: "fixture-device"))
        XCTAssertThrowsError(try SettingsArchiveCipher.open(data, password: "test-password-123", fingerprint: "other-device"))
        var changed = data
        changed[changed.count - 1] ^= 1
        XCTAssertThrowsError(try SettingsArchiveCipher.open(changed, password: "test-password-123", fingerprint: "fixture-device"))
        XCTAssertThrowsError(try SettingsArchiveCipher.seal(original, password: "short"))
    }

    func testArchiveRejectsTruncationAndOversizeBeforeDecryption() {
        for data in [Data(), Data(repeating: 0, count: SettingsArchiveCipher.maximumBytes + 1)] {
            XCTAssertThrowsError(try SettingsArchiveCipher.open(data, password: "test-password-123", fingerprint: "fixture-device"))
        }
    }

    func testLiveRadioReadAndEncryptedSettingsRoundTrip() async throws {
        guard let path = ProcessInfo.processInfo.environment["FLOWDECK_F50_TEST_CREDENTIALS"] else {
            throw XCTSkip("Private credentials not provided")
        }
        let credentials = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let url = try XCTUnwrap(URL(string: try XCTUnwrap(credentials["ufiURL"])))
        let password = try XCTUnwrap(credentials["password"])
        let factory = try XCTUnwrap(credentials["factoryPassword"])
        let probe = UFIClient(baseURL: url, password: password)
        let snapshot = try await probe.snapshot()
        let client = UFIClient(baseURL: url, password: password, expectedFingerprint: snapshot.identityFingerprint)
        let state = try await client.radioState(password: factory)
        XCTAssertNotNil(state.supportedNR)
        let backup = try await client.captureSettings(password: factory)
        let temporaryPassword = UUID().uuidString
        let encrypted = try SettingsArchiveCipher.seal(backup, password: temporaryPassword)
        let restored = try SettingsArchiveCipher.open(encrypted, password: temporaryPassword, fingerprint: backup.fingerprint)
        XCTAssertEqual(DeviceIdentity.digest(Data(restored.configuration.utf8)), DeviceIdentity.digest(Data(backup.configuration.utf8)))
        XCTAssertEqual(restored.wifi, backup.wifi)
        XCTAssertEqual(restored.apns, backup.apns)
    }
}
