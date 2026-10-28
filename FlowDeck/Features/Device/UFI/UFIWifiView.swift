import SwiftUI

/// F50 原生双频编辑。每次仅提交一个接入点，网络中断后通过 Keychain 恢复记录继续核验。
struct UFIWifiView: View {
    var restoredPoint: UFIWifiAccessPoint? = nil
    var restoredFingerprint: String? = nil
    @State private var restoredDraftLoaded = false
    @State private var requestedBands: Set<String>?
    @Environment(DeviceStore.self) private var devices
    @Environment(ManagementStore.self) private var manager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var points: [UFIWifiAccessPoint] = []
    @State private var draft: UFIWifiAccessPoint?
    @State private var selectedID = ""
    @State private var factoryPassword = ""
    @State private var revision: Int?
    @State private var loading = false
    @State private var credentialWarning: String?
    @State private var error: String?
    @State private var notice: String?
    @State private var recovery: UFIWifiRecovery?
    @State private var confirmSave = false
    @State private var confirmRestore = false
    @State private var sharing: WifiNetwork?

    private var busy: Bool { loading || manager.working }
    private var original: UFIWifiAccessPoint? { points.first { $0.id == selectedID } }
    private var canSave: Bool {
        draft != nil && original != nil && draft != original && recovery == nil && !busy && !devices.readOnly
    }

