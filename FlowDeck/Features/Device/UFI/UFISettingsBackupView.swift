import SwiftUI
import UniformTypeIdentifiers

/// 导入仅解密预览；恢复分别进入既有编辑器，由各能力自己的确认、校验和回读流程提交。
struct UFISettingsBackupView: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(ManagementStore.self) private var manager
    @State private var factoryPassword = ""
    @State private var archivePassword = ""
    @State private var confirmation = ""
    @State private var loading = false
    @State private var revision = 0
    @State private var error: String?
    @State private var archive: UFISettingsArchive?
    @State private var exportURL: URL?
    @State private var importing = false
    @State private var restoringWifi: UFIWifiAccessPoint?
    @State private var restoringAPN: UFIAPNProfile?
    @State private var restoringConfig = false

    private var busy: Bool { loading || manager.working }

    var body: some View {
        DetailSheet(title: "设置备份", closeDisabled: busy) {
            DeviceDetailSummary(
                symbol: "externaldrive.badge.checkmark", title: "加密设置恢复包",
                subtitle: "一起保存双频 Wi-Fi、APN 与 Mihomo 配置，恢复时逐项检查。")
            if loading { ProgressView("正在处理恢复包…") }
            if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
            GlassSection("保护与保存") {
                SecureField("原厂网页登录密码", text: $factoryPassword).textContentType(.password)
                SecureField("备份密码（至少 12 字节）", text: $archivePassword).textContentType(.newPassword)
                SecureField("再次输入备份密码（生成时填写）", text: $confirmation)
                Button("生成加密恢复包", systemImage: "externaldrive.badge.plus") { Task { await generate() } }
                    .disabled(
                        busy || factoryPassword.isEmpty || archivePassword != confirmation
                            || archivePassword.utf8.count < 12)
                if let exportURL {
                    ShareLink(item: exportURL) { Label("保存恢复包", systemImage: "square.and.arrow.up") }
                }
                Button("打开已有恢复包", systemImage: "folder") { importing = true }
                    .disabled(busy || archivePassword.utf8.count < 12)
            }.disabled(busy)
            if let archive { contents(archive) }
            Text("包含 Wi-Fi、APN 与节点凭据，请将备份密码与文件分开保管。此包不包含固件、分区、原厂后台密码、短信或未适配设置；不是整机镜像。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .task(id: devices.clientRevision) {
            revision = devices.clientRevision
            loading = false
            archive = nil
            error = nil
            restoringWifi = nil
            restoringAPN = nil
            restoringConfig = false
            archivePassword = ""
            confirmation = ""
            removeExport()
            factoryPassword = devices.current.map { devices.factoryPassword(for: $0) } ?? ""
        }

        .appPush(item: $restoringWifi) { point in
            UFIWifiView(restoredPoint: point, restoredFingerprint: archive?.fingerprint)
        }
        .appPush(item: $restoringAPN) { profile in
            UFIAdvancedSettingsView(kind: .apn, restoredAPN: profile, restoredFingerprint: archive?.fingerprint)
        }
        .appModal(isPresented: $restoringConfig) {
            if let archive, archive.fingerprint == devices.current?.fingerprint {
                ConfigImportView(name: "F50 设置恢复包", content: archive.configuration)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            guard case .success(let url) = result else { return }
            Task { await open(url) }
        }
    }

    private func contents(_ archive: UFISettingsArchive) -> some View {
        GlassSection("恢复包内容") {
            Text(archive.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.subheadline)
            ForEach(archive.wifi) { point in
                Button {
                    restoringWifi = point
                } label: {
                    SettingsRow(point.title, symbol: "wifi", subtitle: "预览并恢复网络参数")
                }
            }
            ForEach(archive.apns.profiles.filter { $0.index >= archive.apns.presetCount }) { profile in
                Button {
                    restoringAPN = profile
                } label: {
                    SettingsRow(profile.name, symbol: "simcard", subtitle: "将 APN 恢复到新的可用槽位")
                }
            }
            Text("\(archive.apns.profiles.count) 项 APN（预置项保留只读，不覆盖）")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                restoringConfig = true
            } label: {
                SettingsRow("Mihomo 配置", symbol: "doc.text", subtitle: "预览、校验并应用")
            }
        } footer: {
            Text("打开文件不会修改设备。Wi-Fi 恢复不切换频段开关；APN 不覆盖原有槽位，保存可能切换为手动模式。")
        }
        .disabled(busy || devices.readOnly || archive.fingerprint != devices.current?.fingerprint)
    }

    private func generate() async {
        guard !busy else { return }
        loading = true
        let expected = revision
        let password = archivePassword
        defer { if expected == devices.clientRevision { loading = false } }
        do {
            guard password == confirmation, let client = devices.webClient as? any UFIArchiveService else {
                throw ManagementError.invalid("请核对备份密码和设备连接。")
            }
            let value = try await client.captureSettings(password: factoryPassword)
            let data = try await Task.detached(priority: .userInitiated) {
                try SettingsArchiveCipher.seal(value, password: password)
            }.value
            guard expected == devices.clientRevision else { return }
            removeExport()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("FlowDeck-F50-\(UUID().uuidString).flowbackup")
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            exportURL = url
            archive = value
            error = nil
        } catch {
            guard expected == devices.clientRevision else { return }
            self.error = error.localizedDescription
        }
    }

    private func open(_ url: URL) async {
        guard !busy, let fingerprint = devices.current?.fingerprint else { return }
        loading = true
        archive = nil
        let expected = revision
        let password = archivePassword
        defer { if expected == devices.clientRevision { loading = false } }
        do {
            let value = try await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                    size <= SettingsArchiveCipher.maximumBytes
                else {
                    throw ManagementError.invalid("恢复包超过大小限制。")
                }
                return try SettingsArchiveCipher.open(Data(contentsOf: url), password: password, fingerprint: fingerprint)
            }.value
            guard expected == devices.clientRevision else { return }
            archive = value
            error = nil
        } catch {
            guard expected == devices.clientRevision else { return }
            self.error = error.localizedDescription
        }
    }

    private func removeExport() {
        if let exportURL { try? FileManager.default.removeItem(at: exportURL) }
        exportURL = nil
    }
}
