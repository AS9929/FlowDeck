import XCTest

/// 使用模拟器中已保存的 F50，只打开页面和读取状态，不更新软件、保存设置或发送消息。
final class F50NavigationTests: XCTestCase {
    func testExistingF50MaintenanceDestinations() throws {
        try checkMaintenanceDestinations(largeText: false)
    }

    func testF50MaintenanceWithAccessibilityText() throws {
        try checkMaintenanceDestinations(largeText: true)
    }

    func testSMSAndClientUDPDiagnostics() throws {
        try checkSMSAndDiagnostics(largeText: false)
    }

    func testSMSAndClientUDPWithAccessibilityText() throws {
        try checkSMSAndDiagnostics(largeText: true)
    }

    private func checkSMSAndDiagnostics(largeText: Bool) throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["FLOWDECK_F50_UI_READONLY"] == "1" else {
            throw XCTSkip("Requires an already configured F50 in this simulator")
        }
        let app = XCUIApplication()
        if largeText {
            app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        let device = app.tabBars.buttons["设备"]
        XCTAssertTrue(device.waitForExistence(timeout: 10))
        device.tap()
        let sms = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "收件、发件、草稿与搜索")).firstMatch
        for _ in 0..<7 {
            if sms.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(sms.isHittable)
        sms.tap()
        XCTAssertTrue(app.navigationBars["短信"].waitForExistence(timeout: 5))
        let inventory = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "设备存储：")).firstMatch
        XCTAssertTrue(inventory.waitForExistence(timeout: 20))
        for _ in 0..<5 {
            if inventory.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(inventory.isHittable)
        let smsImage = XCTAttachment(screenshot: app.screenshot())
        smsImage.name = largeText ? "短信-最大文字" : "短信-存储核对"
        smsImage.lifetime = .keepAlways
        add(smsImage)
        app.navigationBars.buttons.firstMatch.tap()
        app.tabBars.buttons["工具"].tap()
        let diagnostic = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "网络诊断")).firstMatch
        for _ in 0..<7 {
            if diagnostic.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(diagnostic.isHittable)
        diagnostic.tap()
        XCTAssertTrue(app.navigationBars["网络诊断"].waitForExistence(timeout: 5))
        let udp = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "手机 UDP 出口")).firstMatch
        XCTAssertTrue(udp.waitForExistence(timeout: 35))
        for _ in 0..<14 {
            if udp.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(udp.isHittable)
        let simulatorExplanation = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "模拟器使用 Mac 网络")
        ).firstMatch
        XCTAssertTrue(simulatorExplanation.exists)
        let udpImage = XCTAttachment(screenshot: app.screenshot())
        udpImage.name = largeText ? "UDP-最大文字" : "UDP-手机出口"
        udpImage.lifetime = .keepAlways
        add(udpImage)
    }

    private func checkMaintenanceDestinations(largeText: Bool) throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["FLOWDECK_F50_UI_READONLY"] == "1" else {
            throw XCTSkip("Requires an already configured F50 in this simulator")
        }
        let app = XCUIApplication()
        if largeText {
            app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        let device = app.tabBars.buttons["设备"]
        XCTAssertTrue(device.waitForExistence(timeout: 10))
        device.tap()
        for (rowTitle, pageTitle) in [("UFI-TOOLS 更新", "UFI-TOOLS 更新"), ("短信自动转发", "短信自动转发")] {
            let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", rowTitle)).firstMatch
            for _ in 0..<7 {
                if row.isHittable { break }
                app.swipeUp()
            }
            XCTAssertTrue(row.isHittable)
            row.tap()
            XCTAssertTrue(app.navigationBars[pageTitle].waitForExistence(timeout: 5))
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = pageTitle + (largeText ? "-最大文字" : "")
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let lastTitle = pageTitle == "UFI-TOOLS 更新" ? "恢复上一个 APK" : "保存过滤规则"
            let lastButton = app.buttons[lastTitle]
            for _ in 0..<12 {
                if lastButton.isHittable { break }
                app.swipeUp()
            }
            XCTAssertTrue(lastButton.isHittable, "页面底部必须可滚动到达")
            app.navigationBars.buttons.firstMatch.tap()
        }
    }
}
