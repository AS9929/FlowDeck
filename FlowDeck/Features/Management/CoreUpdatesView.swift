import SwiftUI

/// 当前版本与备份状态先从设备读取，远端版本检查仍由用户发起。
struct CoreUpdatesView: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(ManagementStore.self) private var manager
    @Environment(PolicyStore.self) private var policy
    @State private var action: String?
    @State private var currentVersion: String?
    @State private var backupAvailable: Bool?
    @State private var loadError: String?
    @State private var loading = false

    var body: some View {
        DetailSheet(title: "Mihomo 核心更新") {
            DeviceDetailSummary(symbol: "shippingbox", title: "保持代理核心可用", subtitle: "检查 Mihomo 版本，保留旧核心后安装更新；出现问题时可恢复。")
            DeviceVerificationSection()
            GlassSection("Mihomo · 代理核心") {
                Text("负责节点连接与流量分流。更新会短暂中断代理，设备会先保存旧核心。")
                    .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text("已安装").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Text(manager.versions?.current ?? currentVersion ?? policy.coreVersion ?? "读取中…")
                        .font(.title2.weight(.semibold)).textSelection(.enabled)
                }
                Divider()
                if let versions = manager.versions {
                    LabeledContent("可用版本", value: versions.latest)
                    Label(
                        versions.available ? "发现可用更新" : "当前已是最新版本",
                        systemImage: versions.available ? "arrow.down.circle" : "checkmark.circle"
                    )
                    .font(.subheadline.weight(.medium))
                }
                Button {
                    Task { await manager.checkUpdates(devices) }
                } label: {
                    Label(manager.versions == nil ? "检查可用更新" : "重新检查", systemImage: "arrow.clockwise")
                }
                if manager.versions?.available == true {
                    Button {
                        action = "更新"
                    } label: {
                        Label("备份并安装更新", systemImage: "arrow.down.circle")
                    }.disabled(!canWrite)
                }
            }.disabled(manager.working)
            GlassSection("出现问题时") {
                VStack(alignment: .leading, spacing: 18) {
                    Text(backupAvailable.map { $0 ? "已找到上次更新前的核心备份。" : "尚无旧核心备份，成功备份并更新后才可恢复。" } ?? "正在检查旧核心备份…")
                        .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                    Button {
                        action = "回滚"
                    } label: {
                        Label("恢复上一个核心", systemImage: "arrow.uturn.backward")
                    }.disabled(backupAvailable != true || !canWrite)
                    Button {
                        Task { await loadCurrent() }
                    } label: {
                        Label("重新读取设备状态", systemImage: "wifi.router")
                    }.disabled(loading)
                }
            }.disabled(manager.working)
            if let loadError { Text(loadError).font(.footnote.weight(.medium)).foregroundStyle(.orange) }
            if ["检查 Mihomo 核心版本", "备份并更新核心", "回滚核心"].contains(manager.operationTitle) {
                ManagementProgress()
            }
        }
        .task(id: devices.clientRevision) { await loadCurrent() }
        .confirmationDialog(action ?? "确认操作", isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } }), titleVisibility: .visible) {
            if let action {
                Button("确认\(action)") {
                    Task {
                        await manager.updateCore(devices, rollback: action == "回滚")
                        await loadCurrent()
                    }
                }
            }
        } message: {
            Text("此操作可能短暂断开连接。请保持设备供电，完成后 App 会重新读取状态。")
        }
    }

    private var canWrite: Bool {
        !devices.readOnly && (devices.demoMode || devices.current?.needsVerification == false)
    }

    private func loadCurrent() async {
        guard !loading else { return }
        loading = true
        let revision = devices.clientRevision
        let api = devices.webClient
        defer { loading = false }
        let version = try? await devices.client.version().version
        guard revision == devices.clientRevision, !Task.isCancelled else { return }
        currentVersion = version
        do {
            let available: Bool
            if devices.demoMode {
                available = false
            } else {
                let directory = try await api.coreDirectory()
                let output = try await api.runMaintenanceScript(
                    "cd " + ShellValue.quote(directory)
                        + " && if test -x mihomo.u60-before-update && test -f config.u60-before-update.yaml && test -f mihomo.u60-before-update.sha256; then echo available; else echo missing; fi"
                )
                available = output.trimmingCharacters(in: .whitespacesAndNewlines) == "available"
            }
            guard revision == devices.clientRevision, !Task.isCancelled else { return }
            backupAvailable = available
            loadError = nil
        } catch {
            guard revision == devices.clientRevision, !Task.isCancelled else { return }
            backupAvailable = nil
            loadError = "未能读取备份状态：" + error.localizedDescription
        }
    }
}
