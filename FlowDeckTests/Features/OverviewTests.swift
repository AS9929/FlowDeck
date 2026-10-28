import XCTest

@testable import FlowDeck

/// 首页联网标题必须反映读取新鲜度，不把缓存中的联网值显示成当前状态。
final class OverviewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testFreshCellularStatusDoesNotClaimProxyEgress() {
        let state = OverviewNetworkState(connected: true, updatedAt: now, error: nil, now: now)
        XCTAssertEqual(state.title, "蜂窝已联网")
        XCTAssertFalse(state.needsAttention)
    }

    func testOldConnectedSnapshotRequiresRefresh() {
        let state = OverviewNetworkState(connected: true, updatedAt: now.addingTimeInterval(-16), error: nil, now: now)
        XCTAssertEqual(state.title, "设备状态待刷新")
        XCTAssertTrue(state.needsAttention)
    }

    func testReadFailureOverridesCachedConnectedState() {
        let state = OverviewNetworkState(connected: true, updatedAt: now, error: "连接失败", now: now)
        XCTAssertEqual(state.title, "设备连接待恢复")
        XCTAssertTrue(state.needsAttention)
    }

    func testMissingConfigurationAndLoadingAreDifferent() {
        let missing = OverviewNetworkState(connected: nil, updatedAt: nil, error: nil, now: now, managementAvailable: false)
        XCTAssertEqual(missing.title, "设备管理未配置")
        XCTAssertTrue(missing.needsAttention)
        let loading = OverviewNetworkState(connected: nil, updatedAt: nil, error: nil, now: now)
        XCTAssertEqual(loading.title, "正在读取设备")
        XCTAssertFalse(loading.needsAttention)
    }

    func testFreshDisconnectedStateRequiresAttention() {
        let state = OverviewNetworkState(connected: false, updatedAt: now, error: nil, now: now)
        XCTAssertEqual(state.title, "蜂窝未联网")
        XCTAssertTrue(state.needsAttention)
    }

    func testLoadingNeverUsesConnectedSubtitle() {
        for connected: Bool? in [nil, true, false] {
            let state = OverviewNetworkState(connected: connected, updatedAt: nil, error: nil, now: now)
            XCTAssertFalse(state.isConnected)
            XCTAssertEqual(state.subtitle(cellular: "中国移动 · 5G"), "正在读取设备")
        }
    }

    func testOnlyFreshExplicitConnectionUsesCellularSubtitle() {
        let fresh = OverviewNetworkState(connected: true, updatedAt: now, error: nil, now: now)
        XCTAssertTrue(fresh.isConnected)
        XCTAssertEqual(fresh.subtitle(cellular: "中国移动 · 5G"), "中国移动 · 5G · 蜂窝已联网")
        let stale = OverviewNetworkState(connected: true, updatedAt: now.addingTimeInterval(-20), error: nil, now: now)
        XCTAssertFalse(stale.isConnected)
        XCTAssertEqual(stale.subtitle(cellular: "中国移动 · 5G"), "设备状态待刷新")
        let failed = OverviewNetworkState(connected: true, updatedAt: now, error: "超时", now: now)
        XCTAssertFalse(failed.isConnected)
        XCTAssertEqual(failed.subtitle(cellular: "中国移动 · 5G"), "设备连接待恢复")
    }

    func testSignalBarsDistinguishMissingAndWeakSignal() {
        XCTAssertNil(OverviewGauge.signalLevel(rsrp: nil))
        XCTAssertNil(OverviewGauge.signalLevel(rsrp: .nan))
        XCTAssertEqual(OverviewGauge.signalLevel(rsrp: -120), 1)
        XCTAssertEqual(OverviewGauge.signalLevel(rsrp: -115), 2)
        XCTAssertEqual(OverviewGauge.signalLevel(rsrp: -105), 3)
        XCTAssertEqual(OverviewGauge.signalLevel(rsrp: -90), 4)
    }

}
