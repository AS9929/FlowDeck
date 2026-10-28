import XCTest

@testable import FlowDeck

/// 两种生产适配器共享的失败契约。所有请求由 URLProtocol 截获，不访问或修改真实设备。
/// 新后端登记后必须加入 fixture，不能因没有测试实例而静默跳过。
final class BackendContractTests: XCTestCase {
    override func tearDown() {
        ContractURLProtocol.failure = nil
        super.tearDown()
    }

    private func client(for backend: ManagementBackend) throws -> any WebSSHAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContractURLProtocol.self]
        let url = URL(string: "http://contract.fixture:8899")!
        switch backend {
        case .webSSH:
            return WebSSHClient(baseURL: url, username: "fixture", password: "fixture", configuration: configuration)
        case .ufiTools:
            return UFIClient(baseURL: url, password: "fixture", configuration: configuration)
        default:
            XCTFail("Register a contract fixture for \(backend.rawValue)")
            throw ManagementError.unsupported("Missing contract fixture")
        }
    }

    func testEveryRegisteredBackendRejectsMalformedResponse() async throws {
        for descriptor in BackendRegistry.descriptors {
            let adapter = try client(for: descriptor.id)
            do {
                _ = try await adapter.snapshot()
                XCTFail("\(descriptor.id) accepted malformed transport data")
            } catch {
                XCTAssertFalse(error is CancellationError)
            }
        }
    }

    func testEveryRegisteredBackendPreservesTimeoutAndCancellation() async throws {
        for code in [URLError.timedOut, .cancelled] {
            ContractURLProtocol.failure = code
            for descriptor in BackendRegistry.descriptors {
                let adapter = try client(for: descriptor.id)
                do {
                    _ = try await adapter.snapshot()
                    XCTFail("\(descriptor.id) converted transport failure into success")
                } catch {
                    if code == .cancelled {
                        XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
                    } else if descriptor.id == .webSSH {
                        guard case .unreachable = error as? WebSSHError else {
                            return XCTFail("WebSSH must retain its connection-failure classification")
                        }
                    } else {
                        XCTAssertEqual((error as? URLError)?.code, code, descriptor.id.rawValue)
                    }
                }
            }
        }
    }

    func testRegisteredBackendsRejectInvalidEndpointAndWrongDevice() throws {
        let f50 = try UFIClient.snapshot(from: "model=F50\nserial=TESTF500001\nfirmware=F50_FLYMODEM_ZYV1.0.0B09")
        for descriptor in BackendRegistry.descriptors {
            var profile = DeviceProfile(name: "fixture")
            profile.backend = descriptor.id
            profile.host = "invalid/host"
            XCTAssertNil(descriptor.makeClient(profile, "fixture", "fixture"))
            if descriptor.id == .webSSH {
                XCTAssertFalse(descriptor.accepts(f50))
                XCTAssertFalse(descriptor.features.contains(.ufiFactory))
            } else if descriptor.id == .ufiTools {
                XCTAssertTrue(descriptor.accepts(f50))
                XCTAssertFalse(descriptor.features.contains(.webTerminal))
            }
        }
        XCTAssertEqual(Set(BackendRegistry.supportedIDs).count, BackendRegistry.descriptors.count)
    }
}

private final class ContractURLProtocol: URLProtocol {
    static var failure: URLError.Code?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let code = Self.failure {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("not-json".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
