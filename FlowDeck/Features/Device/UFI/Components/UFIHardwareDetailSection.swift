import SwiftUI

/// 硬件统计展示，与页面加载和设备写入状态解耦。
struct UFIHardwareDetailSection: View {
    let hardware: UFIHardwareDetails?
    let onUSB: () -> Void
    @ViewBuilder var body: some View {
        if let hardware {
            GlassSection("运行资源") {
                DeviceParameterRow(title: "UFI-TOOLS", value: hardware.version)
                DeviceParameterRow(title: "CPU 温度", value: hardware.cpuTemperature.map { "\(Int($0)) °C" })
                DeviceParameterRow(title: "CPU 使用率", value: hardware.cpuUsage.map { "\(Int($0))%" })
                DeviceParameterRow(title: "内存使用率", value: hardware.memoryUsage.map { "\(Int($0))%" })
                DeviceParameterRow(title: "存储可用", value: bytes(hardware.availableStorage))
                DeviceParameterRow(title: "存储总量", value: bytes(hardware.totalStorage))
            }
            GlassSection("蜂窝用量") {
                DeviceParameterRow(title: "今日", value: bytes(hardware.dailyBytes))
                DeviceParameterRow(title: "本月", value: bytes(hardware.monthlyBytes))
                Text("UFI-TOOLS 的 Android 蜂窝统计，与 Mihomo 代理流量统计口径不同。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            GlassSection("USB") {
                Button {
                    onUSB()
                } label: {
                    SettingsRow("USB 网络模式", symbol: "cable.connector", subtitle: "自动、RNDIS 与 CDC-ECM")
                }
                DeviceParameterRow(title: "接口速率", value: hardware.usbSpeedMbps.map { "\($0) Mbps" })
                Text("接口速率不是实际网速。F50 通过外部 USB 供电，当前不提供 U60 的电池与直供电开关。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func bytes(_ value: Int64?) -> String? {
        value.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .binary) }
    }
}
