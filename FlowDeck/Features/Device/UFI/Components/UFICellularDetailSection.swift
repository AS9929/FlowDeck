import SwiftUI

/// SIM 与 APN 只展示已读取字段；需要写入的动作通过回调交回核验流程。
struct UFICellularDetailSection: View {
    let factory: JSONObject
    let busy: Bool
    let readOnly: Bool
    let onAdvanced: (UFIAdvancedSettingsView.Kind) -> Void
    let onRadio: () -> Void
    let onRoaming: (Bool) -> Void
    var body: some View {
        VStack(spacing: 20) {
            UFICellularSummary()
            GlassSection("蜂窝连接") {
                Button {
                    onAdvanced(.network)
                } label: {
                    SettingsRow("网络制式", symbol: "antenna.radiowaves.left.and.right", subtitle: "自动、5G SA / NSA、4G 与 3G")
                }
            }
            GlassSection {
                Button {
                    onRadio()
                } label: {
                    SettingsRow(
                        "频段与小区", symbol: "antenna.radiowaves.left.and.right",
                        subtitle: "4G / 5G 频段、锁定与恢复自动")
                }
            }
            GlassSection("SIM 安全") {
                DeviceParameterRow(title: "PIN 锁", value: mapped("pin_status", values: ["0": "关闭", "1": "开启"]))
                DeviceParameterRow(title: "PIN 剩余次数", value: factory.string("pinnumber"))
                DeviceParameterRow(title: "PUK 剩余次数", value: factory.string("puknumber"))
                Button {
                    onAdvanced(.pin)
                } label: {
                    SettingsRow("PIN 与 PUK 管理", symbol: "lock.shield", subtitle: "开关、修改与解锁")
                }
            }
            GlassSection("接入点与漫游") {
                DeviceParameterRow(title: "APN 模式", value: mapped("apn_mode", values: ["auto": "自动", "manual": "手动"]))
                DeviceParameterRow(title: "配置名称", value: factory.string("profile_name_ui"))
                DeviceParameterRow(title: "APN", value: factory.string("wan_apn_ui"))
                DeviceParameterRow(title: "IP 协议", value: factory.string("pdp_type_ui"))
                DeviceParameterRow(title: "连接方式", value: mapped("connectionMode", values: ["auto_dial": "自动连接", "manual_dial": "手动连接"]))
                DeviceParameterRow(title: "数据漫游", value: mapped("autoConnectWhenRoaming", values: ["on": "允许", "off": "关闭"]))
                if let roaming = factory.string("autoConnectWhenRoaming"), ["on", "off"].contains(roaming) {
                    Toggle(
                        "允许数据漫游",
                        isOn: Binding(
                            get: { roaming == "on" }, set: { onRoaming($0) })
                    )
                    .disabled(busy || readOnly)
                }
                Button {
                    onAdvanced(.apn)
                } label: {
                    SettingsRow("管理 APN", symbol: "network", subtitle: "添加、编辑、选择与恢复自动")
                }
            }
            Text("自动 APN 的部分参数由运营商下发，设备可能不会返回。")
                .font(.caption).foregroundStyle(.secondary)
            GlassSection("高级设置") { UFIWebLinks() }
        }
    }

    private func mapped(_ key: String, values: [String: String]) -> String? {
        guard let raw = factory.string(key), !raw.isEmpty else { return nil }
        return values[raw] ?? "未识别（\(raw)）"
    }

}
