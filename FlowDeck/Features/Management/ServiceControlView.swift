import SwiftUI

/// 代理服务启停与自启的交互入口，执行前由管理协调器核验目标。
struct ServiceControlView: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(DeviceStatusStore.self) private var status
    @Environment(ManagementStore.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @State private var disableAutostart = false
    @State private var confirmStop = false
    @State private var confirmRestart = false
    var body: some View {
        DetailSheet(title: "代理服务") {
            if devices.usesUFI {
                UFIServiceSummary()
            } else {
                DeviceDetailSummary(
                    symbol: "power",
                    title: status.service.map { $0.running ? "代理运行中" : "代理已停止" } ?? "正在读取状态",
                    subtitle: "运行状态与出口可达性分别检查。启停会影响连接到此设备的客户端。"
                )
            }
            ManagementProgress()
            GlassSection("服务控制") {
                if devices.usesUFI, let service = status.service {
                    Toggle(
                        "开机自动启动",
                        isOn: Binding(
                            get: { service.autostart },
                            set: { enabled in Task { await status.setAutostart(enabled) } })
                    )
                    .disabled(devices.readOnly)
                }
                if let error = status.serviceError {
                    Text(error).foregroundStyle(.orange)
                }
                if status.service?.running == true {
                    Toggle("停用时关闭自启", isOn: $disableAutostart)
                    Button("停用代理", systemImage: "stop.circle", role: .destructive) {
                        confirmStop = true
                    }
                } else {
                    Button("检查并启动代理", systemImage: "play.circle") {
                        control(.start)
                    }
                }
                Button("重启代理", systemImage: "arrow.clockwise") {
                    confirmRestart = true
                }
                if let busy = status.busy {
                    ProgressView(busy)
                }
                if let notice = status.notice {
                    Text(notice).font(.footnote.weight(.medium))
                }
            }.disabled(manager.working || status.busy != nil || devices.readOnly)
            if devices.readOnly {
                Text("只读模式已开启，服务控制暂不可用。")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("重启将短暂中断所有客户端的代理连接", isPresented: $confirmRestart, titleVisibility: .visible) {
            Button("确认重启") { control(.restart) }
        }
        .task {
            await status.refreshService()
        }
        .confirmationDialog("停用后所有接入设备将直接连接蜂窝网络", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("确认停用", role: .destructive) {
                control(.stop)
            }
        }
    }

    private func control(_ action: ProxyAction) {
        Task {
            await manager.controlProxyService(action, status: status, devices: devices, disableAutostart: disableAutostart)
        }
    }
}
