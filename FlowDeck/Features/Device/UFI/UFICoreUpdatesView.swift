import SwiftUI
import UniformTypeIdentifiers

/// F50 核心更新保留原插件目录和启动脚本；App 只观察后台事务，不用退出页面冒充取消。
struct UFICoreUpdatesView: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(ManagementStore.self) private var manager
    @State private var state: UFICoreState?
    @State private var release: UFICoreRelease?
    @State private var error: String?
    @State private var loading = false
    @State private var confirmation: String?
    @State private var revision = 0
    @State private var importing = false
    @State private var packageURL: URL?
    @State private var transferProgress: Double?

    private var busy: Bool { loading || manager.working || state?.running == true }
    private var newer: Bool {
        guard let release, let state else { return false }
        guard let range = state.version.range(of: "v[0-9]+\\.[0-9]+\\.[0-9]+", options: .regularExpression) else { return false }
        return release.version.compare(String(state.version[range]), options: .numeric) == .orderedDescending
    }

    var body: some View {
        DetailSheet(title: "Mihomo 核心更新", closeDisabled: manager.working) {
            DeviceDetailSummary(
                symbol: "shippingbox", title: "F50 · 代理核心",
                subtitle: "保留 UFI-TOOLS、启动脚本和现有配置，仅替换 Mihomo 内核")
            GlassSection("当前版本") {
                Text(state?.shortVersion ?? "正在读取…")
                    .font(.title.weight(.bold)).textSelection(.enabled)
                if let state {
                    DisclosureGroup("构建信息") {
                        Text(state.version).font(.caption.monospaced()).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }.font(.subheadline)
                }
                Label("Android ARM64 · F50 B09", systemImage: "cpu").font(.subheadline)
                    .foregroundStyle(.secondary)
                if loading { ProgressView() }
                Button("重新读取设备状态", systemImage: "arrow.clockwise") {
                    Task { await refresh() }
                }.disabled(loading || manager.working)
            }
            GlassSection("官方更新") {
                if let release {
                    LabeledContent("稳定版本", value: release.version)
                    LabeledContent(
                        "下载大小", value: ByteCountFormatter.string(fromByteCount: Int64(release.size), countStyle: .file))
                    Label("SHA-256 校验后安装", systemImage: "checkmark.shield").font(.subheadline)
                    Text(newer ? "下载成功并通过当前配置校验后才会停止旧核心。" : "当前版本无需更新到此稳定版。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("备份并安装更新", systemImage: "arrow.down.circle") { confirmation = "install" }
                        .disabled(busy || devices.readOnly || !newer)
                }
                Button("检查官方版本", systemImage: "magnifyingglass") { Task { await checkLatest() } }
                    .disabled(busy)
                Text("版本信息由手机获取，安装包由设备从 GitHub 下载。下载失败会保留原核心，不会先停止代理。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            GlassSection("离线安装包") {
                Text("先用手机有网络时下载，或从文件导入与已缓存官方版本匹配的 gzip 包。连接 F50 后由手机传入，无需设备访问 GitHub。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let packageURL {
                    Label("软件包已校验", systemImage: "checkmark.shield")
                    ShareLink(item: packageURL) { Label("导出安装包", systemImage: "square.and.arrow.up") }
                    Button("传入设备并安装", systemImage: "arrow.down.to.line") { confirmation = "offline" }
                        .disabled(busy || devices.readOnly || !newer)
                }
                if let transferProgress { ProgressView(value: transferProgress) }
                Button("下载到手机", systemImage: "iphone.and.arrow.down") { Task { await obtainPackage(nil) } }
                    .disabled(busy || release == nil)
                Button("从文件导入", systemImage: "folder") { importing = true }
                    .disabled(busy || release == nil)
            }
            GlassSection("恢复与进度") {
                Label(state?.statusTitle ?? "暂无更新任务", systemImage: state?.running == true ? "hourglass" : "clock.arrow.circlepath")
                    .font(.subheadline.weight(.semibold))
                if state?.running == true { ProgressView() }
                if state?.needsRecovery == true {
                    Button("核对并恢复中断任务", systemImage: "arrow.counterclockwise") {
                        Task {
                            await manager.run("恢复中断任务") {
                                _ = try await manager.verifiedAPI(devices, capability: .proxyService)
                                try await client().recoverCoreUpdate()
                            }
                            await refresh()
                        }
                    }.disabled(loading || manager.working || devices.readOnly)
                    Text("只处理已重启设备上的本 App 任务。备份校验不符或任务归属未知时保留现场。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("恢复上一个核心", systemImage: "arrow.uturn.backward") { confirmation = "rollback" }
                    .disabled(busy || devices.readOnly || state?.backupAvailable != true)
                if state?.backupAvailable != true {
                    Text("首次成功备份核心后可用；恢复前再次验证摘要和配置兼容性。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
            Text("更新会短暂中断代理。离开 App 不会取消设备任务；重新进入可继续查看状态。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: devices.clientRevision) {
            revision = devices.clientRevision
            state = nil
            release = UFICorePackageCache.remembered()
            packageURL = nil
            if let release,
                (try? UFICorePackageCache.validatedData(UFICorePackageCache.file(release), release: release)) != nil
            {
                packageURL = UFICorePackageCache.file(release)
            }
            error = nil
            await refresh()
            while state?.running == true, !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
                await refresh()
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { Task { await obtainPackage(url) } }
        }
        .confirmationDialog(
            confirmation == "rollback" ? "恢复上一个 Mihomo 核心？" : "安装官方 Mihomo 内核？",
            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
            titleVisibility: .visible
        ) {
            Button("确认并继续", role: .destructive) {
                let rollback = confirmation == "rollback"
                let offline = confirmation == "offline"
                confirmation = nil
                Task { await perform(rollback: rollback, offline: offline) }
            }
        } message: {
            Text("代理会短暂断开；准备失败保留旧核心，切换失败会尝试恢复。不会升级原厂固件。")
        }
    }

    private func client() throws -> any WebSSHAPI & UFICoreUpdateService {
        guard let api = devices.webClient as? any WebSSHAPI & UFICoreUpdateService else { throw ManagementError.deviceChanged }
        return api
    }

    private func refresh() async {
        let expected = devices.clientRevision
        loading = true
        defer { loading = false }
        do {
            let value = try await client().coreUpdateState()
            guard expected == devices.clientRevision else { return }
            state = value
            error = nil
        } catch {
            if expected == devices.clientRevision { self.error = error.localizedDescription }
        }
    }

    private func checkLatest() async {
        let expected = devices.clientRevision
        loading = true
        defer { loading = false }
        do {
            let value = try await UFICoreRelease.latest()
            guard expected == devices.clientRevision else { return }
            try UFICorePackageCache.remember(value)
            release = value
            packageURL = nil
            error = nil
        } catch {
            if expected == devices.clientRevision { self.error = error.localizedDescription }
        }
    }

    private func obtainPackage(_ imported: URL?) async {
        guard !busy, let release else { return }
        let expected = devices.clientRevision
        loading = true
        defer { if expected == devices.clientRevision { loading = false } }
        do {
            let url: URL
            if let imported {
                let scoped = imported.startAccessingSecurityScopedResource()
                defer { if scoped { imported.stopAccessingSecurityScopedResource() } }
                url = try UFICorePackageCache.store(imported, release: release)
            } else {
                url = try await UFICorePackageCache.download(release)
            }
            guard expected == devices.clientRevision else { return }
            packageURL = url
            error = nil
        } catch {
            if expected == devices.clientRevision { self.error = error.localizedDescription }
        }
    }

    private func perform(rollback: Bool, offline: Bool) async {
        let expected = revision
        let selected = release
        guard rollback || selected != nil else { return }
        await manager.run(rollback ? "恢复 F50 核心" : "更新 F50 核心") {
            let verified = try await manager.verifiedAPI(devices, capability: .proxyService)
            guard expected == devices.clientRevision, let api = verified as? any WebSSHAPI & UFICoreUpdateService else {
                throw ManagementError.deviceChanged
            }
            let previous = try await api.mihomoStatus()
            let package: Data?
            if offline {
                guard let selected, let packageURL else {
                    throw ManagementError.invalid("离线包已失效，请重新选择并校验。")
                }
                package = try UFICorePackageCache.validatedData(packageURL, release: selected)
            } else {
                package = nil
            }
            try await api.startCoreUpdate(rollback ? nil : selected, package: package) { progress in
                await MainActor.run {
                    if expected == devices.clientRevision { transferProgress = progress }
                }
            }
            for _ in 0..<100 {
                try await Task.sleep(for: .seconds(3))
                let value = try await api.coreUpdateState()
                guard expected == devices.clientRevision else { throw ManagementError.deviceChanged }
                state = value
                if value.running { continue }
                guard value.status == "done" else { throw ManagementError.unconfirmed(value.statusTitle) }
                let actual = try await api.mihomoStatus()
                guard actual.running == (rollback || previous.running), !actual.running || actual.apiReachable else {
                    throw ManagementError.unconfirmed("设备任务已结束，但代理控制尚未恢复，请重新读取状态。")
                }
                if let selected, !rollback, !value.version.contains(" " + selected.version + " ") {
                    throw ManagementError.unconfirmed("运行版本与所选版本不一致，请检查设备。")
                }
                return
            }
            throw ManagementError.unconfirmed("等待超时，设备可能仍在执行；请重新读取状态，不要重复安装。")
        }
        if expected == devices.clientRevision { error = manager.error }
    }
}
