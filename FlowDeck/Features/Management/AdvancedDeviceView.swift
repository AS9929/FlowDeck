import SwiftUI

/// SIM 与设备设置均从原厂接口回读；界面草稿不会直接驱动写入。
struct AdvancedDeviceView: View {
    /// 复用原有回读与提交流程，按用户任务分别显示 SIM 或设备硬件设置。
    enum Scope { case sim, hardware }
    var scope: Scope = .sim
    @State private var boundRevision: Int?
    @Environment(DeviceStore.self) private var devices
    @Environment(ManagementStore.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @Environment(DeviceStatusStore.self) private var status
    @State private var roaming = false
    @State private var directPower = false
    @State private var usb = "未知"
    @State private var sim = JSONObject()
    @State private var profiles: [APNProfile] = []
    @State private var mode = 0
    @State private var selectedID = ""
    @State private var editing: APNProfile?
    @State private var showPIN = false
    @State private var pending: String?
    @State private var loaded = false
    @State private var loading = false
    @State private var loadError: String?

    var body: some View {
        DetailSheet(
            title: scope == .sim ? "SIM 与 APN" : "USB 与供电",
            primaryTitle: "刷新", primaryDisabled: loading || manager.working,
            onPrimary: { Task { await load() } }
        ) {
            if loading && !loaded { ProgressView("读取设备设置…") }
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(.footnote.weight(.medium)).foregroundStyle(.orange)
            }
            if devices.readOnly {
                Label("只读模式", systemImage: "lock").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            if manager.operationTitle == "应用设备设置" { ManagementProgress() }
            if loaded {
                if scope == .sim { simSettings } else { hardwareSettings }
            }
        }
        .onAppear { if boundRevision == nil { boundRevision = devices.clientRevision } }
        .task {
            await load()
        }
        .appModal(
            isPresented: $showPIN,
            onDismiss: {
                Task {
                    await load()
                }
            }
        ) {
            PINManagementView()
        }
        .appModal(item: $editing) {
            profile in
            APNEditorView(profile: profile) {
                Task {
                    await load()
                }
            }
        }
        .confirmationDialog("确认设备设置变更", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            if let pending {
                Button(confirmationTitle(pending)) {
                    Task {
                        await manager.run("应用设备设置") {
                            guard boundRevision == devices.clientRevision else { throw ManagementError.deviceChanged }
                            let api = try await manager.verifiedAPI(devices)
                            switch pending {
                            case "开启漫游", "关闭漫游": try await api.setRoaming(pending == "开启漫游")
                            case "开启直供电", "恢复充电": try await api.setDirectPower(pending == "开启直供电")
                            case "自动 APN": try await api.selectAPN(nil)
                            default:
                                if pending.hasPrefix("APN:") {
                                    try await api.selectAPN(String(pending.dropFirst(4)))
                                }
                                if pending.hasPrefix("USB:") {
                                    try await api.setUSBMode(String(pending.dropFirst(4)))
                                }
                            }
                            try await readSettings()
                            await manager.setStage("设置已回读确认", progress: 1)
                        }
                    }
                }
            }
        } message: {
            Text(scope == .hardware ? "USB 模式切换会中断电脑的 USB 网络。直供电只改变充电策略。" : "切换 APN 会重新连接蜂窝网络，数据漫游可能产生额外费用。")
        }
    }

    private func confirmationTitle(_ action: String) -> String {
        if action.hasPrefix("APN:") { return "切换到所选接入点" }
        if action == "USB:ecm" { return "切换为 ECM 网络共享" }
        if action == "USB:rndis" { return "切换为 RNDIS 网络共享" }
        return action == "自动 APN" ? "恢复自动选择 APN" : action
    }

    private var simSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            DeviceDetailSummary(
                symbol: "simcard", title: status.snapshot?.operatorName ?? "SIM 卡",
                subtitle: "\(status.snapshot?.networkType ?? "蜂窝网络") · \(mode == 0 ? "自动选择 APN" : "手动选择 APN")")
            GlassSection("接入点 APN") {
                HStack {
                    Label(mode == 0 ? "自动选择" : "手动选择", systemImage: mode == 0 ? "arrow.triangle.2.circlepath" : "hand.tap")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if mode != 0 {
                        Button("恢复自动") { pending = "自动 APN" }.font(.subheadline.weight(.medium))
                    }
                }
                ForEach(profiles) { profile in
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            editing = profile
                        } label: {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(profile.name.isEmpty ? "未命名接入点" : profile.name).font(.headline)
                                    Text(profile.apn.isEmpty ? "由运营商提供接入点" : profile.apn)
                                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if mode == 1 && selectedID == profile.id {
                            Label("当前使用", systemImage: "checkmark.circle.fill")
                                .font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)
                        } else {
                            Button("使用此接入点", systemImage: "arrow.turn.down.right") {
                                pending = "APN:\(profile.id)"
                            }
                            .font(.subheadline.weight(.medium)).buttonStyle(.bordered)
                        }
                    }
                }
                Divider()
                Button("添加接入点", systemImage: "plus.circle") { editing = APNProfile(values: JSONObject()) }
                    .font(.subheadline.weight(.medium))
            }
            .disabled(manager.working || loading || devices.readOnly)
            Text("自动模式由运营商选择接入点。点按名称可编辑；手动切换会重新连接蜂窝网络。")
                .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            GlassSection("SIM 安全") {
                Button {
                    showPIN = true
                } label: {
                    HStack {
                        DeviceDetailSummary(
                            symbol: "lock.shield", title: "PIN 与 PUK",
                            subtitle: "PIN 锁\(pinState) · 剩余 \(sim.string("pinnumber") ?? "未知") 次")
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            GlassSection("漫游") {
                Toggle("数据漫游", isOn: Binding(get: { roaming }, set: { pending = $0 ? "开启漫游" : "关闭漫游" }))
                Text("允许 SIM 在非归属运营商网络上使用蜂窝数据，费用由运营商决定。")
                    .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            }
            .disabled(manager.working || loading || devices.readOnly)
        }
    }

    private var pinState: String {
        switch sim.string("pin_status") {
        case "1": return "开启"
        case "0": return "关闭"
        default: return "状态未知"
        }
    }

    private var hardwareSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            DeviceDetailSummary(
                symbol: "cable.connector", title: usbTitle,
                subtitle: "当前 USB 模式 · \(usb.uppercased())")
            GlassSection("USB 网络共享") {
                usbOption("ecm", title: "Mac 与 Linux", subtitle: "ECM 网络接口", symbol: "laptopcomputer")
                Divider()
                usbOption("rndis", title: "Windows", subtitle: "RNDIS 网络接口", symbol: "desktopcomputer")
            }
            .disabled(manager.working || loading || devices.readOnly)
            Text("切换后电脑会重新识别 USB 网卡；请保持 Wi-Fi 连接。此设置临时生效，设备重启后恢复原厂模式。")
                .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            GlassSection("电池与供电") {
                LabeledContent("电池电量", value: status.snapshot?.battery.map { "\($0)%" } ?? "尚未读取")
                LabeledContent("电池温度", value: status.snapshot?.batteryTemp.map { "\(Int($0)) °C" } ?? "尚未读取")
                Divider()
                Toggle("直供电", isOn: Binding(get: { directPower }, set: { pending = $0 ? "开启直供电" : "恢复充电" }))
                    .disabled(manager.working || loading || devices.readOnly)
                Text(directPower ? "直供电已开启，设备停止为电池充电。" : "当前使用常规充电模式。开启直供电后停止为电池充电。")
                    .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            }
        }
    }

    private var usbTitle: String {
        switch usb.lowercased() {
        case "ecm": return "USB 网络共享 · ECM"
        case "rndis": return "USB 网络共享 · RNDIS"
        case "storage": return "USB 存储模式"
        default: return "USB 连接"
        }
    }

    private func usbOption(_ value: String, title: String, subtitle: String, symbol: String) -> some View {
        Button {
            pending = "USB:" + value
        } label: {
            HStack(spacing: 12) {
                DeviceDetailSummary(symbol: symbol, title: title, subtitle: subtitle)
                Image(systemName: usb.lowercased() == value ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18)).fixedSize()
                    .foregroundStyle(usb.lowercased() == value ? Color.accentColor : .secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(usb.lowercased() == value)
        .accessibilityLabel(title + "，" + subtitle + (usb.lowercased() == value ? "，当前使用" : "，切换"))
    }

    /// 按页面读取所需接口；USB 失败不会再阻断 SIM 页，所有结果成功后才替换当前草稿。
    private func readSettings() async throws {
        let api = devices.webClient
        if scope == .sim {
            let nextSIM = try await api.read("zwrt_zte_mdm.api", "get_sim_info")
            let nextRoaming = try await api.rpc("zwrt_data", "get_wwaniface", params: JSONObject(["source_module": "web", "cid": 1])).int("roam_enable")
            let nextProfiles = try await api.apnProfiles()
            let nextMode = try await api.read("zwrt_apn_object", "get_apn_mode").int("apn_mode")
            let nextID = try await api.read("zwrt_apn_object", "get_enabled_manu_apn_id").string("profileId")
            guard let nextRoaming, let nextMode, [0, 1].contains(nextMode) else {
                throw ManagementError.unconfirmed("SIM 设置返回不完整，请刷新后重试。")
            }
            sim = nextSIM
            roaming = nextRoaming == 1
            profiles = nextProfiles
            mode = nextMode
            selectedID = nextID ?? ""
        } else {
            let nextPower = try await api.read("zwrt_bsp.charger", "list").string("direct_power_supply_mode")
            let nextUSB = try await api.usbMode()
            guard let nextPower, ["enable", "disable"].contains(nextPower) else {
                throw ManagementError.unconfirmed("供电状态尚未确认，请刷新后重试。")
            }
            directPower = nextPower == "enable"
            usb = nextUSB
        }
        loaded = true
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        loadError = nil
        do { try await readSettings() } catch { loadError = error.localizedDescription }
        loading = false
    }

}

struct APNEditorView: View {
    let profile: APNProfile
    let onSaved: () -> Void
    @State private var boundRevision: Int?
    @Environment(DeviceStore.self) private var devices
    @Environment(ManagementStore.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var apn = ""
    @State private var username = ""
    @State private var password = ""
    @State private var pdp = 3
    @State private var auth = 0
    @State private var deleting = false

    var body: some View {
        DetailSheet(
            title: profile.id.isEmpty ? "添加 APN" : "编辑 APN",
            doneTitle: "取消",
            closeDisabled: manager.working,
            primaryTitle: "保存",
            primaryDisabled: devices.readOnly || manager.working || name.trimmingCharacters(in: .whitespaces).isEmpty
                || apn.trimmingCharacters(in: .whitespaces).isEmpty,
            onPrimary: save
        ) {
            ManagementProgress()
            GlassSection("接入点") {
                FormField("名称") { TextField("名称", text: $name) }
                FormField("APN") { TextField("APN", text: $apn) }.textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            .disabled(manager.working || devices.readOnly)
            GlassSection("运营商认证") {
                FormField("用户名") { TextField("用户名（可选）", text: $username) }.textInputAutocapitalization(.never)
                FormField("密码") { SecureField("密码（可选）", text: $password) }
            }
            .disabled(manager.working || devices.readOnly)
            GlassSection("连接参数") {
                LabeledContent("IP 协议") {
                    Picker("IP 协议", selection: $pdp) {
                        Text("IPv4").tag(1)
                        Text("IPv6").tag(2)
                        Text("IPv4 / IPv6").tag(3)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                LabeledContent("认证") {
                    Picker("认证", selection: $auth) {
                        Text("无").tag(0)
                        Text("PAP").tag(1)
                        Text("CHAP").tag(2)
                        Text("PAP / CHAP").tag(3)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }
            .disabled(manager.working || devices.readOnly)
            if !profile.id.isEmpty {
                GlassSection {
                    Button("删除 APN", role: .destructive) {
                        deleting = true
                    }
                }.disabled(manager.working || devices.readOnly)
            }
        }
        .onAppear {
            if boundRevision == nil { boundRevision = devices.clientRevision }
            name = profile.values.string("profilename") ?? ""
            apn = profile.values.string("wanapn") ?? ""
            username = profile.values.string("username") ?? ""
            password = profile.values.string("password") ?? ""
            pdp = profile.values.int("pdpType") ?? 3
            auth = profile.values.int("pppAuthMode") ?? 0
        }
        .confirmationDialog("删除此 APN？当前使用的 APN 不能删除。", isPresented: $deleting, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                Task {
                    var success = false
                    await manager.run("删除 APN") {
                        guard boundRevision == devices.clientRevision else { throw ManagementError.deviceChanged }
                        let api = try await manager.verifiedAPI(devices)
                        let current = try await api.read("zwrt_apn_object", "get_enabled_manu_apn_id").string("profileId")
                        guard current != profile.id else {
                            throw ManagementError.invalid("请先切换到其他 APN。")
                        }
                        _ = try await api.rpc("zwrt_apn_object", "delete_manu_apn", params: JSONObject(["profileId": profile.id]))
                        guard try await !api.apnProfiles().contains(where: { $0.id == profile.id }) else {
                            throw ManagementError.unconfirmed("删除未得到回读确认。")
                        }
                        success = true
                    }
                    if success {
                        dismiss()
                        onSaved()
                    }
                }
            }
        }
    }

    private func save() {
        Task {
            var success = false
            await manager.run("保存 APN") {
                guard boundRevision == devices.clientRevision else { throw ManagementError.deviceChanged }
                let api = try await manager.verifiedAPI(devices)
                var values = profile.values.raw
                values.merge([
                    "profilename": name, "wanapn": apn, "username": username, "password": password,
                    "pdpType": pdp, "pppAuthMode": auth, "roamingPdpType": pdp,
                ]) {
                    _, new in new
                }
                try await api.saveAPN(APNProfile(values: JSONObject(values)))
                success = true
            }
            if success {
                dismiss()
                onSaved()
            }
        }
    }
}

struct PINManagementView: View {
    @State private var boundRevision: Int?
    @Environment(DeviceStore.self) private var devices
    @Environment(ManagementStore.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @State private var action = "enable"
    @State private var pin = ""
    @State private var newPIN = ""
    @State private var puk = ""
    @State private var confirm = false
    @State private var remaining = "尚未读取"

    var body: some View {
        DetailSheet(
            title: "PIN／PUK 管理", primaryTitle: "刷新", primaryDisabled: manager.working,
            onPrimary: { Task { await refresh() } }
        ) {
            if manager.operationTitle == "提交 SIM 操作" { ManagementProgress() }
            DeviceDetailSummary(symbol: "lock.shield", title: "SIM 安全", subtitle: remaining)
            GlassSection("选择操作") {
                LabeledContent("操作") {
                    Picker("操作", selection: $action) {
                        Text("启用 PIN 锁").tag("enable")
                        Text("关闭 PIN 锁").tag("disable")
                        Text("修改 PIN").tag("change")
                        Text("输入 PIN 解锁").tag("unlock")
                        Text("输入 PUK 解锁").tag("puk")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }
            GlassSection("验证信息") {
                FormField(action == "puk" ? "设置新 PIN" : "当前 PIN") {
                    SecureField("4–8 位数字", text: $pin).keyboardType(.numberPad)
                }
                if action == "change" {
                    FormField("新 PIN") { SecureField("4–8 位数字", text: $newPIN).keyboardType(.numberPad) }
                }
                if action == "puk" {
                    FormField("PUK") { SecureField("运营商提供的 8 位数字", text: $puk).keyboardType(.numberPad) }
                }
                Button("提交") {
                    confirm = true
                }.disabled(pin.isEmpty || manager.working || devices.readOnly)
            } footer: {
                Text("错误 PIN／PUK 会消耗 SIM 剩余次数。请只使用运营商提供或自己设置的号码；不会自动重试。")
            }
        }
        .onAppear { if boundRevision == nil { boundRevision = devices.clientRevision } }
        .task {
            await refresh()
        }
        .confirmationDialog("确认提交一次 PIN 操作？", isPresented: $confirm, titleVisibility: .visible) {
            Button("提交一次") {
                Task {
                    await manager.run("提交 SIM 操作") {
                        guard boundRevision == devices.clientRevision else { throw ManagementError.deviceChanged }
                        _ = try await manager.verifiedAPI(devices)
                        try FactoryClient.validatePIN(action: action, pin: pin, newPIN: newPIN, puk: puk)
                        if devices.demoMode {
                            _ = try await devices.webClient.rpc("u60.demo", "set_pin", params: JSONObject(["action": action]))
                        } else {
                            guard let profile = devices.current else {
                                throw ManagementError.deviceChanged
                            }
                            try await FactoryClient(host: profile.host, password: devices.factoryPassword(for: profile))
                                .changePIN(action: action, pin: pin, newPIN: newPIN, puk: puk)
                        }
                        pin = ""
                        newPIN = ""
                        puk = ""
                        await refresh()
                        await manager.setStage(devices.demoMode ? "演示：SIM 操作完成" : "操作已提交，请核对 SIM 状态与剩余次数", progress: 1)
                    }
                }
            }
        }
    }

    private func refresh() async {
        do {
            let sim = try await devices.webClient.read("zwrt_zte_mdm.api", "get_sim_info")
            remaining = "PIN 剩余 \(sim.string("pinnumber") ?? "未知") 次 · PUK 剩余 \(sim.string("puknumber") ?? "未知") 次"
        } catch { remaining = error.localizedDescription }
    }
}

/// 恢复出厂先生成当前设备备份，用户导出后输入确认词；演示不会访问原厂接口。
struct FactoryResetView: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(ManagementStore.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var saved = false
    @State private var confirm = false
    @State private var backupDevice: String?
    @State private var submitted = false

    var body: some View {
        DetailSheet(title: "恢复出厂设置") {
            Text("将清除原厂设置，管理地址、Wi-Fi 与登录凭据可能恢复默认。部署的代理与开机启动也可能失效，需要重新配对。")
                .foregroundStyle(.orange)
            ManagementProgress()
            GlassSection("1 · 备份当前设备") {
                Button("生成备份") {
                    Task {
                        await manager.backup(devices)
                        if manager.error == nil {
                            backupDevice = devices.storageID
                        }
                    }
                }
                if backupDevice == devices.storageID, let url = manager.backupURL {
                    ShareLink("导出备份", item: url)
                    Toggle("我已妥善保存此备份", isOn: $saved)
                }
            }
            GlassSection("2 · 确认清除") {
                TextField("输入“恢复出厂”", text: $text)
                Button("恢复出厂设置", role: .destructive) {
                    confirm = true
                }
                .disabled(!saved || text != "恢复出厂" || backupDevice != devices.storageID || submitted)
                if submitted {
                    Text("请求已发出，不会重复提交。请按设备屏幕提示连接默认 Wi-Fi，然后重新配对。").font(.footnote.weight(.medium))
                }
            }
            .disabled(manager.working)
        }
        .confirmationDialog("确认清除这台设备的原厂设置？", isPresented: $confirm, titleVisibility: .visible) {
            Button("清除并恢复出厂", role: .destructive) {
                Task {
                    await manager.run("提交恢复出厂请求") {
                        _ = try await manager.verifiedAPI(devices)
                        if !devices.demoMode {
                            guard let profile = devices.current else {
                                throw ManagementError.deviceChanged
                            }
                            do {
                                try await FactoryClient(host: profile.host, password: devices.factoryPassword(for: profile)).reset()
                            } catch is DeviceRequestUncertain {
                                submitted = true
                                throw DeviceRequestUncertain()
                            }
                        }
                        submitted = true
                        await manager.setStage(devices.demoMode ? "演示：恢复出厂请求已完成" : "原厂接口已接收，等待设备重启；需重新配对", progress: 1)
                    }
                }
            }
        }
    }
}
