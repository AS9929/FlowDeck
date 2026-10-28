import SwiftUI

/// 把旧连接记录缺少身份验证、缺少原厂密码转换成可直接完成的前置步骤。
/// 验证只读取状态；保存仍由用户在连接表单中主动完成。
struct DeviceVerificationSection: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(ManagementStore.self) private var manager
    @State private var editing = false
    var requiresFactoryPassword = false

    private var missingIdentity: Bool { devices.current?.needsVerification != false }
    private var missingPassword: Bool {
        requiresFactoryPassword && devices.current.map { devices.factoryPassword(for: $0).isEmpty } != false
    }

    var body: some View {
        if !devices.demoMode && (missingIdentity || missingPassword) {
            GlassSection("完成连接设置") {
                Label(missingIdentity ? "设备已添加，身份待验证" : "需要原厂管理密码", systemImage: "checkmark.shield")
                Text(
                    missingIdentity
                        ? "已有设备无需重新添加。验证当前设备并保存后，即可继续操作。"
                        : "原厂备份使用网页管理密码，与 Mihomo Secret、WebSSH 密码不同。"
                )
                .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                Button {
                    editing = true
                } label: {
                    Label(missingIdentity ? "验证当前设备" : "补充原厂管理密码", systemImage: "arrow.right.circle")
                }
                .disabled(manager.working)
            }
            .appModal(isPresented: $editing) {
                PairingView(device: devices.current, isNew: devices.current == nil)
            }
        }
    }
}
