import SwiftUI

/// WebSSH 服务拥有独立的连接与版本入口；浏览和检查版本不会触发更新或重启。
struct WebSSHManagementView: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(ManagementStore.self) private var manager
    @State private var editingConnection = false
    @State private var action: Action?

    private enum Action: String, Identifiable {
        case update = "更新 WebSSH"
        case restart = "重启 WebSSH"
        var id: String { rawValue }
    }

    var body: some View {
        DetailSheet(title: "WebSSH 管理服务") {
            DeviceDetailSummary(
                symbol: "server.rack", title: "设备管理通道",
                subtitle: "为 App 提供设备状态、原厂设置和命令执行能力。Mihomo 核心在 Mihomo → 配置中单独管理。")
            GlassSection("连接与认证") {
                if let profile = devices.current {
                    LabeledContent("当前设备", value: profile.name)
                    Text("\(profile.host):\(profile.webPort)")
                        .font(.subheadline.monospaced()).textSelection(.enabled)
                    Label(
                        profile.needsVerification ? "设备身份待验证" : "设备身份已绑定",
                        systemImage: profile.needsVerification ? "shield" : "checkmark.shield"
                    )
                    .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                    Text("身份绑定记录不代表当前在线；验证连接可重新确认服务与凭据。")
                        .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                } else {
                    Text(devices.demoMode ? "演示设备 · 使用示例数据" : "尚未保存设备，请先添加已部署的设备。")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                }
                if devices.current != nil || devices.demoMode {
                    Button {
                        editingConnection = true
                    } label: {
                        SettingsRow("连接与凭据", symbol: "key", subtitle: "编辑管理地址、端口并验证密码")
                    }
                }
            }
            GlassSection("服务版本") {
                Text(manager.webVersion == "尚未检查" ? "尚未检查版本" : manager.webVersion)
                    .font(.subheadline.weight(.medium)).textSelection(.enabled)
                Button {
                    Task { await manager.checkWebSSHVersion(devices) }
                } label: {
                    Label("检查 WebSSH 版本", systemImage: "arrow.clockwise")
                }
                .disabled(manager.working || !devices.webAvailable)
                Button {
                    action = .update
                } label: {
                    Label("检查并更新 WebSSH", systemImage: "arrow.down.circle")
                }
                .disabled(!canWrite || manager.working)
                Text("更新前会重新检查版本。下载由设备完成，需要设备能访问更新源。")
                    .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            }
            GlassSection("服务恢复") {
                Button {
                    action = .restart
                } label: {
                    Label("重启 WebSSH", systemImage: "arrow.clockwise")
                }
                .disabled(!canWrite || manager.working)
                Text("仅重启管理服务，App 会短暂失去管理连接，随后检查服务是否恢复。")
                    .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            }
            if ["检查 WebSSH 版本", "重启管理服务", "更新管理服务"].contains(manager.operationTitle) {
                ManagementProgress()
            }
        }
        .appModal(isPresented: $editingConnection) { PairingView() }
        .confirmationDialog(
            action?.rawValue ?? "管理服务",
            isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } }),
            titleVisibility: .visible
        ) {
            if let action {
                Button(action.rawValue) {
                    Task { await manager.manageWebSSH(devices, update: action == .update) }
                }
            }
        } message: {
            Text("请保持设备供电和 Wi-Fi 连接。操作过程中管理页面可能暂时无法读取数据。")
        }
    }

    private var canWrite: Bool {
        !devices.readOnly && (devices.demoMode || devices.current?.needsVerification == false)
    }
}
