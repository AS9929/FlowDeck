import XCTest

/// 只使用演示数据检查导航生命周期，不连接设备，不执行维护操作。
final class NavigationTransitionTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // App 在 Debug 下将导航测试隔离到独立偏好域。
        app.launchArguments = ["-demoMode", "YES", "--navigation-audit"]
        app.launch()
    }

    func testPreferredGroupMenuUpdatesOverviewAndSurvivesTabSwitch() {
        app.tabBars.buttons["Mihomo"].tap()
        app.buttons["策略操作"].tap()
        let picker = app.descendants(matching: .any).matching(identifier: "preferred-policy-group").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        picker.tap()
        let japan = app.buttons["日本"].firstMatch
        XCTAssertTrue(japan.waitForExistence(timeout: 3))
        japan.tap()
        app.tabBars.buttons["总览"].tap()
        XCTAssertTrue(app.staticTexts["常用策略 · 日本"].waitForExistence(timeout: 3))
        app.tabBars.buttons["设备"].tap()
        app.tabBars.buttons["总览"].tap()
        XCTAssertTrue(app.staticTexts["常用策略 · 日本"].exists)
    }

    func testEveryTabRestoresItsBarAfterNestedPush() {
        for tab in ["总览", "Mihomo", "设备", "工具"] {
            app.tabBars.buttons[tab].tap()
            app.buttons["App 设置"].tap()
            XCTAssertTrue(app.navigationBars["App 设置"].waitForExistence(timeout: 3))
            XCTAssertFalse(app.tabBars.buttons[tab].isHittable)
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "关于驭流")).firstMatch.tap()
            XCTAssertTrue(app.navigationBars["关于"].waitForExistence(timeout: 3))
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["App 设置"].waitForExistence(timeout: 3))
            XCTAssertFalse(app.tabBars.buttons[tab].isHittable)
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.tabBars.buttons[tab].waitForExistence(timeout: 3))
            XCTAssertTrue(app.tabBars.buttons[tab].isHittable)
        }
    }

    func testMihomoAndDeviceOwnTheirManagementPages() {
        app.tabBars.buttons["Mihomo"].tap()
        app.segmentedControls.buttons["配置"].tap()
        openRow("核心更新")
        XCTAssertTrue(app.navigationBars["Mihomo 核心更新"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["重启 WebSSH"].exists)
        XCTAssertFalse(app.tabBars.buttons["Mihomo"].isHittable)
        app.navigationBars.buttons.firstMatch.tap()

        app.tabBars.buttons["设备"].tap()
        openRow("原厂设置备份")
        XCTAssertTrue(app.navigationBars["原厂设置备份"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.tabBars.buttons["设备"].isHittable)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.tabBars.buttons["设备"].isHittable)
    }

    func testToolsOwnConnectionAndWebSSH() {
        app.tabBars.buttons["工具"].tap()
        openRow("接入新设备")
        XCTAssertTrue(app.navigationBars["接入设备"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.tabBars.buttons["工具"].isHittable)
        app.navigationBars.buttons.firstMatch.tap()

        openRow("WebSSH")
        XCTAssertTrue(app.navigationBars["WebSSH 管理服务"].waitForExistence(timeout: 3))
        openRow("检查 WebSSH 版本")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "20260909")).firstMatch.waitForExistence(timeout: 3))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.tabBars.buttons["工具"].isHittable)
    }

    /// 在完整节点页原地断言选中态，不能依赖返回重建页面来刷新。
    func testFullNodeListUpdatesSelectionWithoutLeavingPage() {
        app.tabBars.buttons["Mihomo"].tap()
        let group = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Proxies，当前")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 3))
        if group.value as? String != "已展开" {
            group.tap()
        }
        let allOptions = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "查看全部")).firstMatch
        for _ in 0..<4 {
            if allOptions.isHittable { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(allOptions.isHittable)
        allOptions.tap()
        XCTAssertTrue(app.navigationBars["Proxies"].waitForExistence(timeout: 3))
        let option = app.buttons["proxyOption.自动选择"]
        XCTAssertTrue(option.waitForExistence(timeout: 3))
        option.tap()
        let selected = NSPredicate(format: "value == %@", "已选择")
        expectation(for: selected, evaluatedWith: option)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.navigationBars["Proxies"].exists)
    }

    /// 滚动到入口再点击，覆盖迁移后处于屏幕下方的设置项。
    private func openRow(_ title: String) {
        let row = app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + "、")).firstMatch
        for _ in 0..<5 {
            if row.isHittable {
                row.tap()
                return
            }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTFail("没有可点击的入口：" + title)
    }

    func testInteractiveBackCancellationAndCompletion() {
        app.buttons["App 设置"].tap()
        XCTAssertTrue(app.navigationBars["App 设置"].waitForExistence(timeout: 3))
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.55))
        let shortDistance = app.coordinate(withNormalizedOffset: CGVector(dx: 0.20, dy: 0.55))
        edge.press(
            forDuration: 0.05, thenDragTo: shortDistance, withVelocity: .slow,
            thenHoldForDuration: 0.3)
        XCTAssertTrue(app.navigationBars["App 设置"].exists)
        XCTAssertFalse(app.tabBars.buttons["总览"].isHittable)
        let fullDistance = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.55))
        edge.press(
            forDuration: 0.05, thenDragTo: fullDistance, withVelocity: .slow,
            thenHoldForDuration: 0.3)
        XCTAssertTrue(app.tabBars.buttons["总览"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.tabBars.buttons["总览"].isHittable)
    }

    func testOnboardingLinksKeepTabHiddenUntilRoot() {
        app.terminate()
        app.launchArguments = ["-demoMode", "NO", "--navigation-audit"]
        app.launch()
        app.buttons["接入我的设备"].tap()
        XCTAssertTrue(app.navigationBars["接入设备"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.tabBars.buttons["总览"].isHittable)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "原厂设备、")).firstMatch.exists)
        for backend in ["webSSH", "ufiTools"] {
            let entry = app.buttons["onboarding." + backend]
            XCTAssertTrue(entry.waitForExistence(timeout: 3))
            entry.tap()
            XCTAssertTrue(app.navigationBars["添加设备"].waitForExistence(timeout: 3))
            XCTAssertFalse(app.tabBars.buttons["总览"].isHittable)
            app.navigationBars.buttons.firstMatch.tap()
        }
        XCTAssertTrue(app.navigationBars["接入设备"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.tabBars.buttons["总览"].isHittable)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.tabBars.buttons["总览"].waitForExistence(timeout: 3))
    }
    func testUnboundTabsGuideSetupAndExplicitDemoUnlocksPreview() {
        app.terminate()
        app.launchArguments = ["-demoMode", "NO", "--navigation-audit"]
        app.launch()
        XCTAssertTrue(app.buttons["接入我的设备"].waitForExistence(timeout: 3))
        for tab in ["Mihomo", "设备"] {
            app.tabBars.buttons[tab].tap()
            XCTAssertTrue(app.staticTexts["先接入你的设备"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons["接入设备"].exists)
            XCTAssertFalse(app.buttons["规则判定"].exists)
        }
        app.buttons["App 设置"].tap()
        XCTAssertTrue(app.navigationBars["App 设置"].waitForExistence(timeout: 3))
        app.navigationBars.buttons.firstMatch.tap()
        app.tabBars.buttons["工具"].tap()
        openRow("接入新设备")
        XCTAssertTrue(app.navigationBars["接入设备"].waitForExistence(timeout: 3))
        app.navigationBars.buttons.firstMatch.tap()
        app.tabBars.buttons["总览"].tap()
        app.buttons["先体验演示"].tap()
        app.tabBars.buttons["Mihomo"].tap()
        XCTAssertTrue(app.segmentedControls.buttons["策略"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["先接入你的设备"].exists)
    }

}
