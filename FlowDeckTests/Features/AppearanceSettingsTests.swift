import XCTest

@testable import FlowDeck

/// 验证图标异步状态边界，替身不调用系统接口、不更改桌面图标。
@MainActor
final class AppearanceSettingsTests: XCTestCase {
    func testAppearanceResolution() {
        XCTAssertNil(AppAppearance.resolve("system").colorScheme)
        XCTAssertNil(AppAppearance.resolve("unknown").colorScheme)
        XCTAssertEqual(AppAppearance.resolve("light").colorScheme, .light)
        XCTAssertEqual(AppAppearance.resolve("dark").colorScheme, .dark)
    }

    func testPendingRequestBlocksReentryAndFailureCanRetry() {
        let runtime = IconRuntimeStub()
        let controller = AppIconController(runtime: runtime)
        controller.select(.graphite)
        controller.select(.porcelain)
        XCTAssertEqual(runtime.requestCount, 1)
        XCTAssertEqual(controller.pending, .graphite)
        XCTAssertEqual(controller.current, .aurora)

        runtime.finish(error: NSError(domain: "test", code: 1))
        XCTAssertTrue(controller.failed)
        XCTAssertNil(controller.pending)
        XCTAssertEqual(controller.current, .aurora)
        controller.select(.graphite)
        XCTAssertEqual(runtime.requestCount, 2)
        runtime.alternateIconName = "GraphiteIcon"
        runtime.finish()
        XCTAssertEqual(controller.current, .graphite)
        XCTAssertFalse(controller.failed)
    }

    func testSuccessPrecedesReadbackAndDefaultCanBeRestored() {
        let runtime = IconRuntimeStub()
        let controller = AppIconController(runtime: runtime)
        controller.select(.porcelain)
        runtime.finish()
        controller.refresh()
        XCTAssertEqual(controller.current, .porcelain)
        runtime.alternateIconName = "PorcelainIcon"
        controller.refresh()
        controller.select(.aurora)
        XCTAssertNil(runtime.requestedName)
        runtime.alternateIconName = nil
        runtime.finish()
        XCTAssertEqual(controller.current, .aurora)
    }

    func testUnsupportedAndUnknownSystemIconDoNotPretendSuccess() {
        let runtime = IconRuntimeStub()
        runtime.supportsAlternateIcons = false
        runtime.alternateIconName = "FutureIcon"
        let controller = AppIconController(runtime: runtime)
        XCTAssertNil(controller.current)
        controller.select(.graphite)
        XCTAssertEqual(runtime.requestCount, 0)
        XCTAssertNil(controller.pending)
    }

    func testFailureAfterSystemChangeReflectsActualSelection() {
        let runtime = IconRuntimeStub()
        let controller = AppIconController(runtime: runtime)
        controller.select(.graphite)
        runtime.alternateIconName = "GraphiteIcon"
        runtime.finish(error: NSError(domain: "test", code: 2))
        XCTAssertEqual(controller.current, .graphite)
        XCTAssertFalse(controller.failed)
    }
}

@MainActor
private final class IconRuntimeStub: AppIconApplying {
    var supportsAlternateIcons = true
    var alternateIconName: String?
    private(set) var requestCount = 0
    private(set) var requestedName: String?
    private var completion: (@MainActor @Sendable (Error?) -> Void)?

    func apply(_ name: String?, completion: @escaping @MainActor @Sendable (Error?) -> Void) {
        requestCount += 1
        requestedName = name
        self.completion = completion
    }

    func finish(error: Error? = nil) {
        let callback = completion
        completion = nil
        callback?(error)
    }
}
