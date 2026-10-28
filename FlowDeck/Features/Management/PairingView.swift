import SwiftUI

/// 配对先验证硬件指纹，再保存三路凭据。修改地址或凭据后必须重新测试。
struct PairingView: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(ManagementStore.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPushedDetail) private var isPushed
    @State private var profile = DeviceProfile(name: "随身")
    @State private var secret = ""
    @State private var webPassword = ""
    @State private var factoryPassword = ""
    @State private var verifiedInput: String?
    @State private var result = ""
    @State private var testing = false
    let device: DeviceProfile?
    let isNew: Bool

    init(device: DeviceProfile? = nil, isNew: Bool = false, backend: ManagementBackend = .webSSH) {
        self.device = device
        self.isNew = isNew
        var initial = DeviceProfile(name: backend == .ufiTools ? "F50" : "随身")
        initial.backend = backend
        initial.webPort = backend.defaultPort
        initial.mihomoPort = backend.defaultMihomoPort
        _profile = State(initialValue: initial)
    }

    private var input: String {
        "\(profile.backend.rawValue)|\(profile.host)|\(profile.mihomoPort)|\(profile.webPort)|\(profile.webUser)|\(secret)|\(webPassword)|\(factoryPassword)"
    }

    var body: some View {
        DetailNavigationContainer {
            GlassSheet {
                DeviceDetailSummary(symbol: "checkmark.shield", title: isNew ? "连接一台新设备" : "管理连接凭据", subtitle: profile.backend == .ufiTools ? "分别验证 F50 身份与 Mihomo 控制接口，连接成功后保存。" : "设备身份、代理控制、原厂管理分别验证。连接成功后点击右上角保存。")
                GlassSection("设备") {
                    Picker("管理服务", selection: $profile.backend) {
                        ForEach(ManagementBackend.allCases) { backend in
                            Text(backend.title).tag(backend)
                        }
                    }
                    .disabled(!isNew)
                    .onChange(of: profile.backend) { _, backend in
                        guard isNew else { return }
                        profile.webPort = backend.defaultPort
                        profile.mihomoPort = backend.defaultMihomoPort
                        profile.fingerprint = nil
                        webPassword = ""
                        verifiedInput = nil
                        result = ""
                    }
                    LabeledContent("名称") {
                        TextField("例如：随身、家中", text: $profile.name).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("管理地址") {
                        TextField("192.168.0.1", text: $profile.host)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                } footer: {
                    Text("先连接设备的 Wi-Fi，再验证连接。每台设备单独保存，不会覆盖其他设备。")
                }
                GlassSection("代理与管理通道") {
                    FormField("Mihomo · 代理控制") { SecureField("Secret", text: $secret).textContentType(.password) }
                    Divider()
                    FormField("\(profile.backend.title) · 设备管理") { SecureField("管理服务密码", text: $webPassword).textContentType(.password) }
                }
                GlassSection("原厂管理") {
                    FormField("网页后台密码") {
                        SecureField("可选，与 Wi-Fi 密码不同", text: $factoryPassword)
                            .textContentType(.password)
                    }
                    Text(
                        profile.backend == .ufiTools
                            ? "用于 F50 原生 Wi-Fi 管理，也可进入 Wi-Fi 页面后补充。"
                            : "用于原厂设置备份与 PIN 操作，可在日后补充。"
                    )
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                GlassSection {
                    DisclosureGroup("端口与账号") {
                        LabeledContent("Mihomo 端口") {
                            TextField("9090", value: $profile.mihomoPort, format: .number)
                                .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        }
                        LabeledContent("\(profile.backend.title) 端口") {
                            TextField("8899", value: $profile.webPort, format: .number)
                                .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        }
                        if profile.backend == .webSSH {
                            TextField("WebSSH 账号", text: $profile.webUser)
                                .textInputAutocapitalization(.never)
                        }
                    }
                }
                GlassSection {
                    Button {
                        Task { await verify() }
                    } label: {
                        HStack {
                            Text(testing ? "正在验证…" : "验证连接")
                            Spacer()
                            if testing { ProgressView() }
                            if verifiedInput == input { Image(systemName: "checkmark.circle.fill") }
                        }
                    }
                    .disabled(testing)
                    if !result.isEmpty {
                        Text(result).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("验证只读取设备身份和连接状态。密码保存在本机钥匙串。")
                }
            }
            .disabled(testing || manager.working || DeviceOperationGate.active != nil)
            .navigationBarBackButtonHidden(testing || manager.working)
            .nativeSettingsPage(title: isNew ? "添加设备" : "验证连接", inline: true)
            .toolbar {
                if !isPushed {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }.disabled(testing)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            try devices.saveVerified(profile, secret: secret, webPassword: webPassword, factoryPassword: factoryPassword)
                            dismiss()
                        } catch {
                            result = error.localizedDescription
                            verifiedInput = nil
                        }
                    }
                    .disabled(verifiedInput != input || profile.name.trimmingCharacters(in: .whitespaces).isEmpty || testing || manager.working || DeviceOperationGate.active != nil)
                }
            }
        }
        .onAppear {
            // 新增不得自动加载当前设备，否则保存会覆盖旧 ID。
            guard !isNew, let current = device ?? devices.current else { return }
            profile = current
            secret = devices.secret(for: current)
            webPassword = devices.webPassword(for: current)
            factoryPassword = devices.factoryPassword(for: current)
        }
    }

    private func verify() async {
        testing = true
        verifiedInput = nil
        defer {
            testing = false
        }
        let requestedInput = input
        do {
            guard (1...65535).contains(profile.mihomoPort), (1...65535).contains(profile.webPort),
                !profile.host.contains(where: {
                    "/?#@ ".contains($0)
                }),
                let client = devices.probeManagementClient(profile, password: webPassword),
                let proxy = devices.probeClient(host: profile.host, port: profile.mihomoPort, secret: secret)
            else {
                throw ManagementError.invalid("请检查局域网地址和端口。")
            }
            let state = try await client.snapshot()
            guard let descriptor = BackendRegistry.descriptor(for: profile.backend),
                  descriptor.accepts(state), let fingerprint = state.identityFingerprint else {
                throw ManagementError.invalid("设备型号或身份与所选管理服务不匹配。")
            }
            if let previous = profile.fingerprint, previous != fingerprint {
                throw ManagementError.invalid("此地址已变为另一台设备，请返回“我的设备”添加新设备。")
            }
            // 管理通道已确认硬件身份后，代理故障不应阻止保存与后续修复。
            var checks = ["设备身份 / \(profile.backend.title)：已验证"]
            do {
                let version = try await proxy.version()
                checks.append("Mihomo：\(version.version)")
            } catch {
                checks.append("Mihomo：连接失败，可保存后在维护中修复或编辑 Secret")
            }
            if profile.backend == .webSSH && !factoryPassword.isEmpty {
                do {
                    try await FactoryClient(host: profile.host, password: factoryPassword).login()
                    checks.append("原厂管理：认证通过")
                } catch {
                    checks.append("原厂管理：认证未通过，备份与 PIN 操作需重新验证密码")
                }
            } else if profile.backend == .ufiTools {
                if !factoryPassword.isEmpty, let ufi = client as? any UFIWifiService {
                    do {
                        _ = try await ufi.readWifiAccessPoints(password: factoryPassword)
                        checks.append("原厂 Wi-Fi：认证通过，配置可读取")
                    } catch {
                        checks.append("原厂 Wi-Fi：未通过，请在 Wi-Fi 页面核对网页后台密码")
                    }
                } else {
                    checks.append("原厂 Wi-Fi：进入 Wi-Fi 页面补充网页后台密码")
                }
            } else {
                checks.append("原厂管理：未配置密码")
            }
            guard requestedInput == input else {
                return
            }
            profile.fingerprint = fingerprint
            profile.model = state.model
            verifiedInput = input
            result = checks.joined(separator: "\n")
        } catch {
            result = error.localizedDescription
        }
    }
}
