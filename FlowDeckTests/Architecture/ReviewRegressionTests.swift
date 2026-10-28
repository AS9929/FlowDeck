import XCTest

@testable import FlowDeck

/// 评审修复的协议和状态边界回归。请求仅发往 URLProtocol 内存替身。
final class ReviewRegressionTests: XCTestCase {
    func testFileExecPreservesExitCodeAndBothOutputStreams() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReviewURLProtocol.self]
        let client = WebSSHClient(
            baseURL: URL(string: "http://fixture.test")!, username: "fixture", password: "fixture",
            configuration: configuration)
        let result = try await client.rpc("file", "exec", params: JSONObject())
        XCTAssertEqual(result.int("code"), 7)
        XCTAssertEqual(result.string("stdout"), "partial output")
        XCTAssertEqual(result.string("stderr"), "failure detail")
        do {
            _ = try await client.rpc("device", "write", params: JSONObject())
            XCTFail("普通 RPC 的失败码仍须拒绝")
        } catch {
            XCTAssertTrue(error is ManagementError)
        }
    }

    func testPublicBuildCannotLoadFirstInstallPayloads() {
        XCTAssertNil(Bundle.main.url(forResource: "BootstrapWebSSH", withExtension: "bin"))
        XCTAssertNil(Bundle.main.url(forResource: "OfflineDeploymentManifest", withExtension: "json"))
        XCTAssertThrowsError(try OfflineDeploymentResources.bundled())
        XCTAssertThrowsError(try FactoryBootstrap.binary())
    }

    @MainActor
    func testOperationGateRejectsOverlapAndIgnoresForeignRelease() throws {
        let lease = try DeviceOperationGate.begin("测试部署")
        defer { DeviceOperationGate.end(lease) }
        XCTAssertThrowsError(try DeviceOperationGate.begin("锁频"))
        DeviceOperationGate.end(UUID())
        XCTAssertEqual(DeviceOperationGate.active, lease)
        DeviceOperationGate.end(lease)
        let next = try DeviceOperationGate.begin("另一项操作")
        DeviceOperationGate.end(next)
        XCTAssertNil(DeviceOperationGate.active)
    }

    @MainActor
    func testNestedMaintenanceStepKeepsOuterOperationLocked() async throws {
        let outer = try DeviceOperationGate.begin("维护")
        defer { DeviceOperationGate.end(outer) }
        try DeviceOperationGate.$owner.withValue(outer) {
            let inner = try DeviceOperationGate.begin("配置写入")
            DeviceOperationGate.end(inner)
            XCTAssertEqual(DeviceOperationGate.active, outer)
        }
        XCTAssertThrowsError(try DeviceOperationGate.begin("另一页面"))
    }

    @MainActor
    func testDeepLinkCannotDiscardConfigurationDraft() {
        let router = AppRouter()
        router.tab = 1
        let navigationID = router.proxyNavigationID
        router.hasUnsavedConfiguration = true
        router.open(AppIdentity.url(for: "policy"))
        XCTAssertEqual(router.proxyNavigationID, navigationID)
        XCTAssertNotNil(router.navigationNotice)
        router.open(AppIdentity.url(for: "device"))
        XCTAssertEqual(router.tab, 1)
    }

    @MainActor
    func testUnverifiedStockPathIsBlockedBeforeNetwork() async {
        let defaults = UserDefaults(suiteName: "test.FlowDeck." + UUID().uuidString)!
        let devices = DeviceStore(defaults: defaults)
        devices.readOnly = false
        let store = DeploymentStore()
        store.simulation = false
        await store.prepareFactory(devices)
        XCTAssertTrue(store.error?.contains("电脑") == true)
        await store.applyFactory(devices)
        XCTAssertTrue(store.error?.contains("电脑") == true)
        XCTAssertNotEqual(store.phase, "factorySubmitted")
    }

    @MainActor
    func testDeviceWriteWithoutAuthorizationFailsClosed() async {
        let store = DeviceStatusStore(api: DemoWebSSH(), deviceID: UUID().uuidString)
        await store.setNetworkMode(.auto)
        XCTAssertTrue(store.notice?.contains("写入授权") == true)
    }

    func testBootstrapNTPDoesNotDependOnDNSOrProxy() throws {
        let config = try DeploymentConfiguration.make(
            source: "proxies: []\nrules: [MATCH,DIRECT]\n",
            host: "192.168.0.1", secret: String(repeating: "a", count: 48))
        XCTAssertTrue(config.contains("server: 203.107.6.88"))
        XCTAssertTrue(config.contains("dialer-proxy: DIRECT"))
        XCTAssertTrue(config.contains("write-to-system: false"))
    }
}

/// 固定应答避免静态 handler 在并行测试之间串扰。
private final class ReviewURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "fixture.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let body =
            request.url!.path.hasSuffix("/api/login")
            ? #"{"code":0,"token":"fixture-token"}"#
            : #"[{"id":1,"result":[0,{"code":7,"stdout":"partial output","stderr":"failure detail"}]}]"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
