import SwiftUI
import UniformTypeIdentifiers

/// 代理配置的唯一入口；复用已验证的导入、检查和回滚流程。
struct ProxyConfigurationView: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(DeviceStatusStore.self) private var status
    @Environment(AppRouter.self) private var router
    @State private var picking = false
    @State private var pickKind: PickKind = .yaml
    @State private var surgeImport: ImportedConfig?
    @State private var importing: ImportedConfig?
    @State private var checkResult: ConfigCheckResult?
    @State private var editing = false
    @State private var cache = false
    @State private var applied: ConfigRevision?
    @Environment(PolicyStore.self) private var policy

    enum PickKind { case yaml, surge }

    struct ImportedConfig: Identifiable {
        let id = UUID()
        let name: String
        let content: String
    }

    var body: some View {
        standardContent
    }

    private var standardContent: some View {
        GlassSheet {
            GlassSection("核心与网络") {
                DestinationRow("运行设置", symbol: "slider.horizontal.3", subtitle: "模式、IPv6、嗅探、并发与日志级别", destination: .runtime)
                DestinationRow("代理服务", symbol: "power", subtitle: "启动、停用与重启", destination: .service)
                DestinationRow("核心更新", symbol: "shippingbox", subtitle: "Mihomo 版本、安装与回滚", destination: .updates)
                DestinationRow("DNS 查询", symbol: "network", subtitle: "查看设备的域名解析结果", destination: .dns)
                Button {
                    cache = true
                } label: {
                    SettingsRow("缓存管理", symbol: "arrow.triangle.2.circlepath", subtitle: "清理 DNS 与 Fake-IP 映射")
                }
            }
            GlassSection("规则与分流") {
                DestinationRow("规则集", symbol: "arrow.triangle.2.circlepath", subtitle: "在线规则集的条数、更新时间与立即更新", destination: .providers)
                DestinationRow("分流规则", symbol: "list.bullet.rectangle", subtitle: "搜索规则及其目标策略", destination: .rules)
                if !devices.usesUFI {
                    DestinationRow("规则数据库", symbol: "externaldrive", subtitle: "GeoSite、GeoIP 与 IP 段更新", destination: .ruleData)
                }
            }
            GlassSection("当前配置") {
                Button {
                    editing = true
                } label: {
                    SettingsRow("查看与编辑配置", symbol: "doc.text", subtitle: applied?.sourceName ?? "设备 config.yaml")
                }
                if let applied, applied.sourceName != nil {
                    LabeledContent("本机应用记录", value: applied.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption.weight(.medium))
                }
                LabeledContent("运行中的策略组", value: "\(policy.proxies.values.filter(\.isGroup).count) 个")
                    .font(.caption.weight(.medium))
                Text("运行设置只改变当前核心；此处编辑并应用 config.yaml 后可跨重启保留。")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Button {
                    Task { checkResult = await status.checkCurrentConfig() }
                } label: {
                    Label("检查当前配置", systemImage: "checkmark.seal")
                }
                .disabled(status.busy != nil)
            }
            configSection
            if devices.usesUFI {
                GlassSection("设备适配") {
                    Text("配置通过加密会话读取和提交。F50 的透明代理、DNS 和管理连接参数需保持不变；节点、策略组与规则可编辑。")
                        .font(.footnote).foregroundStyle(.secondary)
                    UFIWebLinks()
                }
            }
            GlassSection("版本管理") {
                Button {
                    router.sheet = .history
                } label: {
                    SettingsRow("配置历史", symbol: "clock.arrow.circlepath", subtitle: "保存快照、恢复之前的配置")
                }
            }
        }
        .task(id: devices.clientRevision) {
            // 只将摘要相同的历史记录关联为本机来源，外部更改不会沿用旧文件名。
            if !devices.usesUFI, let content = try? await status.deviceConfig(),
                let history = try? ConfigHistory.list(deviceID: devices.storageID)
            {
                applied = history.first { $0.checksum == DeviceIdentity.digest(Data(content.utf8)) }
            }
        }
        .appPush(isPresented: $cache) { ProxyCacheView() }
        .appPush(isPresented: $editing) { ConfigurationEditorView() }
        .appModal(item: $importing) { cfg in ConfigImportView(name: cfg.name, content: cfg.content) }
        .appModal(item: $surgeImport) { cfg in SurgeImportView(name: cfg.name, text: cfg.content) }
        .appPush(value: $checkResult) { result in
            ConfigCheckView(result: result)
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [UTType(filenameExtension: "conf") ?? .data, .yaml, .plainText, .data]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let cfg = ImportedConfig(name: url.lastPathComponent, content: text)
                if pickKind == .surge { surgeImport = cfg } else { importing = cfg }
            } else {
                status.notice = "读不出这个文件，请确认是 UTF-8 文本"
            }
        }
    }
    private var configSection: some View {
        GlassSection {
            Button {
                pickKind = .surge
                picking = true
            } label: {
                Label {
                    VStack(alignment: .leading) {
                        Text("从 Surge 配置导入")
                        Text("选手机上的 .conf，在 App 里转换").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "arrow.triangle.branch")
                }
            }
            Button {
                pickKind = .yaml
                picking = true
            } label: {
                Label("导入 Mihomo YAML", systemImage: "square.and.arrow.down")
            }
        } header: {
            Text("导入配置")
        } footer: {
            Text("导入时先保存当前版本、写入新配置并检查；检查不通过会自动写回旧版本，通过后才重启代理核心。")
        }
        .disabled(status.busy != nil)
    }

}

/// 规则数据库与分流规则统一归属 Mihomo，更新仍复用已验证的设备流程。
struct RuleDataView: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(DeviceStatusStore.self) private var status
    var body: some View {
        DetailSheet(title: "规则数据库") {
            dataSection
        }
    }
    @ViewBuilder
    private var dataSection: some View {
        GlassSection {
            LabeledContent("本地版本", value: status.dataVersion?.local ?? "—")
            LabeledContent("最新版本", value: status.dataVersion?.remote ?? "—")
            if let d = status.dataStatus, d.isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(d.percent), total: 100)
                    Text("\(d.fileName ?? "") \(d.fileIndex)/\(d.fileTotal) · \(d.percent)%").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
            } else {
                Button {
                    Task { await status.updateData() }
                } label: {
                    Label("更新规则数据", systemImage: "arrow.down.circle")
                }
            }
        } header: {
            Text("规则数据")
        } footer: {
            Text("GeoSite、GeoIP 和中国 IP 段，设备经镜像下载，约 18 MB。完成后会自动重新加载 IP 段。")
        }
        .task(id: devices.clientRevision) { await status.loadDataVersion() }
    }
}
