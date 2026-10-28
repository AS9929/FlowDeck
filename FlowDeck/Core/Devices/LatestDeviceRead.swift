import Foundation

/// 主线程上的读取顺序边界。新请求覆盖旧请求的发布权；取消与换设备均不发布结果。
/// 后台轮询可通过 isReading 跳过重叠采样，用户主动刷新仍可发起更新的请求。
@MainActor
final class LatestDeviceRead<Value> {
    private var latest = UUID()
    private var pending: Set<UUID> = []
    var isReading: Bool { !pending.isEmpty }

    func invalidate() {
        latest = UUID()
        pending.removeAll()
    }

    func read(_ operation: () async throws -> Value) async -> Result<Value, Error>? {
        guard !Task.isCancelled else { return nil }
        let request = UUID()
        latest = request
        pending.insert(request)
        defer { pending.remove(request) }
        let result: Result<Value, Error>
        do {
            result = .success(try await operation())
        } catch is CancellationError {
            return nil
        } catch let error as URLError where error.code == .cancelled {
            return nil
        } catch {
            result = .failure(error)
        }
        guard latest == request, !Task.isCancelled else { return nil }
        return result
    }
}
