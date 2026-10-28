import QuartzCore
import UIKit

/// 让新插入的折叠内容先以零高度提交一帧，避免 Task.yield 在同一帧合并两次状态修改。
/// 仅等待挂载边界，不逐帧更新 SwiftUI；取消任务时立即释放 display link。
@MainActor
final class DisplayFrameBoundary: NSObject {
    private var link: CADisplayLink?
    private var continuation: CheckedContinuation<Void, Never>?
    private var remainingFrames = 2
    private var finished = false

    static func wait() async {
        let boundary = DisplayFrameBoundary()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                boundary.start(continuation)
            }
        } onCancel: {
            Task { @MainActor in boundary.finish() }
        }
    }

    private func start(_ continuation: CheckedContinuation<Void, Never>) {
        guard !finished, !Task.isCancelled else {
            continuation.resume()
            return
        }
        self.continuation = continuation
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick() {
        remainingFrames -= 1
        if remainingFrames == 0 { finish() }
    }

    private func finish() {
        finished = true
        link?.invalidate()
        link = nil
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}
