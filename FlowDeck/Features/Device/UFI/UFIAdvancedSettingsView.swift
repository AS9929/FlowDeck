import SwiftUI

/// F50 原厂写入集中使用一次性确认与设备版本校验，避免 UI 乐观显示“已生效”。
struct UFIAdvancedSettingsView: View {
    enum Kind: String, Identifiable {
        case apn, pin, network, usb
        var id: String { rawValue }
        var title: String {
            switch self {
            case .apn: return "APN 管理"
            case .pin: return "PIN 与 PUK"
            case .network: return "网络制式"
            case .usb: return "USB 网络模式"
            }
        }
        var symbol: String {
            switch self {
            case .apn: return "network"
            case .pin: return "simcard"
            case .network: return "antenna.radiowaves.left.and.right"
            case .usb: return "cable.connector"
            }
        }
        var explanation: String {
            switch self {
            case .apn: return "保留预置配置，按运营商要求管理自定义 APN"
            case .pin: return "密码由运营商提供，错误输入会消耗解锁次数"
            case .network: return "按覆盖情况选择制式；自动模式适合日常使用"
            case .usb: return "选择电脑连接协议，切换后 USB 网络会重新连接"
            }
        }
    }

    private enum Action {
        case save(UFIAPNProfile)
        case select(UFIAPNProfile?)
        case delete(UFIAPNProfile)
        case pin
        case network(UFINetworkMode)
        case usb(String)
        var title: String {
            switch self {
            case .save: return "保存 APN"
            case .select(let profile): return profile == nil ? "恢复自动 APN" : "使用此 APN"
            case .delete: return "删除 APN"
            case .pin: return "提交 SIM 操作"
            case .network: return "切换网络制式"
            case .usb: return "切换 USB 网络模式"
            }
        }
    }

    let kind: Kind
    var restoredAPN: UFIAPNProfile? = nil
    var restoredFingerprint: String? = nil
    @State private var restoredDraftLoaded = false
    @Environment(DeviceStore.self) private var devices
    @Environment(ManagementStore.self) private var manager
    @State private var revision = 0
    @State private var password = ""
    @State private var loading = false
    @State private var credentialWarning: String?
    @State private var error: String?
    @State private var notice: String?
    @State private var apns: UFIAPNState?
    @State private var backup: UFIAPNBackup?
    @State private var draft: UFIAPNProfile?
    @State private var sim = JSONObject()
    @State private var operation = UFIPINOperation.enable
    @State private var pin = ""
    @State private var newPIN = ""
    @State private var confirmPIN = ""
    @State private var puk = ""
    @State private var action: Action?

    private var busy: Bool { loading || manager.working }
    private var writable: Bool { !busy && !devices.readOnly }

    var body: some View {
        DetailSheet(title: kind.title, closeDisabled: busy) {
            DeviceDetailSummary(
                symbol: kind.symbol, title: kind.title, subtitle: kind.explanation)
            if let credentialWarning {
                Text(credentialWarning).font(.footnote).foregroundStyle(.orange)
            }
            if let error { Text(error).foregroundStyle(.orange).font(.footnote) }
            if let notice { Label(notice, systemImage: "checkmark.circle").font(.footnote) }
            if loading { ProgressView("正在读取…") }
            if kind == .apn {
                if let draft { apnEditor(draft) } else if let apns { apnList(apns) }
            } else if kind == .network || kind == .usb {
                modeForm
            } else if sim.int("pinnumber") != nil {
                pinForm
            }
            GlassSection("原厂后台连接") {
                SecureField("原厂网页登录密码", text: $password).textContentType(.password)
                Button("验证并刷新", systemImage: "arrow.clockwise") { Task { await load() } }
                    .disabled(busy || password.isEmpty || draft != nil)
            }
            .disabled(busy)
        }
        .task(id: devices.clientRevision) {
            credentialWarning = nil
            revision = devices.clientRevision
            loading = false
            draft = nil
            apns = nil
            backup = nil
            restoredDraftLoaded = false
            sim = JSONObject()
            error = nil
            notice = nil
            clearPIN()
            action = nil
            password = devices.current.map { devices.factoryPassword(for: $0) } ?? ""
            if !password.isEmpty { await load() }
        }
        .confirmationDialog(
            action?.title ?? "确认操作",
            isPresented: Binding(
                get: { action != nil }, set: { if !$0 { action = nil } }
            ), titleVisibility: .visible
        ) {
            if let current = action {
                Button(current.title, role: .destructive) { Task { await perform(current) } }
            }
        } message: {
            switch kind {
            case .apn:
                Text("修改前保留本机加密副本。APN 保存可能进入手动模式并中断蜂窝网络，断网时可恢复自动 APN。")
            case .pin:
                Text("请核对运营商提供的 PIN/PUK。错误输入可能锁卡，本次只提交一次，不会自动重试。")
            case .network:
                Text("切换制式会重新注册蜂窝网络。当地不支持所选制式时，请切回自动模式。")
            case .usb:
                Text("USB 网络将短暂断开，请保持 Wi-Fi 管理连接。可在此页面恢复自动模式。")
            }
        }
    }

