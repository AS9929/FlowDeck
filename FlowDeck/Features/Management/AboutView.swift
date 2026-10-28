import SwiftUI

/// 产品品牌与信息页；版本属于 App，路由器上的服务版本在更新管理中查看。
struct AboutView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var page: Page?

    private enum Page: String, Identifiable {
        case changes = "本版更新"
        case compatibility = "设备兼容"
        case privacy = "数据与隐私"
        case licenses = "第三方许可"
        var id: String { rawValue }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "—") · Build \(info["CFBundleVersion"] as? String ?? "—")"
    }

    var body: some View {
        DetailSheet(title: "关于") {
            let layout =
                typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 20))
            layout {
                AppBrandIcon(size: 80)
                VStack(alignment: .leading, spacing: 5) {
                    Text(AppBrand.name).font(.largeTitle.weight(.semibold))
                    Text(AppBrand.englishName).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    Text(version).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 20)

            VStack(alignment: .leading, spacing: 8) {
                Text("设备与代理，一处掌握。").font(.title3.weight(.medium))
                Text("连接随身网络，掌握设备状态，让每一次分流与切换都清晰可见。")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 12)

            GlassSection("产品信息") {
                entry(.changes, symbol: "sparkles", subtitle: "浏览这一版的变化")
                Divider()
                entry(.compatibility, symbol: "wifi.router", subtitle: "支持的设备与连接能力")
            }
            GlassSection("隐私与许可") {
                entry(.privacy, symbol: "lock.shield", subtitle: "连接凭据与本机数据")
                Divider()
                entry(.licenses, symbol: "doc.text", subtitle: "开源项目、作者与许可原文")
            }
            VStack(spacing: 6) {
                Text("为随身网络而设计").font(.caption.weight(.medium))
                Text("独立开发，与中兴及相关开源项目没有隶属关系。")
                    .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
        .appPush(item: $page) { selected in
            if selected == .licenses {
                ThirdPartyLicensesView()
            } else {
                DetailSheet(title: selected.rawValue) {
                    switch selected {
                    case .changes:
                        GlassSection("0.4.0 · 体验改进") {
                            Label("详情页使用层级导航", systemImage: "chevron.right")
                            Label("独立的大文本配置编辑器", systemImage: "doc.text")
                            Label("策略预览恢复玻璃与展开动效", systemImage: "rectangle.expand.vertical")
                            Label("重做首页与设备详情层级", systemImage: "square.grid.2x2")
                            Label("订阅健康检查与代理缓存管理", systemImage: "waveform.path.ecg")
                            Label("Wi-Fi 性能、短信转发与命令工具", systemImage: "wrench.and.screwdriver")
                        }
                    case .compatibility:
                        GlassSection("连接能力") {
                            DeviceParameterRow(title: "代理管理", value: "Mihomo API")
                            DeviceParameterRow(title: "管理服务", value: "WebSSH")
                            Text("安装相同组件并不代表原厂接口一致。App 根据已验证的接口能力提供操作。")
                                .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                        }
                        GlassSection("已适配原厂接口") {
                            DeviceParameterRow(title: "设备型号", value: "MU5250 · 中兴 U60 Pro")
                            DeviceParameterRow(title: "固件", value: "B28")
                            Text("其他机型或固件需逐项验证，未适配的写入保持不可用。")
                                .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                        }
                    case .privacy:
                        GlassSection("本机保存") {
                            Label("密码和 Secret 保存在钥匙串", systemImage: "key")
                            Label("小组件仅共享最近一次状态摘要", systemImage: "square.grid.2x2")
                            Text("小组件摘要不包含密码和 IMEI。原厂备份可能含凭据，只有选择保存或分享后才导出。")
                                .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                        }
                    case .licenses: EmptyView()
                    }
                }
            }
        }
    }

    private func entry(_ page: Page, symbol: String, subtitle: String) -> some View {
        Button {
            self.page = page
        } label: {
            SettingsRow(page.rawValue, symbol: symbol, subtitle: subtitle)
        }
    }
}

/// 分别说明随包图标与适配的设备端服务；服务本体不随 App 分发。
struct ThirdPartyLicensesView: View {
    private struct License: Identifiable {
        let id: String
        let title: String
        let detail: String
        let url: String
    }

    private let licenses = [
        License(id: "SimpleIcons", title: "Simple Icons", detail: "16.34.0 · CC0-1.0", url: "https://github.com/simple-icons/simple-icons"),
        License(id: "LobeIcons", title: "Lobe Icons", detail: "1.95.1 · MIT", url: "https://github.com/lobehub/lobe-icons"),
        License(id: "WebSSHLicense", title: "WebSSH-u60pro", detail: "MIT · 设备端管理服务", url: "https://github.com/Jack-bin183/WebSSH-u60pro"),
        License(id: "MihomoLicense", title: "Mihomo", detail: "GPL-3.0 · 设备端代理核心", url: "https://github.com/MetaCubeX/mihomo/tree/v1.19.32"),
        License(id: "UFIToolsLicense", title: "UFI-TOOLS", detail: "MIT · 设备端管理服务", url: "https://github.com/kanoqwq/UFI-TOOLS"),
        License(id: "OfflineResources", title: "资源分发说明", detail: "本地资源与设备端服务的边界", url: "https://github.com/AS9929/FlowDeck"),
        License(id: "FlagIcons", title: "flag-icons", detail: "7.5.0 · MIT", url: "https://github.com/lipis/flag-icons"),
    ]

    var body: some View {
        DetailSheet(title: "第三方许可") {
            Text("感谢开源作者与贡献者。以下列出随包图标资源及适配的设备端服务。设备端服务本体不随 App 分发，名称与商标归各自所有者。")
                .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            GlassSection("资源与组件") {
                ForEach(licenses) { license in
                    NavigationLink {
                        DetailSheet(title: license.title) {
                            Link("项目主页", destination: URL(string: license.url)!)
                            Text(licenseText(license.id))
                                .font(.footnote.weight(.medium))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .appDetailDestination()
                    } label: {
                        SettingsRow(license.title, symbol: "doc.plaintext", subtitle: license.detail)
                    }
                    if license.id != licenses.last?.id { Divider() }
                }
            }
            Text("品牌轮廓采用统一单色渲染，地区保留原始国旗颜色。尺寸、底座及名称匹配由 App 实现。")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
    }

    private func licenseText(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "无法读取许可文件。" }
        return text
    }
}
