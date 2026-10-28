import SwiftUI

/// 工具页按接入、排障、管理服务组织；代理核心和原厂设置分别归属 Mihomo 与设备。
struct MaintenanceView: View {
    @Environment(ManagementStore.self) private var manager
    @Environment(DeviceStore.self) private var devices
    @State private var destination: Destination?

    private enum Destination: String, Identifiable {
        case connection, command, history
        var id: String { rawValue }
    }

    var body: some View {
        GlassSheet {
            if let issue = devices.accessIssue(for: .webSSH) {
                DeviceAccessNotice(issue: issue)
            }
            GlassSection("设备接入") {
                entry("接入新设备", symbol: "plus.circle", subtitle: "连接已部署的 WebSSH 或 UFI-TOOLS", target: .connection)
            }
            if devices.usesUFI {
                GlassSection("诊断与排障") {
                    DestinationRow("网络诊断", symbol: "stethoscope", subtitle: "管理通道、蜂窝、Mihomo 与设备时间", destination: .diagnostics)
                    Divider()
                    DestinationRow("检查与重启", symbol: "arrow.clockwise", subtitle: "配置校验、重启与恢复检查", destination: .recovery)
                }
                GlassSection("连接与记录") {
                    DestinationRow("连接与凭据", symbol: "key", subtitle: "验证 UFI 与 Mihomo", destination: .pairing)
                    Divider()
                    entry("最近操作", symbol: "clock", subtitle: "本次会话的执行结果与失败记录", target: .history)
                }
                GlassSection("网页管理") {
                    UFIWebLinks()
                }
                Text("首次安装与固件操作请在电脑上完成。")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            } else {
                GlassSection("诊断与排障") {
                    DestinationRow("网络诊断", symbol: "stethoscope", subtitle: "检查链路、设备时间并导出结果", destination: .diagnostics)
                    entry("命令控制台", symbol: "terminal", subtitle: "单次执行命令、查看输出与退出码", target: .command)
                    entry("最近操作", symbol: "clock", subtitle: "本次会话的执行结果与失败记录", target: .history)
                }
                GlassSection("管理服务") {
                    DestinationRow("WebSSH", symbol: "server.rack", subtitle: "连接与凭据、服务版本、更新与重启", destination: .webSSH)
                }
            }
        }
        .nativeSettingsPage(title: "工具")
        .toolbar { DeviceContextToolbar() }
        .appPush(item: $destination) { target in
            switch target {
            case .connection: DeviceOnboardingView()
            case .command:
                DeviceAccessGate(requirement: .webSSH, title: "命令控制台") { DeviceCommandView() }
            case .history: operationHistory
            }
        }
    }

    private func entry(_ title: String, symbol: String, subtitle: String, target: Destination) -> some View {
        Button {
            destination = target
        } label: {
            SettingsRow(title, symbol: symbol, subtitle: subtitle)
        }
    }

    private var operationHistory: some View {
        DetailSheet(title: "最近操作") {
            if manager.working {
                ManagementProgress()
            }
            ForEach(manager.recentOperations) { record in
                GlassSection {
                    Label(record.title, systemImage: record.succeeded ? "checkmark.circle" : "exclamationmark.circle")
                    HStack {
                        Text(record.succeeded ? "已完成" : "未完成，需检查")
                        Spacer()
                        Text(record.date.formatted(date: .omitted, time: .standard))
                    }
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            if manager.recentOperations.isEmpty {
                ContentUnavailableView("暂无操作", systemImage: "clock", description: Text("记录当前设备、本次会话最近 20 次管理操作。"))
            }
        }
    }
}
