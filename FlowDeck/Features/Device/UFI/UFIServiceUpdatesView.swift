import SwiftUI
import UniformTypeIdentifiers

/// 先下载/传输并核对 Android 包签名，再单独确认安装；断线只轮询，不重发更新。
struct UFIServiceUpdatesView: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(ManagementStore.self) private var manager
    @State private var state: UFIServiceUpdateState?
    @State private var release: UFIServiceRelease?
    @State private var package: UFIServicePackage?
    @State private var file: URL?
    @State private var error: String?
    @State private var loading = false
    @State private var importing = false
    @State private var progress: Double?
    @State private var action: String?
    @State private var revision = 0
    private var busy: Bool { loading || manager.working || state?.running == true }

    var body: some View {
        DetailSheet(title: "UFI-TOOLS 更新", closeDisabled: manager.working) {
            DeviceDetailSummary(
                symbol: "shippingbox", title: "设备管理服务",
                subtitle: "管理 App 与 Mihomo 核心分别更新，保留原厂固件和插件配置。")
            GlassSection("当前安装") {
                LabeledContent("UFI-TOOLS", value: state?.version ?? "未读取")
                LabeledContent("任务状态", value: statusTitle)
                if state?.needsRecovery == true {
                    Button("核对中断任务", systemImage: "arrow.counterclockwise") {
                        Task {
                            await manager.run("核对管理服务任务") {
                                _ = try await manager.verifiedAPI(devices, capability: .factoryControl)
                                try await api().recoverServiceUpdate()
                            }
                            await refresh()
                        }
                    }.disabled(busy || devices.readOnly)
                }
                Button("重新读取", systemImage: "arrow.clockwise") { Task { await refresh() } }.disabled(loading || manager.working)
            }
            GlassSection("完整版安装包") {
                if let release {
                    LabeledContent("作者发布版本", value: release.version)
                    Text(release.name).font(.caption).textSelection(.enabled)
                }
                Button("检查作者版本", systemImage: "magnifyingglass") { Task { await check() } }.disabled(busy)
                Button("下载到手机", systemImage: "arrow.down.circle") { Task { await download() } }.disabled(busy || release == nil)
                Button("导入本地 APK", systemImage: "folder") { importing = true }.disabled(busy)
                if let file {
                    ShareLink(item: file) { Label("保存安装包", systemImage: "square.and.arrow.up") }
                    Button("传入设备并验证", systemImage: "checkmark.shield") { Task { await prepare() } }
                        .disabled(busy || devices.readOnly)
                }
                if let progress { ProgressView(value: progress) }
                if let package {
                    Label("包名与已安装签名一致", systemImage: "checkmark.shield.fill")
                    LabeledContent("候选版本", value: package.version)
                    Text(package.code > package.installedCode ? "可安装更新" : "版本不高于当前安装，无需更新")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("备份并安装", systemImage: "arrow.triangle.2.circlepath") { action = "install" }
                        .disabled(busy || devices.readOnly || package.code <= package.installedCode)
                }
                Text("仅接受设备上的 UFI 原签名和包名；PE 版、其他签名、损坏包不会安装。手机可提前下载后再连接 F50。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            GlassSection("恢复管理服务") {
                Button("恢复上一个 APK", systemImage: "arrow.uturn.backward") { action = "restore" }
                    .disabled(busy || devices.readOnly || state?.backup != true)
                Text("保存原 APK 后可尝试回退。Android 若禁止版本降级，会保留当前安装；不会为回退卸载应用或清除数据。APK 回退不等于应用数据回退。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if loading { ProgressView() }
            if let error { Text(error).foregroundStyle(.orange).font(.footnote) }
        }
        .task(id: devices.clientRevision) {
            revision = devices.clientRevision
            package = nil
            state = nil
            await refresh()
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result {
                do {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                        (1...UFIPackageTransfer.maximumBytes).contains(size)
                    else { throw ManagementError.invalid("APK 文件过大或为空。") }
                    let target = FileManager.default.temporaryDirectory.appendingPathComponent("UFI-Import-\(UUID().uuidString).apk")
                    try FileManager.default.copyItem(at: url, to: target)
                    file = target
                    package = nil
                } catch { self.error = error.localizedDescription }
            }
        }
        .confirmationDialog("更新设备管理服务？", isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } }), titleVisibility: .visible) {
            Button("确认继续", role: .destructive) {
                let restore = action == "restore"
                action = nil
                Task { await install(restore: restore) }
            }
        } message: {
            Text("UFI 管理连接会暂时断开，设备后台继续执行。保持供电，勿重复提交。此操作不升级原厂固件。")
        }
    }

    private var statusTitle: String {
        switch state?.status {
        case "interrupted": "设备重启中断了任务，请核对"
        case "orphaned": "任务已退出，请重启设备后核对"
        case "recovery-required": "任务记录不完整，需人工核对"
        case "recovering": "正在核对中断任务"
        case "starting": "准备安装"
        case "installing": "替换管理 App"
        case "reconnecting": "恢复管理连接"
        case "done": "版本回读通过"
        case "rejected": "未接受安装，保留现有版本"
        case "unconfirmed": "版本尚未确认"
        default: "暂无任务"
        }
    }

    private func api() throws -> any UFIAppUpdateService {
        guard let value = devices.webClient as? any UFIAppUpdateService else { throw ManagementError.deviceChanged }
        return value
    }

    private func refresh() async {
        let expected = devices.clientRevision
        do {
            let value = try await api().serviceUpdateState()
            guard expected == devices.clientRevision else { return }
            state = value
            error = nil
        } catch {
            if expected == devices.clientRevision { self.error = error.localizedDescription }
        }
    }

    private func check() async {
        loading = true
        defer { loading = false }
        do { release = try await UFIServiceRelease.latest() } catch { self.error = error.localizedDescription }
    }

    private func download() async {
        guard let release else { return }
        loading = true
        defer { loading = false }
        do {
            file = try await release.download()
            package = nil
        } catch { self.error = error.localizedDescription }
    }

    private func prepare() async {
        guard let file else { return }
        let expected = revision
        await manager.run("验证 UFI 安装包") {
            _ = try await manager.verifiedAPI(devices, capability: .factoryControl)
            guard expected == devices.clientRevision else { throw ManagementError.deviceChanged }
            let value = try await api().prepareServicePackage(Data(contentsOf: file)) { value in
                await MainActor.run { if expected == devices.clientRevision { progress = value } }
            }
            guard expected == devices.clientRevision else { throw ManagementError.deviceChanged }
            package = value
        }
        if expected == devices.clientRevision { error = manager.error }
    }

    private func install(restore: Bool) async {
        let expected = revision
        guard restore || package != nil else { return }
        await manager.run("更新 UFI 管理服务") {
            _ = try await manager.verifiedAPI(devices, capability: .factoryControl)
            guard expected == devices.clientRevision else { throw ManagementError.deviceChanged }
            let client = try api()
            try await client.installServicePackage(restore ? nil : package)
            // APK 替换会断开服务。只有这一段容忍临时网络错误，绝不重发安装请求。
            for _ in 0..<40 {
                try await Task.sleep(for: .seconds(3))
                guard expected == devices.clientRevision else { throw ManagementError.deviceChanged }
                guard let actual = try? await client.serviceUpdateState() else { continue }
                state = actual
                if actual.running { continue }
                guard actual.status == "done" else { throw ManagementError.unconfirmed("设备未确认安装成功，请核对当前版本。") }
                return
            }
            throw ManagementError.unconfirmed("管理服务尚未恢复，请保持供电后重新读取，勿重复安装。")
        }
        if expected == devices.clientRevision { error = manager.error }
    }
}
