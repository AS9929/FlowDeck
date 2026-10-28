import XCTest

@testable import FlowDeck

/// 官方资产选择和后台事务生成测试；不会下载或替换真机核心。
final class UFICoreUpdateTests: XCTestCase {
    private func fixture() -> [String: Any] {
        [
            "tag_name": "v1.19.32", "draft": false, "prerelease": false,
            "assets": [
                [
                    "name": "mihomo-android-arm64-v8-v1.19.32.gz", "size": 100,
                    "digest": "sha256:" + String(repeating: "a", count: 64),
                    "browser_download_url": "https://github.com/MetaCubeX/mihomo/releases/download/v1.19.32/mihomo-android-arm64-v8-v1.19.32.gz",
                ]
            ],
        ]
    }

    func testOfficialStableAndroidAssetRequiresDigestAndExactURL() throws {
        XCTAssertEqual(try UFICoreRelease(json: JSONObject(fixture())).version, "v1.19.32")
        for key in ["digest", "browser_download_url", "name", "size"] {
            var json = fixture()
            var assets = json["assets"] as! [[String: Any]]
            assets[0].removeValue(forKey: key)
            json["assets"] = assets
            XCTAssertThrowsError(try UFICoreRelease(json: JSONObject(json)))
        }
        var json = fixture()
        json["prerelease"] = true
        XCTAssertThrowsError(try UFICoreRelease(json: JSONObject(json)))
        json = fixture()
        json["tag_name"] = "v1.19.32'; echo bad"
        XCTAssertThrowsError(try UFICoreRelease(json: JSONObject(json)))
    }

    func testUpdateScriptKeepsDownloadBeforeStopAndPrivateRecovery() throws {
        let release = try UFICoreRelease(json: JSONObject(fixture()))
        let script = try UFICoreUpdateScript.make(release: release, port: 7890)
        XCTAssertTrue(script.contains("--proto '=https'"))
        XCTAssertFalse(script.contains("--insecure"))
        XCTAssertTrue(script.contains("sha256sum -c"))
        XCTAssertTrue(script.contains("mkdir \"$operation\""))
        XCTAssertTrue(script.contains("state rolled-back"))
        XCTAssertTrue(script.contains("trap finish EXIT"))
        XCTAssertThrowsError(try UFICoreUpdateScript.make(release: release, port: 0))
        let rollback = try UFICoreUpdateScript.make(release: nil, port: 7890)
        XCTAssertFalse(rollback.contains("releases/download"))
        XCTAssertTrue(rollback.contains("sha256sum -c .flowdeck-core.previous.sha256"))
        // 供宿主机故障注入测试使用；这里没有用户设备数据或凭据。
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CoreScriptFixtures")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try script.write(to: directory.appendingPathComponent("install.sh"), atomically: true, encoding: .utf8)
        try rollback.write(to: directory.appendingPathComponent("rollback.sh"), atomically: true, encoding: .utf8)
        let offline = try UFICoreUpdateScript.make(release: release, port: 7890, localPackage: true)
        XCTAssertFalse(offline.contains("releases/download"))
        XCTAssertTrue(offline.contains("/data/local/flowdeck-packages/" + release.checksum))
        try offline.write(to: directory.appendingPathComponent("offline.sh"), atomically: true, encoding: .utf8)
    }
}
