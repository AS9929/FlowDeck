import SwiftUI
import UniformTypeIdentifiers

/// 首次部署原生向导。原厂恢复和启用代理都需要独立确认，浏览页面不会触发安装。
struct DeploymentView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(DeviceStore.self) private var devices
    @Environment(ManagementStore.self) private var manager
    @State private var store = DeploymentStore()
    @State private var importing = false
    @State private var importingSuffix = false
    @State private var confirm: Confirmation?
    @State private var backupSaved = false
    @State private var inputError: String?

    var initialRoute: DeploymentStore.Route = .managed
    var newDevice = false

    private enum Confirmation: String, Identifiable {
        case bootstrap, restore, install, activate
        var id: String { rawValue }
    }

    var body: some View {
        DetailSheet(title: "部署代理") {
            DeviceDetailSummary(
                symbol: "shippingbox", title: "让设备具备代理能力",
                subtitle: "检测设备 → 准备安装 → 导入配置 → 验证联网")
            GlassSection("部署方式") {
                routePicker.disabled(store.phase != "new")
                Button("部署另一台设备", systemImage: "plus.circle") {
                    store.useNewDevice()
                    backupSaved = false
                    inputError = nil
                }
                Toggle("演示流程", isOn: $store.simulation)
                    .disabled(store.phase != "new")
                Text(
                    store.route == .factory
                        ? "原厂设备先完成电脑辅助准备，再回到 App 部署代理。纯 Wi-Fi 首次解锁尚未通过实机验收，当前不开放写入。"
                        : "已有 WebSSH 的设备可安装 Mihomo。已有代理或配置不会被首次安装覆盖。"
                )
                .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            }
            if store.route == .factory && !store.simulation {
                factoryPreparation
            } else {
                GlassSection("连接设备") {
                    FormField("名称") { TextField("随身", text: $store.profile.name) }
                    FormField("管理地址") {
                        TextField("192.168.0.1", text: $store.profile.host)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.decimalPad)
                    }
                    if store.route == .factory {
                        FormField("原厂网页密码") { SecureField("不是 Wi-Fi 密码", text: $store.factoryPassword) }
                        FormField("备份解密后缀") { SecureField("由设备部署资料提供", text: $store.suffix) }
                        Button("导入本机部署参数", systemImage: "square.and.arrow.down") { importingSuffix = true }
                        FormField("设置 WebSSH 密码") { SecureField("12–63 字节", text: $store.webPassword) }
                    } else {
                        FormField("WebSSH 端口") {
                            TextField("8899", value: $store.profile.webPort, format: .number.grouping(.never))
                                .keyboardType(.numberPad)
                        }
                        FormField("WebSSH 账号") { TextField("admin", text: $store.profile.webUser) }
                        FormField("WebSSH 密码") { SecureField("管理服务密码", text: $store.webPassword) }
                    }
                }
                .disabled(store.phase != "new")
                GlassSection {
                    action("检查设备", "checkmark.shield") { await store.inspect(devices) }
                    if store.phase != "new", store.canEditConnection {
                        Button("修改连接信息", systemImage: "pencil") { store.editConnection() }
                    }
                }
                if store.route == .factory {
                    factorySteps
                } else {
                    proxySteps
                }
                if let url = store.originalURL {
                    GlassSection("原始备份与恢复") {
                        ShareLink(item: url) { Label("导出原始备份", systemImage: "square.and.arrow.up") }
                        Button("恢复原始备份", systemImage: "arrow.uturn.backward", role: .destructive) { confirm = .restore }
                            .disabled(devices.readOnly || ["factoryRestoreSubmitted", "factoryRestored"].contains(store.phase))
                        Text("恢复该备份中的原厂设置并重启；不会删除 /data 中的插件文件。请保持连接到这台设备。")
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                }
            }
            GlassSection("当前进度") {
                if store.busy {
                    if let progress = store.progress { ProgressView(value: progress) } else { ProgressView() }
                }
                Label(store.message, systemImage: store.phase == "complete" ? "checkmark.circle" : "info.circle")
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                if let error = store.error ?? inputError {
                    Text(error).foregroundStyle(.orange).font(.footnote.weight(.medium)).textSelection(.enabled)
                }
                if store.phase == "complete" {
                    Text("回到代理页即可管理节点。实际使用请保持手机连接设备 Wi-Fi。")
                        .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(store.busy || manager.working)
        .navigationBarBackButtonHidden(store.busy)
        .task {
            store.load(devices)
            if newDevice {
                store.useNewDevice()
                store.simulation = false
            }
            if store.phase == "new" { store.route = initialRoute }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.yaml, .plainText, .data]) { result in
            readFile(result, suffix: false)
        }
        .fileImporter(isPresented: $importingSuffix, allowedContentTypes: [.json]) { result in
            readFile(result, suffix: true)
        }
        .confirmationDialog("确认部署操作", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            if let confirm {
                Button(
                    confirm == .restore ? "恢复原始备份并重启" : confirm == .bootstrap ? "导入安装包并重启" : confirm == .activate ? "启用并验证" : "开始安装",
                    role: confirm == .restore ? .destructive : nil
                ) {
                    Task {
                        switch confirm {
                        case .bootstrap: await store.applyFactory(devices)
                        case .restore: await store.applyFactory(devices, restoreOriginal: true)
                        case .install: await store.installProxy(devices)
                        case .activate: await store.activate(devices)
                        }
                    }
                    self.confirm = nil
                }
            }
        } message: {
            Text(
                confirm == .bootstrap || confirm == .restore
                    ? "设备会恢复该备份中的全部设置并重启，Wi-Fi 会暂时断开。请确认已保存原始备份并保持供电。"
                    : "只操作当前已验证设备。安装期间保持 App 在前台和 Wi-Fi 连接，失败或中断后先查询状态，不重复提交。")
        }
    }

    @ViewBuilder
    private var routePicker: some View {
        // 分段和菜单的选中标题在极大字号下都会截断，改为可换行的纵向选项。
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(DeploymentStore.Route.allCases) { route in
                    Button {
                        store.route = route
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Text(route.rawValue)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if store.route == route { Image(systemName: "checkmark.circle.fill") }
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(store.route == route ? AppTheme.aqua : Color.primary)
                    .accessibilityValue(store.route == route ? "已选择" : "未选择")
                }
            }
        } else {
            Picker("设备状态", selection: $store.route) {
                ForEach(DeploymentStore.Route.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    /// 原厂解锁尚无手机端实机证据，不向用户展示能直接执行的恢复入口。
    private var factoryPreparation: some View {
        Group {
            GlassSection("先准备管理通道") {
                Label("需要电脑与 USB 数据线", systemImage: "laptopcomputer")
                    .font(.headline)
                Text("此前成功部署使用电脑处理原厂备份，开启 root ADB，再经 USB 安装 WebSSH。普通 Wi-Fi 连接本身不提供 root 或 ADB 权限。")
                    .foregroundStyle(.secondary)
                Label("目前适配：MU5250 / U60 Pro · B28", systemImage: "checkmark.shield")
                    .font(.footnote.weight(.medium))
                Text("其他中兴型号和固件需单独验证，安装了 WebSSH 也不代表透明代理脚本一定兼容。")
                    .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            }
            GlassSection("电脑准备的三个阶段") {
                preparationStep("1", "保留原厂恢复副本", "核对型号、固件和设备身份；导出当前设备的原始备份并验证可解密，不能套用其他设备的备份。")
                Divider()
                preparationStep("2", "安装并验证 WebSSH", "通过已验证的备份导入流程开启 root ADB；电脑确认 uid=0 后，经 USB 上传文件、校验摘要并初始化管理密码。")
                Divider()
                preparationStep("3", "恢复日常 USB 模式", "确认 WebSSH 登录和持久化启动正常后，恢复原厂 USB 联网模式，再继续 App 内的代理部署。")
            }
            GlassSection("准备完成后") {
                Button("已有 WebSSH，继续部署", systemImage: "arrow.right.circle") {
                    store.route = .managed
                }
                Text("此时只需 WebSSH 管理密码，无需已有 Mihomo Secret。App 会生成独立控制密钥。演示流程仅用于了解步骤，不会操作路由器。")
                    .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            }
        }
    }

    private func preparationStep(_ number: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(number + " · " + title).font(.headline)
            Text(detail).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var factorySteps: some View {
        Group {
            GlassSection("1 · 准备与备份") {
                action("生成离线安装包", "shippingbox") { await store.prepareFactory(devices) }
                    .disabled(!["factoryDetected", "factoryPrepared"].contains(store.phase))
                if let url = store.originalURL {
                    ShareLink(item: url) { Label("导出原始备份", systemImage: "square.and.arrow.up") }
                }
                if store.preparedURL != nil || store.simulation && store.phase == "factoryPrepared" {
                    Toggle("已另存原始备份", isOn: $backupSaved)
                    Button("导入安装包并重启", systemImage: "arrow.up.doc") { confirm = .bootstrap }
                        .disabled(!backupSaved || store.phase != "factoryPrepared" || devices.readOnly)
                }
            }
            GlassSection("2 · 重连与初始化") {
                Text("等待设备重启后，重新连接它的 Wi-Fi。检查会验证 WebSSH 密码与硬件身份；连接失败不会重复导入。")
                    .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                action("检查管理通道，继续部署", "wifi") { await store.reconnect(devices) }
            }
        }
    }

    private var proxySteps: some View {
        Group {
            GlassSection("1 · 选择配置") {
                Button("导入 Mihomo YAML 或 Surge 配置", systemImage: "doc.badge.plus") { importing = true }
                if !store.sourceName.isEmpty { Text(store.sourceName).font(.footnote.weight(.medium)).foregroundStyle(.secondary) }
                Text("保留节点、策略和规则，网络端口、DNS、TUN 及随机 Secret 按设备适配。Surge 配置在本机转换，规则集按在线地址下载；YAML 中依赖本地文件的规则集需先改为在线版本。")
                    .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                if store.simulation {
                    Button("使用演示配置") {
                        store.source = "proxies: []\nproxy-groups: []\nrules:\n  - MATCH,DIRECT\n"
                        store.sourceName = "演示配置 · 不连接真实设备"
                    }
                }
            }
            GlassSection("2 · 安装与校验") {
                Button("检查并同步设备时间", systemImage: "clock.arrow.circlepath") {
                    Task { await store.synchronizeClock(devices) }
                }
                .disabled(store.phase == "new" || devices.readOnly)
                Text("系统时间异常会影响 TLS 下载和节点连接。此操作仅在点击后将设备时钟同步到手机。")
                    .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                Button("安装核心并校验配置", systemImage: "square.and.arrow.down") { confirm = .install }
                    .disabled(store.source.isEmpty || !["ready", "coreRequested", "dataRequested", "configWritten"].contains(store.phase) || devices.readOnly)
                Text("使用 App 内置的 v1.19.32 核心、控制脚本和地理数据，经 Wi-Fi 传到设备；安装基础资源不访问 GitHub。你的订阅、在线规则及代理出口仍需要可用网络。")
                    .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            }
            GlassSection("3 · 启用代理") {
                Button("启用并验证联网", systemImage: "power") { confirm = .activate }
                    .disabled(!["validated", "activationRequested"].contains(store.phase) || devices.readOnly)
                Text("控制接口和 HTTP 出口通过后才开启自启动。UDP 及真实手机访问需要单独确认。")
                    .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            }
        }
    }

    private func action(_ title: String, _ symbol: String, perform: @escaping () async -> Void) -> some View {
        Button {
            Task { await perform() }
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    private func readFile(_ result: Result<URL, Error>, suffix: Bool) {
        do {
            let url = try result.get()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 8 * 1024 * 1024 else {
                throw ManagementError.invalid("文件超过 8 MB 上限。")
            }
            let data = try Data(contentsOf: url)
            if suffix {
                guard let values = try JSONSerialization.jsonObject(with: data) as? [String: String],
                    let key = values["backupKeySuffix"], !key.isEmpty
                else { throw ManagementError.invalid("参数文件须包含 backupKeySuffix，且只能保存在个人受保护的位置。") }
                store.suffix = key
            } else {
                guard let text = String(data: data, encoding: .utf8) else { throw ManagementError.invalid("配置需要 UTF-8 编码。") }
                if DeploymentConfiguration.looksLikeSurge(text) {
                    let converted = try DeploymentConfiguration.fromSurge(text)
                    store.source = converted.yaml
                    store.sourceName = url.lastPathComponent + " · " + converted.summary
                } else {
                    store.source = text
                    store.sourceName = url.lastPathComponent
                }
            }
            inputError = nil
        } catch { inputError = error.localizedDescription }
    }
}
