import SwiftUI

// MARK: - 配置检查结果

struct ConfigCheckView: View {
    let result: ConfigCheckResult
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DetailSheet(title: "配置检查") {
            GlassSection {
                Label(result.ok ? "配置有效" : "检查未通过", systemImage: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(result.ok ? .green : .red)
                if !result.output.isEmpty {
                    Text(result.output).font(.caption.monospaced()).textSelection(.enabled)
                }
            } footer: {
                Text("检查的是设备上已保存的 config.yaml（mihomo -t），不会修改任何设置。")
            }
        }
    }
}

// MARK: - 导入配置

struct ConfigImportView: View {
    let name: String
    let content: String
    var expectedDeviceID: String?
    @Environment(DeviceStore.self) private var devices
    @State private var loadedRevision: Int?
    @Environment(DeviceStatusStore.self) private var status
    @Environment(PolicyStore.self) private var policy
    @Environment(\.dismiss) private var dismiss
    @State private var step: DeviceStatusStore.ImportStep?
    @State private var running = false
    @State private var baseline: String?
    @State private var previewError: String?
    @State private var loadingPreview = false
    @State private var difference: ConfigurationDifference?

    var body: some View {
        DetailSheet(title: "导入配置", doneTitle: "关闭", closeDisabled: running) {
            GlassSection("文件") {
                LabeledContent("名称", value: name)
                LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: Int64(content.utf8.count), countStyle: .file))
                LabeledContent("策略组", value: "\(countMatches("- name:", in: proxyGroupsSection)) 个")
                if content.contains("USER-AGENT") {
                    Label("包含 Mihomo 不支持的 USER-AGENT 规则，检查会失败", systemImage: "exclamationmark.triangle")
                        .font(.footnote.weight(.medium)).foregroundStyle(.orange)
                }
                if !content.contains("external-controller") {
                    Label("没有 external-controller，导入后 App 将无法控制代理", systemImage: "exclamationmark.triangle")
                        .font(.footnote.weight(.medium)).foregroundStyle(.orange)
                }
            }
            GlassSection("与设备配置比较") {
                if let diff = difference {
                    LabeledContent("文本变更", value: "新增 \(diff.inserted) 行 · 删除 \(diff.removed) 行")
                    Text(diff.changedSections.isEmpty ? "没有顶层分区变化" : "变更分区：" + diff.changedSections.joined(separator: "、"))
                        .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                    Text("这是文本差异，不代表语义校验；应用时仍由设备上的 Mihomo 校验。")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                } else if loadingPreview {
                    ProgressView("读取设备上的基准配置…")
                } else {
                    Text(previewError ?? "等待预览").font(.footnote.weight(.medium)).foregroundStyle(.orange)
                    Button("重新读取预览") { Task { await loadBaseline() } }
                }
            }
            GlassSection("步骤") {
                stepRow("保存当前版本，写入新配置", active: step == .uploading, done: passed(.uploading))
                stepRow("检查配置（mihomo -t）", active: step == .checking, done: passed(.checking))
                stepRow("重启代理核心", active: step == .restarting, done: step == .done)
            }
            if let step {
                GlassSection {
                    switch step {
                    case .done:
                        Label("新配置已生效", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .rolledBack(let why):
                        VStack(alignment: .leading, spacing: 6) {
                            Label("检查未通过，已写回原来的配置", systemImage: "arrow.uturn.backward.circle.fill").foregroundStyle(.orange)
                            Text(why).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    case .failed(let why):
                        Label(why, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    default:
                        EmptyView()
                    }
                }
            }
            GlassSection {
                Button("检查并应用") {
                    running = true
                    Task {
                        guard loadedRevision == devices.clientRevision else {
                            step = .failed("设备已切换，请重新预览配置。")
                            running = false
                            return
                        }
                        await status.importConfig(content, sourceName: name, expectedChecksum: baseline.map { DeviceIdentity.digest(Data($0.utf8)) }) {
                            step = $0
                        }
                        running = false
                        await policy.refresh()
                    }
                }
                .disabled(running || step == .done || baseline == nil || baseline == content || loadedRevision != devices.clientRevision)
            } footer: {
                Text("会写入设备上的 config.yaml，并在检查通过后重启代理核心，所有设备会短暂断开代理约 30 秒。")
            }
        }
        .task { await loadBaseline() }
        .interactiveDismissDisabled(running)
        .scrollContentBackground(.hidden)
        .background(AppBackground())
    }

    private func loadBaseline() async {
        loadingPreview = true
        defer { loadingPreview = false }
        do {
            let revision = devices.clientRevision
            guard expectedDeviceID == nil || expectedDeviceID == devices.storageID else { throw ManagementError.deviceChanged }
            let current = try await status.deviceConfig()
            let candidate = content
            let diff = await Task.detached(priority: .userInitiated) {
                ConfigurationDifference(before: current, after: candidate)
            }.value
            guard !Task.isCancelled else { return }
            guard revision == devices.clientRevision else { throw ManagementError.deviceChanged }
            loadedRevision = revision
            baseline = current
            difference = diff
            previewError = nil
        } catch {
            previewError = "读取基准失败：" + error.localizedDescription
        }
    }

    private var proxyGroupsSection: String {
        guard let r = content.range(of: "proxy-groups:") else { return "" }
        let rest = content[r.upperBound...]
        if let end = rest.range(of: "\nrule-providers:") ?? rest.range(of: "\nrules:") { return String(rest[..<end.lowerBound]) }
        return String(rest)
    }

    private func countMatches(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private func passed(_ s: DeviceStatusStore.ImportStep) -> Bool {
        let order: [DeviceStatusStore.ImportStep] = [.uploading, .checking, .restarting, .done]
        guard let step, let cur = order.firstIndex(of: step), let target = order.firstIndex(of: s) else { return false }
        return cur > target
    }

    private func stepRow(_ title: String, active: Bool, done: Bool) -> some View {
        HStack {
            Group {
                if active {
                    ProgressView()
                } else {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? .green : .secondary)
                }
            }
            .frame(width: 22)
            Text(title)
        }
    }
}

// MARK: - 从 Surge 导入

/// 读取设备当前配置 → 在手机上转换 Surge → 只替换节点、策略组、规则集和规则 → 交给导入流程检查并应用。
struct SurgeImportView: View {
    let name: String
    let text: String
    @Environment(DeviceStatusStore.self) private var status
    @Environment(PolicyStore.self) private var policy
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading
    @State private var applying: ProxyConfigurationView.ImportedConfig?