    var body: some View {
        DetailSheet(
            title: "Wi-Fi", closeDisabled: busy, primaryTitle: "保存",
            primaryDisabled: !canSave, onPrimary: { confirmSave = true }
        ) {
            DeviceDetailSummary(
                symbol: "wifi", title: "无线网络",
                subtitle: "分别管理 2.4 GHz 与 5 GHz，修改后回读确认。")
            if loading { ProgressView("正在读取 Wi-Fi…").frame(maxWidth: .infinity) }
            if manager.working && manager.operationTitle == "保存 F50 Wi-Fi" { ManagementProgress() }
            if let credentialWarning {
                Text(credentialWarning).font(.footnote).foregroundStyle(.orange)
            }
            if let error { Text(error).font(.footnote.weight(.medium)).foregroundStyle(.orange) }
            if let notice { Label(notice, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.secondary) }
            if devices.readOnly {
                Label("只读模式 · 可查看与分享，暂不允许修改", systemImage: "lock.shield")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if recovery != nil { recoverySection }
            if !points.isEmpty { networkSection }
            if points.count == 2 && recovery == nil { bandSection }
            credentialsSection
        }
        .task(id: devices.clientRevision) {
            credentialWarning = nil
            revision = devices.clientRevision
            loading = false
            points = []
            draft = nil
            selectedID = ""
            error = nil
            notice = nil
            recovery = nil
            requestedBands = nil
            restoredDraftLoaded = false
            factoryPassword = devices.current.map { devices.factoryPassword(for: $0) } ?? ""
            do { recovery = try UFIWifiRecovery.load(devices.storageID) } catch { self.error = error.localizedDescription }
            if !factoryPassword.isEmpty { await load() }
        }
        .appModal(item: $sharing) { WifiShareView(network: $0) }
        .confirmationDialog("保存后可能暂时断开 Wi-Fi", isPresented: $confirmSave, titleVisibility: .visible) {
            Button("保存当前频段") {
                if let draft, let original { Task { await save(draft, replacing: original) } }
            }
        } message: {
            Text("请记住新的名称和密码；断线后在系统设置重新连接，再返回确认。其他频段保持原设置。")
        }
        .confirmationDialog("恢复修改前的 Wi-Fi 配置？", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("恢复旧配置") { Task { await restore() } }
        }
        .confirmationDialog(
            "切换频段可能断开热点",
            isPresented: Binding(
                get: { requestedBands != nil }, set: { if !$0 { requestedBands = nil } }
            ), titleVisibility: .visible
        ) {
            if let bands = requestedBands {
                Button("切换并重新读取") { Task { await changeBands(bands) } }
            }
        } message: {
            Text("至少保留一个频段。若连接中断，请在系统设置连接仍开启的热点，再返回刷新。")
        }
    }

    @ViewBuilder private var networkSection: some View {
        if points.count > 1 {
            Picker("频段", selection: $selectedID) {
                ForEach(points) { Text($0.title).tag($0.id) }
            }
            .pickerStyle(.segmented)
            .disabled(busy || recovery != nil || draft != original)
            .onChange(of: selectedID) { _, id in
                if draft?.id != id { draft = points.first { $0.id == id } }
            }
        }
        if let value = draft {
            GlassSection {
                HStack(spacing: 12) {
                    FeatureIcon(symbol: "wifi")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(value.title).font(.headline)
                        Text(value.enabled ? "频段已开启" : "频段已关闭")
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: value.enabled ? "checkmark.circle.fill" : "minus.circle")
                        .foregroundStyle(value.enabled ? Color.accentColor : .secondary)
                }
                Divider()
                FormField("网络名称") {
                    TextField("1–32 字节", text: binding(\.ssid, default: ""))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                FormField("Wi-Fi 密码") {
                    SecureField("8–63 位字母、数字或符号", text: binding(\.password, default: ""))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Divider()
                Toggle("隐藏网络名称", isOn: binding(\.hidden, default: false))
                LabeledContent("接入上限") {
                    Picker("接入上限", selection: binding(\.maxClients, default: 10)) {
                        ForEach(1...10, id: \.self) { Text("\($0) 台").tag($0) }
                    }.labelsHidden().pickerStyle(.menu)
                }
                Picker("安全方式", selection: binding(\.authMode, default: "WPA2PSK")) {
                    Text("WPA2 Personal").tag("WPA2PSK")
                    Text("WPA3 Personal").tag("WPA3PSK")
                    Text("WPA2 / WPA3").tag("WPA2PSKWPA3PSK")
                    if value.authMode == "WPAPSKWPA2PSK" { Text("WPA / WPA2").tag("WPAPSKWPA2PSK") }
                }
                if value.isolation != nil {
                    Toggle(
                        "隔离热点内的接入设备",
                        isOn: Binding(
                            get: { draft?.isolation == "1" }, set: { draft?.isolation = $0 ? "1" : "0" }))
                }
            }
            .disabled(busy || recovery != nil || devices.readOnly)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: selectedID)
            if let original, original.enabled,
                ["WPA2PSK", "WPAPSKWPA2PSK", "WPA2PSKWPA3PSK"].contains(original.authMode)
            {
                GlassSection {
                    Button {
                        sharing = original.sharingNetwork
                    } label: {
                        SettingsRow("分享此网络", symbol: "qrcode", subtitle: "使用已保存的名称与密码")
                    }.disabled(busy || recovery != nil)
                }
            }
            if draft != original && recovery == nil {
                Button("撤销未保存的修改", systemImage: "arrow.uturn.backward") { draft = original }
                    .disabled(busy)
            }
        }
    }

    private var bandSection: some View {
        GlassSection("频段开关") {
            ForEach(points) { point in
                Toggle(
                    point.title,
                    isOn: Binding(
                        get: { point.enabled },
                        set: { enabled in
                            var chips = Set(points.filter(\.enabled).map(\.chip))
                            if enabled { chips.insert(point.chip) } else { chips.remove(point.chip) }
                            if chips.isEmpty {
                                error = "至少保留一个频段，避免手机失去管理连接。"
                            } else {
                                requestedBands = chips
                            }
                        }))
            }
        } footer: {
            Text("频段开关独立提交；请先保存或撤销上方未保存的修改。")
        }
        .disabled(busy || devices.readOnly || draft != original)
    }

    private func changeBands(_ bands: Set<String>) async {
        let expectedRevision = revision
        let originalPoints = points
        let password = factoryPassword
        requestedBands = nil
        error = nil
        notice = nil
        await manager.run("切换 F50 Wi-Fi 频段") {
            _ = try await manager.verifiedAPI(devices, capability: .wifi)
            guard expectedRevision == devices.clientRevision else { throw ManagementError.deviceChanged }
            try await client().setWifiBands(bands, replacing: originalPoints, password: password)
        }
        guard expectedRevision == devices.clientRevision else { return }
        if let failure = manager.error { error = failure } else { await load() }
    }

    private var credentialsSection: some View {
        GlassSection(points.isEmpty ? "验证原厂后台" : "原厂后台连接") {
            FormField("网页后台密码") {
                SecureField("192.168.0.1 的登录密码", text: $factoryPassword).textContentType(.password)
            }
            Button {
                Task { await load() }
            } label: {
                Label(points.isEmpty ? "验证并读取 Wi-Fi" : "重新读取配置", systemImage: "arrow.clockwise")
            }
            .disabled(busy || factoryPassword.isEmpty || (recovery == nil && draft != original))
        } footer: {
            Text("使用原厂网页登录密码，与 UFI 管理口令、Wi-Fi 密码不同。验证成功后保存在本机钥匙串。")
        }
        .disabled(busy)
    }

    private var recoverySection: some View {
        GlassSection("等待确认") {
            Label("已保留修改前的配置", systemImage: "clock.arrow.circlepath").font(.headline)
            Text("若连接已断开，请先连接新的 Wi-Fi，再检查结果。没有回读到目标配置前，不会显示保存成功。")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("已重新连接，检查结果", systemImage: "arrow.clockwise") { Task { await load() } }
                .disabled(busy || factoryPassword.isEmpty)
            Button("恢复修改前的配置", systemImage: "arrow.uturn.backward") { confirmRestore = true }
                .disabled(busy || devices.readOnly || factoryPassword.isEmpty)
        }
    }

    private func binding<Value>(_ path: WritableKeyPath<UFIWifiAccessPoint, Value>, default fallback: Value) -> Binding<Value> {
        Binding(get: { draft?[keyPath: path] ?? fallback }, set: { draft?[keyPath: path] = $0 })
    }

    private func client() throws -> any UFIWifiService {
        guard revision == devices.clientRevision, let client = devices.webClient as? any UFIWifiService else {
            throw ManagementError.deviceChanged
        }
        return client
    }

    /// 读取失败保持草稿和恢复记录；设备切换后的旧请求不更新新页面。
    private func load() async {
        guard !loading else { return }
        let requestedRevision = devices.clientRevision
        loading = true
        defer { if requestedRevision == devices.clientRevision { loading = false } }
        do {
            let actual = try await client().readWifiAccessPoints(password: factoryPassword)
            guard requestedRevision == devices.clientRevision else { return }
            credentialWarning = try DeviceServiceContext(devices, revision: requestedRevision).rememberFactoryPasswordWarning(factoryPassword)
            points = actual
            error = nil
            if let recovery {
                let point = actual.first { $0.id == recovery.requested.id }
                if point == recovery.requested {
                    try UFIWifiRecovery.clear(devices.storageID)
                    notice = "Wi-Fi 配置已回读确认"
                    self.recovery = nil
                } else {
                    error =
                        point == recovery.before
                        ? "设备暂时仍返回旧配置，请稍后检查；也可点击恢复以确认保留旧配置。"
                        : "回读结果与目标配置不一致，已保留旧配置供检查与恢复。"
                }
                selectedID = recovery.requested.id
            }
            if !actual.contains(where: { $0.id == selectedID }) {
                selectedID = actual.first(where: \.enabled)?.id ?? actual.first?.id ?? ""
            }
            draft = actual.first { $0.id == selectedID }
            if !restoredDraftLoaded, recovery == nil, let restoredPoint {
                guard restoredFingerprint == devices.current?.fingerprint,
                    let current = actual.first(where: { $0.id == restoredPoint.id })
                else {
                    throw ManagementError.deviceChanged
                }
                let target = try UFISettingsRestore.wifi(restoredPoint, current: current)
                selectedID = target.id
                draft = target
                restoredDraftLoaded = true
                notice = "已载入恢复包草稿，请检查后点击保存。频段开关保持当前状态。"
            }
        } catch {
            guard requestedRevision == devices.clientRevision else { return }
            self.error = error.localizedDescription
        }
    }

    private func save(_ target: UFIWifiAccessPoint, replacing original: UFIWifiAccessPoint) async {
        await manager.run("保存 F50 Wi-Fi") {
            let api = try client()
            try target.validate()
            _ = try await manager.verifiedAPI(devices, capability: .wifi)
            guard revision == devices.clientRevision else { throw ManagementError.deviceChanged }
            let record = UFIWifiRecovery(deviceID: devices.storageID, before: original, requested: target)
            try record.save()
            recovery = record
            notice = nil
            do {
                try await api.saveWifiAccessPoint(target, replacing: original, password: factoryPassword)
                // 原厂异步重载需要时间；仅回读，不因断线自动重发修改请求。
                try await Task.sleep(for: .seconds(2))
                await load()
            } catch {
                self.error = "保存结果尚未确认：" + error.localizedDescription
            }
            if recovery != nil { throw ManagementError.unconfirmed("请重新连接 Wi-Fi 后检查保存结果。") }
        }
        if let failure = manager.error, notice == nil, error == nil { error = failure }
    }

    private func restore() async {
        guard !busy, let record = recovery else { return }
        let requestedRevision = devices.clientRevision
        loading = true
        defer { if requestedRevision == devices.clientRevision { loading = false } }
        do {
            let actual = try await client().readWifiAccessPoints(password: factoryPassword)
            guard requestedRevision == devices.clientRevision else { return }
            guard let current = actual.first(where: { $0.id == record.before.id }) else { throw ManagementError.deviceChanged }
            if current == record.before {
                try UFIWifiRecovery.clear(devices.storageID)
                recovery = nil
                loading = false
                await load()
                notice = "已确认保留修改前的 Wi-Fi 配置"
                return
            }
            guard current == record.requested else {
                throw ManagementError.unconfirmed("设备配置已发生其他变化，停止自动恢复以避免覆盖。请在原厂网页核对。")
            }
            loading = false
            await save(record.before, replacing: current)
        } catch { self.error = error.localizedDescription }
    }
}
