import XCTest

@testable import FlowDeck

/// 请求先后顺序由 continuation 控制，不依赖网络或睡眠时长；验证取消和旧响应不发布。
@MainActor
final class StateConsistencyTests: XCTestCase {
    func testUnitTestHostUsesExplicitIsolatedDemo() {
        let defaults = UserDefaults(suiteName: "com.max.U60Manager.unit-test-host")!
        XCTAssertTrue(defaults.bool(forKey: "demoMode"))
        XCTAssertTrue(defaults.bool(forKey: "demo.explicitSelection.v1"))
        XCTAssertNil(defaults.data(forKey: "devices.v1"))
    }

    func testOlderSuccessCannotReplaceNewerSuccess() async throws {
        let reads = LatestDeviceRead<Int>()
        let response = ControlledResponse<Int>()
        let old = Task { await reads.read { try await response.wait() } }
        await response.started()
        XCTAssertTrue(reads.isReading)
        let newest = await reads.read { 2 }
        XCTAssertEqual(try newest?.get(), 2)
        response.finish(.success(1))
        let discarded = await old.value
        XCTAssertNil(discarded)
        XCTAssertFalse(reads.isReading)
    }

    func testOlderFailureCannotEraseNewerSuccess() async throws {
        let reads = LatestDeviceRead<Int>()
        let response = ControlledResponse<Int>()
        let old = Task { await reads.read { try await response.wait() } }
        await response.started()
        let newest = await reads.read { 3 }
        XCTAssertEqual(try newest?.get(), 3)
        response.finish(.failure(URLError(.timedOut)))
        let discarded = await old.value
        XCTAssertNil(discarded)
    }

    func testCancellationDiscardsEvenTransportThatReturnsSuccess() async {
        let reads = LatestDeviceRead<Int>()
        let response = ControlledResponse<Int>()
        let request = Task { await reads.read { try await response.wait() } }
        await response.started()
        request.cancel()
        response.finish(.success(1))
        let discarded = await request.value
        XCTAssertNil(discarded)
        let cancelled = await reads.read { throw URLError(.cancelled) }
        XCTAssertNil(cancelled)
    }

    func testChangingDeviceInvalidatesInFlightResponse() async {
        let reads = LatestDeviceRead<Int>()
        let response = ControlledResponse<Int>()
        let request = Task { await reads.read { try await response.wait() } }
        await response.started()
        reads.invalidate()
        XCTAssertFalse(reads.isReading)
        response.finish(.success(1))
        let discarded = await request.value
        XCTAssertNil(discarded)
    }

    func testCurrentTransportFailureRemainsVisible() async {
        let reads = LatestDeviceRead<Int>()
        let result = await reads.read { throw URLError(.timedOut) }
        guard case .failure(let error) = result else {
            return XCTFail("Timeout must not become an empty or successful response")
        }
        XCTAssertEqual((error as? URLError)?.code, .timedOut)
    }
}

/// 单次读取的可控替身。started 同步确认请求已进入，finish 可模拟乱序、取消和失败。
@MainActor
private final class ControlledResponse<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var startWaiter: CheckedContinuation<Void, Never>?

    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            startWaiter?.resume()
            startWaiter = nil
        }
    }

    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func finish(_ result: Result<Value, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
