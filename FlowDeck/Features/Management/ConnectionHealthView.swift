import SwiftUI

/// 分开展示代理与设备管理通道；旧快照保留供参考，但标明时间，避免看起来仍在实时刷新。
struct ConnectionHealthView: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(DeviceStatusStore.self) private var status
    @Environment(PolicyStore.self) private var policy
    @Environment(AppRouter.self) private var router
    var body: some View {
        @Bindable var devices = devices
        if !devices.demoMode {
            if let error = status.snapshotError {
                GlassSection("设备管理未连接") {
                    Text(error).font(.footnote.weight(.medium)).foregroundStyle(.orange)
                    Text("请确认已连接 U60 Wi-Fi，并在系统设置中允许本地网络访问。密码或设备变化后需要重新配对。")
                        .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                    HStack {
                        Button("重新连接") {
                            Task {
                                await status.refreshSnapshot()
                            }
                        }
                        Button("设备配对") {
                            router.sheet = .pairing
                        }
                        Button("系统设置") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                }
            }
            if let updated = status.snapshotAt {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    if context.date.timeIntervalSince(updated) > 15 {
                        Label("显示上次成功读取的数据 · \(updated.formatted(date: .omitted, time: .standard))", systemImage: "clock.badge.exclamationmark")
                            .font(.caption.weight(.medium)).foregroundStyle(.orange)
                    }
                }
            }
            if devices.readOnly {
                Label("只读模式：可查看与诊断，设备写入已锁定", systemImage: "lock.shield")
                    .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            }
        }
    }
}
