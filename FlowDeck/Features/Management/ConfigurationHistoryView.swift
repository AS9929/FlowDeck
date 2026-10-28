import SwiftUI

/// 展示配置历史并明确恢复入口，实际应用沿用配置事务边界。
struct ConfigurationHistoryView: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(DeviceStatusStore.self) private var status
    @Environment(ManagementStore.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @State private var history: [ConfigRevision] = []
    @State private var selected: ConfigRevision?
    @State private var loadError: String?
    var body: some View {
        DetailSheet(title: "配置历史") {
            DeviceDetailSummary(symbol: "clock.arrow.circlepath", title: "保留可恢复的版本", subtitle: "每台设备保存最近 5 份不同配置。恢复前再次校验文件，并备份当前版本。")
            if manager.operationTitle == "保存配置历史" || manager.operationTitle == "恢复历史配置" { ManagementProgress() }
            if let loadError {
                Text(loadError).foregroundStyle(.orange)
            }
            GlassSection {
                Button("保存当前配置快照", systemImage: "plus.rectangle.on.folder") {
                    Task {
                        await manager.run("保存配置历史") {
                            let api = try await manager.verifiedAPI(devices)
                            try ConfigHistory.save(try await api.loadConfig(), deviceID: devices.storageID)
                            history = try ConfigHistory.list(deviceID: devices.storageID)
                        }
                    }
                }
                ForEach(history) { revision in
                    Divider().padding(.vertical, 4)
                    Button {
                        selected = revision
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(revision.sourceName ?? "设备配置快照").font(.subheadline.weight(.medium))
                            Text(revision.createdAt.formatted(date: .abbreviated, time: .standard)).font(.caption.weight(.medium))
                            Text(String(revision.checksum.prefix(16))).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                if history.isEmpty {
                    ContentUnavailableView("还没有历史快照", systemImage: "clock.arrow.circlepath", description: Text("保存当前配置后，可在这里查看并恢复。"))
                }
            }.disabled(manager.working)
            Text("快照仅保存在本机受保护目录。点击版本可恢复，操作将重启代理服务。")
                .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
        }
        .task {
            do {
                history = try ConfigHistory.list(deviceID: devices.storageID)
            } catch {
                loadError = error.localizedDescription
            }
        }
        .confirmationDialog("恢复所选配置并重启代理", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }), titleVisibility: .visible) {
            if let selected {
                Button("恢复配置") {
                    Task {
                        await manager.run("恢复历史配置") {
                            _ = try await manager.verifiedAPI(devices)
                            guard selected.deviceID == devices.storageID,
                                DeviceIdentity.digest(Data(selected.content.utf8)) == selected.checksum
                            else {
                                throw ManagementError.deviceChanged
                            }
                            var restoreFailure: String?
                            await status.importConfig(selected.content) { step in
                                switch step {
                                case .failed(let reason), .rolledBack(let reason): restoreFailure = reason
                                case .done: loadError = "历史配置已应用"
                                default: break
                                }
                            }
                            if let restoreFailure {
                                throw ManagementError.unconfirmed(restoreFailure)
                            }
                            history = try ConfigHistory.list(deviceID: devices.storageID)
                        }
                    }
                }
            }
        }
    }
}
