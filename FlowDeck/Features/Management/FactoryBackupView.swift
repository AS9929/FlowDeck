import SwiftUI

/// 先完成连接设置，再生成并导出原厂设置；不把旧失败当成当前页的初始状态。
struct FactoryBackupView: View {
    @State private var editingConnection = false
    @Environment(DeviceStore.self) private var devices
    @Environment(ManagementStore.self) private var manager

    private var ready: Bool {
        devices.demoMode
            || (devices.current?.needsVerification == false
                && devices.current.map { !devices.factoryPassword(for: $0).isEmpty } == true)
    }

    var body: some View {
        DetailSheet(title: "原厂设置备份") {
            GlassSection("备份内容") {
                Label(devices.current?.name ?? "演示设备", systemImage: "wifi.router")
                Text("保存 Wi-Fi、APN 等原厂设置，用于后续恢复。代理节点与 Mihomo 配置请在“Mihomo → 配置”中管理。")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            }
            DeviceVerificationSection(requiresFactoryPassword: true)
            if ready {
                GlassSection("生成与保存") {
                    Button {
                        Task { await manager.backup(devices) }
                    } label: {
                        Label(manager.backupURL == nil ? "生成备份" : "重新生成备份", systemImage: "externaldrive.badge.plus")
                    }
                    .disabled(manager.working || devices.readOnly)
                    if let url = manager.backupURL {
                        ShareLink(item: url) { Label("保存到文件或分享", systemImage: "square.and.arrow.up") }
                    }
                    if let checksum = manager.backupChecksum {
                        DisclosureGroup("文件校验信息") {
                            Text("SHA256").font(.caption.weight(.medium))
                            Text(checksum).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                } footer: {
                    Text("生成后需点击保存。备份包含设备设置与凭据，请存放在受保护的位置。")
                }
            }
            if ready && !devices.demoMode {
                Button {
                    editingConnection = true
                } label: {
                    Label("连接与凭据", systemImage: "key")
                }.disabled(manager.working)
            }
            if devices.readOnly { Text("只读模式已开启，请在 App 设置中关闭后生成备份。").font(.footnote.weight(.medium)) }
            if manager.operationTitle == "生成原厂设置备份" { ManagementProgress() }
        }
        .appModal(isPresented: $editingConnection) { PairingView(device: devices.current) }
    }
}
