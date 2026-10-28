import CoreImage.CIFilterBuiltins
import SwiftUI

/// 双频 Wi-Fi 原生编辑器。保存后保留页面和旧值；连接中断不会当成保存成功。
struct WifiEditorView: View {
    @State private var boundRevision: Int?
    @Environment(DeviceStore.self) private var devices
    @Environment(DeviceStatusStore.self) private var status
    @Environment(ManagementStore.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @State private var networks: [WifiNetwork] = []
    @State private var previous: [WifiNetwork] = []
    @State private var pending = false
    @State private var confirm = false
    @State private var error: String?
    @State private var sharing: WifiNetwork?

    var body: some View {
        DetailSheet(
            title: "Wi-Fi",
            closeDisabled: manager.working,
            primaryTitle: "保存",
            primaryDisabled: networks.isEmpty || networks == previous || manager.working || pending,
            onPrimary: { confirm = true }
        ) {
            DeviceDetailSummary(symbol: "wifi", title: "管理无线网络", subtitle: "分别设置双频网络。修改名称或密码后可能需要重新连接，再回读确认。")
            if manager.operationTitle == "保存 Wi-Fi 配置" { ManagementProgress() }
            if let error {
                Text(error).font(.footnote.weight(.medium)).foregroundStyle(.orange)
            }
            if pending {
                GlassSection("等待重新连接") {
                    Text("若 Wi-Fi 已断开，请在 iPhone 设置中连接新名称，再回来检查。未确认前保留旧值供恢复。")
                    Button("已连接，检查新配置") {
                        Task {
                            await check()
                        }
                    }.disabled(manager.working)
                    Button("恢复旧配置") {
                        Task {
                            await save(previous)
                        }
                    }.disabled(manager.working)
                }
            }
            ForEach($networks) { $network in
                GlassSection(network.title) {
                    HStack {
                        Image(systemName: "wifi").foregroundStyle(Color.accentColor)
                        Text(network.title).font(.headline)
                        Spacer()
                        Text(network.enabled ? "开启" : "关闭").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                    Divider()
                    Toggle("开启此频段", isOn: $network.enabled)
                    FormField("网络名称") { TextField("网络名称", text: $network.ssid) }.textInputAutocapitalization(.never).autocorrectionDisabled()
                    FormField("Wi-Fi 密码") { SecureField("Wi-Fi 密码", text: $network.password) }
                    Divider()
                    Toggle("隐藏网络名称", isOn: $network.hidden)
                    LabeledContent("信道") {
                        Picker("信道", selection: $network.channel) {
                            Text("自动").tag("auto")
                            ForEach(network.id == "main_2g" ? Array(1...13) : [36, 40, 44, 48, 149, 153, 157, 161, 165], id: \.self) {
                                Text(String($0)).tag(String($0))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }.disabled(manager.working || pending)
            }
            GlassSection("分享网络") {
                ForEach(previous.filter(\.enabled)) { network in
                    Button {
                        sharing = network
                    } label: {
                        SettingsRow(network.ssid, symbol: "qrcode", subtitle: network.title)
                    }
                }
            } footer: {
                Text("二维码使用设备已保存的配置，不包含尚未应用的草稿。")
            }
            GlassSection {
                Button("重新读取", systemImage: "arrow.clockwise") {
                    Task {
                        await load()
                    }
                }.disabled(manager.working || pending)
            }
            WifiPowerSection().disabled(pending || manager.working)
        }
        .appModal(item: $sharing) { network in WifiShareView(network: network) }
        .interactiveDismissDisabled(pending || manager.working)
        .onAppear { if boundRevision == nil { boundRevision = devices.clientRevision } }
        .task {
            await load()
        }
        .confirmationDialog("修改 Wi-Fi 可能断开所有无线客户端", isPresented: $confirm, titleVisibility: .visible) {
            Button("确认保存") {
                Task {
                    await save(networks)
                }
            }
        }
    }

    private func load() async {
        do {
            if let recovery = try WifiRecovery.load(devices.storageID) {
                previous = recovery.before
                networks = recovery.requested
                pending = true
                return
            }
            networks = try await devices.webClient.readWifiNetworks()
            previous = networks
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func save(_ values: [WifiNetwork]) async {
        await manager.run("保存 Wi-Fi 配置") {
            guard boundRevision == devices.clientRevision else { throw ManagementError.deviceChanged }
            let api = try await manager.verifiedAPI(devices)
            for value in values {
                try value.validate()
            }
            try WifiRecovery(deviceID: devices.storageID, before: previous, requested: values).save()
            pending = true
            do { try await api.saveWifiNetworks(values) } catch {
                self.error = "保存结果尚未确认：\(error.localizedDescription)"
            }
            networks = values
            await check()
            if pending { throw ManagementError.unconfirmed(error ?? "Wi-Fi 保存尚未确认，等待重新连接。") }
        }
    }

    private func check() async {
        do {
            guard boundRevision == devices.clientRevision else { throw ManagementError.deviceChanged }
            let api = try await manager.verifiedAPI(devices)
            let actual = try await api.readWifiNetworks()
            guard actual == networks else {
                throw ManagementError.unconfirmed("回读与目标不一致，仍保留旧配置。")
            }
            try WifiRecovery.clear(devices.storageID)
            previous = actual
            pending = false
            error = nil
            await status.refreshSnapshot()
            await manager.setStage("Wi-Fi 已回读确认", progress: 1)
        } catch {
            self.error = "尚未确认：\(error.localizedDescription)"
        }
    }
}

struct WifiPowerSection: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(DeviceStatusStore.self) private var status
    @State private var draft: [String: WifiRadioSettings] = [:]
    @State private var confirm = false
    @State private var boundRevision: Int?
    var body: some View {
        GlassSection("发射功率") {
            ForEach(["wifi0", "wifi1"], id: \.self) { key in
                if draft[key] != nil {
                    LabeledContent(key == "wifi0" ? "2.4 GHz" : "5 GHz") {
                        Picker("发射功率", selection: Binding(get: { draft[key]?.txPower ?? "100" }, set: { draft[key]?.txPower = $0 })) {
                            Text("40%").tag("40")
                            Text("80%").tag("80")
                            Text("100%").tag("100")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
            }
            Button("应用发射功率", systemImage: "antenna.radiowaves.left.and.right") {
                confirm = true
            }.disabled(draft.isEmpty || draft == status.wifi || boundRevision != devices.clientRevision)
        }
        .confirmationDialog("调整发射功率可能改变 Wi-Fi 覆盖范围", isPresented: $confirm, titleVisibility: .visible) {
            Button("应用") {
                Task {
                    guard boundRevision == devices.clientRevision else {
                        status.notice = "设备连接已变化，请重新打开此页面。"
                        return
                    }
                    await status.setWifi(draft)
                }
            }
        }
        .task {
            boundRevision = devices.clientRevision
            await status.loadWifi()
            draft = status.wifi
        }
    }
}

/// 本地生成扫码入网图，不上传 Wi-Fi 密码，不写入相册。
struct WifiShareView: View {
    let network: WifiNetwork
    @State private var image: UIImage?

    var body: some View {
        DetailSheet(title: "分享 Wi-Fi") {
            GlassSection {
                Text(network.ssid).font(.title3.weight(.semibold))
                Text(network.title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                if let image {
                    Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                        .frame(maxWidth: 260).padding(16).background(.white, in: RoundedRectangle(cornerRadius: 16))
                        .frame(maxWidth: .infinity).accessibilityLabel("Wi-Fi 入网二维码")
                    ShareLink(item: Image(uiImage: image), preview: SharePreview("Wi-Fi · " + network.ssid, image: Image(uiImage: image))) {
                        Label("分享二维码", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Text("无法生成二维码").foregroundStyle(.secondary)
                }
            } footer: {
                Text("二维码包含 Wi-Fi 密码，只分享给允许接入此网络的人。部分扫码器可能不支持 WPA3 网络。")
            }
        }
        .task {
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(Self.payload(network).utf8)
            guard let output = filter.outputImage,
                let cgImage = CIContext().createCGImage(
                    output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), from: output.extent.applying(CGAffineTransform(scaleX: 8, y: 8)))
            else { return }
            image = UIImage(cgImage: cgImage)
        }
    }

    static func payload(_ network: WifiNetwork) -> String {
        func escape(_ value: String) -> String {
            value.reduce(into: "") { result, character in
                if ["\\", ";", ",", ":", "\""].contains(String(character)) { result += "\\" }
                result.append(character)
            }
        }
        return "WIFI:T:WPA;S:\(escape(network.ssid));P:\(escape(network.password));H:\(network.hidden ? "true" : "false");;"
    }
}
