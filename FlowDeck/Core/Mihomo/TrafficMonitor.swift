import Foundation
import Observation

/// 订阅 Mihomo 的 /traffic 流（每秒一条），统计的是经过代理核心的流量。
@MainActor
@Observable
final class TrafficMonitor {
    private(set) var up = 0
    private(set) var down = 0
    private(set) var history: [Double] = []
    private(set) var updatedAt: Date?
    private(set) var connected = false
    private var generation = 0

    /// 新设备和断流必须清除旧速率；旧订阅的取消回调不能覆盖新订阅。
    func run(_ api: any MihomoAPI) async {
        generation += 1
        let revision = generation
        history = []
        updatedAt = nil
        invalidate()
        while !Task.isCancelled, revision == generation {
            do {
                for try await sample in api.traffic() {
                    guard !Task.isCancelled, revision == generation else { return }
                    accept(sample)
                }
            } catch {
                // 保留最近采样时间，供界面区分断流和真实零流量。
            }
            guard revision == generation else { return }
            invalidate()
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
        }
    }

    func accept(_ sample: TrafficSample, at date: Date = Date()) {
        up = sample.up
        down = sample.down
        connected = true
        updatedAt = date
        history.append(Double(sample.down))
        if history.count > 40 { history.removeFirst(history.count - 40) }
    }

    func invalidate() {
        connected = false
        up = 0
        down = 0
    }

    var hasFreshSample: Bool { connected && updatedAt.map { Date().timeIntervalSince($0) < 5 } == true }
    var downText: String { hasFreshSample ? Self.split(down).0 : "—" }
    var downUnit: String { hasFreshSample ? Self.split(down).1 : "" }
    var upText: String { hasFreshSample ? Self.split(up).0 : "—" }
    var upUnit: String { hasFreshSample ? Self.split(up).1 : "" }

    func caption(at date: Date) -> String {
        guard let updatedAt else { return "等待实时采样 · 下行曲线保留最近 40 个采样点" }
        if !connected || date.timeIntervalSince(updatedAt) >= 5 {
            return "流量连接中断，正在重连 · 最后采样 " + updatedAt.formatted(date: .omitted, time: .standard)
        }
        return "下行曲线 · 最近 \(history.count) 秒 · 每秒采样"
    }

    nonisolated static func split(_ bytesPerSecond: Int) -> (String, String) {
        let v = Double(bytesPerSecond)
        if v >= 1_048_576 { return (String(format: "%.1f", v / 1_048_576), "MB/s") }
        if v >= 1024 { return (String(format: "%.0f", v / 1024), "KB/s") }
        return ("\(bytesPerSecond)", "B/s")
    }
}
