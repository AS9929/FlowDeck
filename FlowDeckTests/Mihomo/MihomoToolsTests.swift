import Foundation
import XCTest

@testable import FlowDeck

/// 新增控制接口的契约测试，使用内存 URLProtocol，不接触真实设备。
final class MihomoToolsTests: XCTestCase {
    override func tearDown() {
        ToolsURLProtocol.handler = nil
        super.tearDown()
    }

    private func client() -> MihomoClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ToolsURLProtocol.self]
        return MihomoClient(baseURL: URL(string: "http://test.invalid:9090")!, secret: "test-only", session: URLSession(configuration: config))
    }

    func testRuntimePatchSendsOnlyRequestedFieldAndReadback() async throws {
        ToolsURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only")
            XCTAssertEqual(request.url?.path, "/configs")
            if request.httpMethod == "PATCH" {
                let payload = try JSONSerialization.jsonObject(with: Self.body(request)) as! [String: Bool]
                XCTAssertEqual(payload, ["sniffing": false])
                return (204, Data())
            }
            return (200, Data(#"{"sniffing":false,"ipv6":true,"log-level":"warning"}"#.utf8))
        }
        let api = client()
        try await api.patchRuntime(.sniffing(false))
        let actual = try await api.runtimeSettings()
        XCTAssertTrue(RuntimeChange.sniffing(false).matches(actual))
        XCTAssertFalse(RuntimeChange.sniffing(true).matches(actual))
        XCTAssertNil(actual.bool("tcp-concurrent"))
    }

    func testUnknownRuntimeValueIsNotSilentlyAccepted() throws {
        XCTAssertThrowsError(try RuntimeChange.logLevel("arbitrary").payload())
        XCTAssertFalse(RuntimeChange.ipv6(false).matches(JSONObject()))
    }

    func testProviderParsingSeparatesKindsAndStaticSources() {
        let object = JSONObject([
            "providers": [
                "static": ["vehicleType": "Compatible", "proxies": [["name": "node"]]],
                "remote": ["vehicleType": "HTTP", "proxies": [["name": "a"], ["name": "b"]], "updatedAt": "2026-10-04T00:00:00Z"],
            ]
        ])
        let providers = MihomoProvider.parse(object, kind: .proxies)
        XCTAssertEqual(providers.count, 2)
        XCTAssertEqual(providers.first { $0.name == "remote" }?.count, 2)
        XCTAssertEqual(providers.first { $0.name == "static" }?.canUpdate, false)
        let rules = MihomoProvider.parse(JSONObject(["providers": ["rules": ["vehicleType": "File", "ruleCount": 123]]]), kind: .rules)
        XCTAssertEqual(rules.first?.count, 123)
        XCTAssertEqual(rules.first?.id, "rules:rules")
    }

    func testProviderPathEncodesNamesAsOneSegment() async throws {
        ToolsURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            let path = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.percentEncodedPath
            XCTAssertEqual(path, "/providers/proxies/JP%2FHK%20%23main")
            return (204, Data())
        }
        try await client().updateProvider("JP/HK #main", kind: .proxies)
    }

    func testDNSUsesDeviceEndpointAndPreservesFailureResponse() async throws {
        ToolsURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/dns/query")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "name" }?.value, "missing.example")
            XCTAssertEqual(query.first { $0.name == "type" }?.value, "AAAA")
            return (200, Data(#"{"Status":3,"Answer":[]}"#.utf8))
        }
        let result = try await client().queryDNS("missing.example", type: "AAAA")
        XCTAssertEqual(result.int("Status"), 3)
        XCTAssertTrue(result.array("Answer").isEmpty)
    }

    func testRuntimeAuthenticationFailureRemainsAnError() async throws {
        ToolsURLProtocol.handler = { _ in (401, Data()) }
        do {
            _ = try await client().runtimeSettings()
            XCTFail("401 不应变成默认配置")
        } catch {
            XCTAssertEqual(error as? MihomoError, .unauthorized)
        }
    }

    /// 失败不能被上层批量入口覆盖成成功提示。
    @MainActor
    func testDelayFailureKeepsFailureNoticeAndClearsBusy() async {
        ToolsURLProtocol.handler = { request in
            switch request.url?.path {
            case "/proxies":
                return (200, Data(#"{"proxies":{"节点选择":{"name":"节点选择","type":"Selector","all":["节点 A"],"now":"节点 A"}}}"#.utf8))
            case "/configs":
                return (200, Data(#"{"mode":"rule"}"#.utf8))
            case "/version":
                return (200, Data(#"{"version":"fixture"}"#.utf8))
            default:
                return (503, Data())
            }
        }
        let store = PolicyStore(api: client())
        store.authorizeWrite = {}
        await store.refresh()
        await store.testAll()
        XCTAssertTrue(store.notice?.contains("失败") == true)
        XCTAssertFalse(store.notice?.contains("完成") == true)
        XCTAssertTrue(store.testing.isEmpty)
        XCTAssertTrue(store.testedAt.isEmpty)
    }

    func testCacheFlushUsesPostAndAcceptsEmpty204() async throws {
        ToolsURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(["/cache/dns/flush", "/cache/fakeip/flush"].contains(request.url!.path))
            return (204, Data())
        }
        for kind in ProxyCacheKind.allCases { try await client().flushCache(kind) }
    }

    func testProviderHealthCheckEncodesNameAndUsesGet() async throws {
        ToolsURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.timeoutInterval, 60)
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath, "/providers/proxies/JP%2FHK/healthcheck")
            return (204, Data())
        }
        try await client().healthCheckProvider("JP/HK")
    }

    func testUnavailableCacheEndpointStaysAnError() async throws {
        ToolsURLProtocol.handler = { _ in (404, Data()) }
        do {
            try await client().flushCache(.dns)
            XCTFail("不支持的接口不能伪造成功")
        } catch MihomoError.http(let code, _) {
            XCTAssertEqual(code, 404)
        }
    }

    func testProviderQuotaOptionalAndZeroDoesNotMeanUnlimited() {
        let missing = MihomoProvider.parse(JSONObject(["providers": ["node": ["vehicleType": "HTTP"]]]), kind: .proxies)
        XCTAssertNil(missing.first?.quota)
        let quota = SubscriptionQuota(JSONObject(["Upload": 20, "Download": 30, "Total": 100, "Expire": 0]))
        XCTAssertEqual(quota.used, 50)
        XCTAssertEqual(quota.total, 100)
        XCTAssertNil(quota.expiry)
    }

    private static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            body.append(buffer, count: count)
        }
        return body
    }
}

/// 此测试类串行运行；每例独立配置会话，结束时移除 handler。
private final class ToolsURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
