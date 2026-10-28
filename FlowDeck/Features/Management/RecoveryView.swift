import SwiftUI

/// 观察设备重启后的恢复状态，重新检查不重复发送重启命令。
struct RecoveryView: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(ManagementStore.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @State private var confirm = false
    var body: some View {
        DetailSheet(title: "设备重启与恢复") {
            DetailStatus(title: "重启与自动检查", subtitle: "设备重启后，跟踪蜂窝网络、代理核心与出口的恢复状态。", symbol: "arrow.clockwise")
            ManagementProgress()
            GlassSection {
                Button("重启设备", role: .destructive) {
                    confirm = true
                }.disabled(manager.working)
                if manager.recoveryPending {
                    Button("重新检查恢复状态") {
                        Task {
                            await manager.reboot(devices, sendCommand: false)
                        }
                    }.disabled(manager.working)
                    Button("结束本次跟踪") { manager.stopRecoveryTracking() }
                        .disabled(manager.working)
                }
            } footer: {
                Text("重启后重新连上设备 Wi-Fi，保持此 App 前台即可自动检查设备身份、蜂窝、核心和出口。后台锁屏显示最近阶段，恢复前台后继续检查。")
            }
        }
        .confirmationDialog("重启会让所有接入设备短暂断网", isPresented: $confirm, titleVisibility: .visible) {
            Button("确认重启", role: .destructive) {
                Task {
                    await manager.reboot(devices)
                }
            }
        }
    }
}
