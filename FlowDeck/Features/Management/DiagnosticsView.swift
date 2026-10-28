import SwiftUI

/// 网络诊断报告、重测和校时入口；执行流程由管理协调器持有。
struct DiagnosticsView: View {
    @State private var confirmClockSync = false
    @Environment(DeviceStore.self) private var devices
    @Environment(ManagementStore.self) private var manager
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        DetailSheet(title: "网络诊断") {
            DeviceDetailSummary(
                symbol: "stethoscope",
                title: manager.working ? "正在检查网络链路" : "定位连接问题",
                subtitle: "逐项检查管理通道、代理出口、DNS 和设备时间；无法验证的项目单独标明。"
            )
            ManagementProgress()
            if let report = manager.report {
                GlassSection(report.demo ? "演示诊断" : "检测结果") {
                    Text("\(report.checks.filter { $0.outcome == .passed }.count) 项通过")
                        .font(.title2.weight(.semibold))
                    Text("\(report.checks.filter { $0.outcome == .failed }.count) 项异常 · \(report.checks.filter { $0.outcome == .unavailable }.count) 项未检测")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    ForEach(report.checks) { check in
                        Divider().padding(.vertical, 4)
                        HStack(alignment: .top) {
                            Image(
                                systemName: check.outcome == .passed ? "checkmark.circle.fill" : check.outcome == .failed ? "xmark.circle.fill" : "minus.circle"
                            )
                            .font(.system(size: 22))
                            .foregroundStyle(check.outcome == .passed ? Color.green : check.outcome == .failed ? Color.orange : Color.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(check.title + (check.outcome == .unavailable ? " · 未检测" : ""))
                                Text(check.detail).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            GlassSection("设备校时") {
                Button("同步手机时间", systemImage: "clock.arrow.trianglehead.2.counterclockwise.rotate.90") {
                    confirmClockSync = true
                }
                .disabled(manager.working || devices.readOnly)
            } footer: {
                Text(devices.readOnly ? "当前为只读模式，关闭后可同步。" : "以手机当前时间校准设备，完成后回读验证。只更新系统时间，不改变时区；重启或设备自动校时后可能被覆盖。")
            }
            GlassSection {
                Button("重新检测", systemImage: "arrow.clockwise") {
                    Task {
                        await manager.diagnose(devices)
                    }
                }.disabled(manager.working)
                if let url = manager.exportURL {
                    ShareLink(item: url) { Label("导出诊断报告", systemImage: "square.and.arrow.up") }
                }
            } footer: {
                Text("未检测表示当前没有验证结果，不代表网络异常。导出包含检测结果及 UDP 出口地址，不含 IMEI、短信、节点配置、密码或 Secret。")
            }
        }
        .confirmationDialog("将设备时间同步为手机时间？", isPresented: $confirmClockSync, titleVisibility: .visible) {
            Button("同步手机时间") { Task { await manager.synchronizeClock(devices) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("时间跳变可能影响日志时间及现有连接。请确认手机已开启自动设置时间。")
        }
        .task {
            if manager.report == nil {
                await manager.diagnose(devices)
            }
        }
    }
}