    private var modeForm: some View {
        GlassSection("可用模式") {
            if kind == .network {
                let raw = sim.string("net_select")
                DeviceParameterRow(title: "当前制式", value: raw.flatMap(UFINetworkMode.init(rawValue:))?.title ?? raw)
                ForEach(UFINetworkMode.allCases) { mode in
                    Button {
                        action = .network(mode)
                    } label: {
                        modeRow(mode.title, selected: raw == mode.rawValue)
                    }.disabled(!writable || raw == nil || raw == mode.rawValue)
                }
            } else {
                let raw = sim.string("usb_network_protocal")
                let choices = [("0", "自动"), ("1", "RNDIS · Windows"), ("2", "CDC-ECM · macOS / Linux")]
                DeviceParameterRow(title: "当前协议", value: choices.first { $0.0 == raw }?.1 ?? raw)
                ForEach(choices, id: \.0) { mode, title in
                    Button {
                        action = .usb(mode)
                    } label: {
                        modeRow(title, selected: raw == mode)
                    }.disabled(!writable || raw == nil || raw == mode)
                }
            }
        }
    }

    private func modeRow(_ title: String, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Text(title).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if selected { Image(systemName: "checkmark.circle.fill") }
        }.padding(.vertical, 6)
    }

    private func apnList(_ state: UFIAPNState) -> some View {
        VStack(spacing: 20) {
            GlassSection("选择模式") {
                DeviceParameterRow(title: "当前模式", value: state.mode == "auto" ? "自动" : "手动")
                Button("恢复自动 APN", systemImage: "arrow.uturn.backward") { action = .select(nil) }
                    .disabled(!writable || state.mode == "auto")
            }
            if let backup {
                GlassSection("修改前副本") {
                    Text(backup.date, style: .date).font(.caption).foregroundStyle(.secondary)
                    Text("原模式：" + (backup.state.mode == "auto" ? "自动" : "手动"))
                        .font(.subheadline)
                    ForEach(backup.state.profiles.filter { $0.index >= backup.state.presetCount }) { profile in
                        Button("恢复 \(profile.name) 到编辑器") {
                            let matching = state.profiles.first { $0.name == profile.name && $0.index >= state.presetCount }
                            guard let index = matching?.index ?? state.freeIndex else { return }
                            draft = UFIAPNProfile(
                                index: index, name: profile.name, protocolType: profile.protocolType,
                                ipv4: profile.ipv4, ipv6: profile.ipv6)
                        }.disabled(
                            !writable
                                || (state.freeIndex == nil
                                    && !state.profiles.contains {
                                        $0.name == profile.name && $0.index >= state.presetCount
                                    })
                        )
                    }
                    Text("副本仅保存在本机钥匙串。恢复参数后需保存并选择使用；自动模式可在上方恢复。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            GlassSection("接入点") {
                ForEach(state.profiles) { profile in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(profile.name).font(.headline)
                            Spacer()
                            if state.mode == "manual", state.currentIndex == profile.index {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                            }
                        }
                        Text([profile.apn, profile.protocolType].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary)
                        HStack(spacing: 20) {
                            Button("使用") { action = .select(profile) }
                            if profile.index >= state.presetCount {
                                Button("编辑") { draft = profile }
                                Button("删除", role: .destructive) { action = .delete(profile) }
                            } else {
                                Text("原厂预置").font(.caption).foregroundStyle(.secondary)
                            }
                        }.disabled(!writable)
                    }
                    if profile.id != state.profiles.last?.id { Divider() }
                }
                if let index = state.freeIndex {
                    Button("添加 APN", systemImage: "plus.circle") { draft = .draft(index: index) }
                        .disabled(!writable)
                }
            }
        }
    }

    private func apnEditor(_ value: UFIAPNProfile) -> some View {
        VStack(spacing: 20) {
            GlassSection("编辑接入点") {
                FormField("名称") { TextField("例如：运营商数据", text: field(\.name)) }
                Picker("IP 协议", selection: field(\.protocolType)) {
                    Text("IPv4").tag("IP")
                    Text("IPv6").tag("IPv6")
                    Text("IPv4 + IPv6").tag("IPv4v6")
                }
                if value.protocolType != "IPv6" { familyEditor(ipv6: false) }
                if value.protocolType != "IP" { familyEditor(ipv6: true) }
            }.disabled(!writable)
            HStack(spacing: 20) {
                Button("取消编辑", role: .cancel) { draft = nil }
                Spacer()
                Button("保存 APN") { if let draft { action = .save(draft) } }
            }.disabled(!writable)
        }
    }

    private func familyEditor(ipv6: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text(ipv6 ? "IPv6 参数" : "IPv4 参数").font(.headline)
            FormField("APN") { TextField("运营商提供的 APN", text: parameter(ipv6, 1)) }
            Picker("认证", selection: parameter(ipv6, 4)) {
                Text("无").tag("none")
                Text("PAP").tag("pap")
                Text("CHAP").tag("chap")
            }
            FormField("用户名") { TextField("可选", text: parameter(ipv6, 5)) }
            FormField("密码") { SecureField("可选", text: parameter(ipv6, 6)) }
            Text("现有 DNS 参数会保留，新 APN 默认自动获取。")
                .font(.caption).foregroundStyle(.secondary)
        }.textInputAutocapitalization(.never).autocorrectionDisabled()
    }

    private var pinForm: some View {
        VStack(spacing: 20) {
            GlassSection("当前状态") {
                DeviceParameterRow(title: "PIN 锁", value: sim.int("pin_status").map { $0 == 1 ? "开启" : "关闭" })
                DeviceParameterRow(title: "PIN 剩余次数", value: sim.string("pinnumber"))
                DeviceParameterRow(title: "PUK 剩余次数", value: sim.string("puknumber"))
            }
            GlassSection("操作") {
                Picker("操作类型", selection: $operation) {
                    ForEach(UFIPINOperation.allCases) { Text($0.title).tag($0) }
                }.onChange(of: operation) { clearPIN() }
                if operation == .unblock {
                    SecureField("8 位 PUK", text: $puk).keyboardType(.numberPad)
                } else {
                    SecureField("当前 PIN", text: $pin).keyboardType(.numberPad)
                }
                if operation.needsNewPIN {
                    SecureField("新 PIN", text: $newPIN).keyboardType(.numberPad)
                    SecureField("再次输入新 PIN", text: $confirmPIN).keyboardType(.numberPad)
                }
                Button(operation.title) { action = .pin }
            }.disabled(!writable)
        }
    }

    private func field(_ path: WritableKeyPath<UFIAPNProfile, String>) -> Binding<String> {
        Binding(get: { draft?[keyPath: path] ?? "" }, set: { draft?[keyPath: path] = $0 })
    }

    private func parameter(_ ipv6: Bool, _ index: Int) -> Binding<String> {
        Binding(
            get: { (ipv6 ? draft?.ipv6 : draft?.ipv4)?[index] ?? "" },
            set: { value in
                if ipv6 { draft?.ipv6[index] = value } else { draft?.ipv4[index] = value }
            })
    }

    private func clearPIN() {
        pin = ""
        newPIN = ""
        confirmPIN = ""
        puk = ""
    }

    private func api() throws -> any UFIDeviceService {
        guard revision == devices.clientRevision, let client = devices.webClient as? any UFIDeviceService else {
            throw ManagementError.deviceChanged
        }
        return client
    }

    private func load() async {
        guard !loading else { return }
        let expected = revision
        loading = true
        defer { if expected == devices.clientRevision { loading = false } }
        do {
            let client = try api()
            if kind == .apn {
                let value = try await client.readAPNs(password: password)
                guard expected == devices.clientRevision else { return }
                apns = value
                backup = try UFIAPNBackup.load(deviceID: devices.storageID)
                if !restoredDraftLoaded, let restoredAPN {
                    guard restoredFingerprint == devices.current?.fingerprint else {
                        throw ManagementError.deviceChanged
                    }
                    draft = try UFISettingsRestore.apn(restoredAPN, current: value)
                    restoredDraftLoaded = true
                    notice = "已载入新的 APN 草稿，请检查后保存；不会覆盖原有槽位。"
                }
            } else {
                let value = try await client.factoryDetails(password: password)
                guard expected == devices.clientRevision else { return }
                sim = value
            }
            credentialWarning = try DeviceServiceContext(devices, revision: expected).rememberFactoryPasswordWarning(password)
            error = nil
        } catch {
            guard expected == devices.clientRevision else { return }
            self.error = error.localizedDescription
        }
    }

    /// 捕获提交时的凭据和设备修订，任务完成后清空 PIN，失败也不自动重复消耗次数。
    private func perform(_ current: Action) async {
        guard writable else { return }
        let expected = revision
        let currentPassword = password
        let currentPIN = pin
        let nextPIN = newPIN
        let currentPUK = puk
        let pinOperation = operation
        let state = apns
        action = nil
        notice = nil
        error = nil
        if case .pin = current, pinOperation.needsNewPIN, nextPIN != confirmPIN {
            error = "两次新 PIN 不一致。"
            return
        }
        await manager.run("F50 " + current.title) {
            let client = try await manager.verifiedService(
                (any UFIFactoryService).self, devices: devices, revision: expected, capability: .factoryControl)
            switch current {
            case .save(let profile):
                guard let state else { throw ManagementError.invalid("请先读取 APN。") }
                try UFIAPNBackup(state: state, date: Date()).save(deviceID: devices.storageID)
                try await client.saveAPN(profile, replacing: state, password: currentPassword)
            case .select(let profile):
                guard let state else { throw ManagementError.invalid("请先读取 APN。") }
                try UFIAPNBackup(state: state, date: Date()).save(deviceID: devices.storageID)
                try await client.selectAPN(profile, from: state, password: currentPassword)
            case .delete(let profile):
                guard let state else { throw ManagementError.invalid("请先读取 APN。") }
                try UFIAPNBackup(state: state, date: Date()).save(deviceID: devices.storageID)
                try await client.deleteAPN(profile, from: state, password: currentPassword)
            case .network(let mode):
                try await client.setNetworkMode(mode, password: currentPassword)
            case .usb(let mode):
                try await client.setUSBProtocol(mode, password: currentPassword)
            case .pin:
                try await client.operatePIN(pinOperation, pin: currentPIN, newPIN: nextPIN, puk: currentPUK, password: currentPassword)
            }
        }
        guard expected == devices.clientRevision else { return }
        clearPIN()
        let failure = manager.error
        if failure == nil { draft = nil }
        await load()
        error = failure ?? error
        if error == nil { notice = "操作完成，已重新读取设备状态" }
    }
}