    enum Phase {
        case loading
        case ready(SurgeConverter.Result, merged: String, kept: [String])
        case failed(String)
    }

    var body: some View {
        DetailSheet(title: "从 Surge 导入", doneTitle: "关闭") {
            GlassSection("文件") {
                LabeledContent("名称", value: name)
                LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .file))
            }
            switch phase {
            case .loading:
                GlassSection {
                    HStack {
                        ProgressView()
                        Text("正在读取设备配置并转换…")
                    }
                }
            case .failed(let msg):
                GlassSection {
                    Label(msg, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                } footer: {
                    Text("设备上的配置没有任何改动。")
                }
            case .ready(let r, let merged, let kept):
                GlassSection("转换结果") {
                    LabeledContent("节点", value: nodeSummary(r))
                    LabeledContent("策略组", value: "\(r.groups.count) 个" + (r.droppedGroups.isEmpty ? "" : "（去掉空组 \(r.droppedGroups.joined(separator: "、"))）"))
                    LabeledContent("规则", value: "\(r.rules.count) 条 · \(r.providers.count) 个规则集")
                    LabeledContent("图标", value: "\(r.groups.filter { $0.icon != nil }.count) 个组带图标")
                }
                GlassSection {
                    Label("PROTOCOL → NETWORK、DEST-PORT → DST-PORT 等写法差异，沿用设备上的本地兼容规则集（\(kept.count) 个）", systemImage: "checkmark.circle")
                    if !r.ignoredRules.isEmpty {
                        Label("有 \(r.ignoredRules.count) 条独立规则未转换；本模板只导入远程 RULE-SET，并重建国内及兜底规则。", systemImage: "exclamationmark.triangle")
                            .font(.footnote.weight(.medium)).foregroundStyle(.orange)
                        Text(r.ignoredRules.joined(separator: "\n"))
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                    if !r.ignoredSections.isEmpty {
                        Label("忽略 Surge 专属功能：\(r.ignoredSections.joined(separator: "、"))", systemImage: "minus.circle")
                    }
                    Label("保留这台设备的 Secret、端口、DNS、TUN、NTP 设置", systemImage: "lock")
                    Label("节点选择按名称保留", systemImage: "arrow.triangle.2.circlepath")
                } header: {
                    Text("处理方式")
                }
                .font(.footnote.weight(.medium))
                GlassSection {
                    Button("下一步：检查并应用") { applying = ProxyConfigurationView.ImportedConfig(name: name, content: merged) }
                } footer: {
                    Text("节点密码只经本地网络写入设备，不经过任何服务器。")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .task { await prepare() }
        .appModal(item: $applying) { cfg in ConfigImportView(name: cfg.name, content: cfg.content) }
    }

    private func nodeSummary(_ r: SurgeConverter.Result) -> String {
        let current = Set(policy.proxies.values.filter { !$0.isGroup && !$0.isBuiltin }.map(\.name))
        let incoming = Set(r.proxies.map(\.name))
        guard !current.isEmpty else { return "\(r.proxies.count) 个" }
        let added = incoming.subtracting(current).count
        let removed = current.subtracting(incoming).count
        return "\(r.proxies.count) 个（新增 \(added) · 删除 \(removed)）"
    }

    private func prepare() async {
        do {
            let result = try SurgeConverter.convert(text)
            let device = try await status.deviceConfig()
            let (merged, kept) = try SurgeConverter.merge(result, into: device)
            phase = .ready(result, merged: merged, kept: kept)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

// MARK: - 连接设置

/// 编辑设备地址、Secret 和 WebSSH 密码。“测试连接”只读，不改设备。
struct DeviceEditor: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(\.dismiss) private var dismiss
    @State var device: DeviceProfile
    @State private var secret = ""
    @State private var webPassword = ""
    @State private var portText = ""
    @State private var webPortText = ""
    @State private var testLines: [(String, Bool)] = []
    @State private var testing = false

    var body: some View {
        DetailSheet(title: "连接设置", doneTitle: "取消") {
            GlassSection("设备") {
                TextField("名称", text: $device.name)
                TextField("地址", text: $device.host)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            GlassSection {
                TextField("端口", text: $portText).keyboardType(.numberPad)
                SecureField("Secret", text: $secret)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("代理控制（Mihomo）")
            } footer: {
                Text("部署资料 private/access.json 里的 mihomo_secret。")
            }
            GlassSection {
                TextField("端口", text: $webPortText).keyboardType(.numberPad)
                TextField("账号", text: $device.webUser)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密码", text: $webPassword)
            } header: {
                Text("WebSSH")
            } footer: {
                Text("账号 admin，密码与原厂管理密码相同。设备、Wi-Fi、短信和代理启停都通过它。凭据只保存在本机钥匙串。")
            }
            GlassSection {
                Button {
                    Task { await test() }
                } label: {
                    HStack {
                        Text("测试连接")
                        Spacer()
                        if testing { ProgressView() }
                    }
                }
                .disabled(testing || device.host.isEmpty)
                ForEach(testLines.indices, id: \.self) { i in
                    Text(testLines[i].0).font(.footnote.weight(.medium)).foregroundStyle(testLines[i].1 ? .green : .orange)
                }
            } footer: {
                Text("只读取版本、策略组数量和代理服务状态，不会修改设备。")
            }
            GlassSection {
                Button("保存") {
                    device.mihomoPort = Int(portText) ?? 9090
                    device.webPort = Int(webPortText) ?? 8899
                    devices.save(device, secret: secret, webPassword: webPassword)
                    dismiss()
                }
                .disabled(device.name.isEmpty || device.host.isEmpty)
                if devices.devices.contains(where: { $0.id == device.id }) {
                    Button("移除这台设备", role: .destructive) {
                        devices.remove(device)
                        dismiss()
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .onAppear {
            secret = devices.secret(for: device)
            webPassword = devices.webPassword(for: device)
            portText = String(device.mihomoPort)
            webPortText = String(device.webPort)
        }
    }

    private func test() async {
        testing = true
        testLines = []
        defer { testing = false }
        if let client = devices.probeClient(host: device.host, port: Int(portText) ?? 9090, secret: secret) {
            do {
                let v = try await client.version()
                let groups = try await client.proxies().values.filter(\.isGroup).count
                testLines.append(("代理控制：Mihomo \(v.version)，\(groups) 个策略组（含 GLOBAL）", true))
            } catch {
                testLines.append(("代理控制：\(error.localizedDescription)", false))
            }
        }
        if !webPassword.isEmpty,
            let web = devices.probeWebClient(host: device.host, port: Int(webPortText) ?? 8899, user: device.webUser, password: webPassword)
        {
            do {
                let s = try await web.mihomoStatus()
                testLines.append(("WebSSH：登录成功，代理\(s.running ? "运行中" : "未运行")", true))
            } catch {
                testLines.append(("WebSSH：\(error.localizedDescription)", false))
            }
        }
    }
}

struct HiddenGroupsView: View {
    @Environment(PolicyStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DetailSheet(title: "自定义策略列表") {
            Text("选择哪些策略组显示在代理首页。关闭显示不会停用该组，也不会改变分流规则。")
                .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            GlassSection("在列表中显示") {
                ForEach(allGroups, id: \.self) { name in
                    Toggle(
                        isOn: Binding(
                            get: { !store.hiddenGroups.contains(name) },
                            set: { show in if show { store.hiddenGroups.remove(name) } else { store.hiddenGroups.insert(name) } })
                    ) {
                        HStack {
                            GroupIcon(name: name, iconURL: store.proxies[name]?.icon, size: 26, groupType: store.proxies[name]?.type)
                            Text(PolicyIconCatalog.displayName(name))
                        }
                    }
                }
            } footer: {
                Text("隐藏只影响代理页的策略列表，组本身仍然生效，也仍是其他组的选项。")
            }
        }
    }

    private var allGroups: [String] {
        let order = store.proxies["GLOBAL"]?.all ?? []
        let listed = order.filter { store.proxies[$0]?.isGroup == true && store.proxies[$0]?.hidden != true }
        let remaining = store.proxies.values.filter { $0.isGroup && !$0.hidden && $0.name != "GLOBAL" && !listed.contains($0.name) }.map(\.name).sorted()
        return listed + remaining
    }
}
