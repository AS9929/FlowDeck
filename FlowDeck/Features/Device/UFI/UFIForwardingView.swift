import SwiftUI

/// 转发目标、开关和过滤独立保存；不把 UFI 的自动测试发送隐藏在普通表单提交之后。
struct UFIForwardingView: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(ManagementStore.self) private var manager
    @Environment(\.scenePhase) private var scenePhase
    @State private var method: UFIForwardingState.Method = .smtp
    @State private var state: UFIForwardingState?
    @State private var values: [String: String] = [:]
    @State private var filter: [String: String] = [:]
    @State private var loading = false
    @State private var revision = 0
    @State private var error: String?
    @State private var action: String?
    private var busy: Bool { loading || manager.working }

    var body: some View {
        DetailSheet(title: "短信自动转发", closeDisabled: busy) {
            DeviceDetailSummary(
                symbol: "arrowshape.turn.up.right", title: "收到短信，自动通知",
                subtitle: "由 F50 持续运行。短信可能包含验证码，请仅转发到自己的目标。")
            if loading { ProgressView("读取转发设置…") }
            if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
            GlassSection("运行状态") {
                LabeledContent("自动转发", value: state?.enabled == true ? "已开启" : "未开启")
                LabeledContent("当前通道", value: state?.method.isEmpty == false ? state!.method : "尚未配置")
                Button(state?.enabled == true ? "关闭自动转发" : "开启自动转发", systemImage: "power") {
                    action = "toggle"
                }.disabled(busy || devices.readOnly || state == nil)
            }
            GlassSection("通知目标") {
                Picker("方式", selection: $method) {
                    ForEach(UFIForwardingState.Method.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).disabled(busy)
                if method == .smtp {
                    field("SMTP 服务器", "smtp_host")
                    field("端口", "smtp_port")
                    field("收件邮箱", "smtp_to")
                    field("认证账号", "smtp_username")
                    field("发件邮箱（可选）", "smtp_from")
                    field("发件人名称（可选）", "smtp_from_name")
                    SecureField("SMTP 授权码", text: binding("smtp_password"))
                } else {
                    SecureField("钉钉机器人 HTTPS 地址", text: binding("webhook_url"))
                    SecureField("签名密钥（可选）", text: binding("secret"))
                }
                Toggle(
                    "附带设备信息",
                    isOn: Binding(
                        get: { values["forward_dev_info"] == "1" },
                        set: { values["forward_dev_info"] = $0 ? "1" : "0" }))
                Button("保存并发送测试消息", systemImage: "paperplane") { action = "save" }
                    .disabled(busy || devices.readOnly || state == nil)
            }.disabled(busy)
            GlassSection("不转发的短信") {
                Text("号码和关键词分别每行填写一项。留空表示不按此项过滤。")
                    .font(.footnote).foregroundStyle(.secondary)
                TextField("号码，每行一个", text: Binding(get: { filter["phone"] ?? "" }, set: { filter["phone"] = $0 }), axis: .vertical)
                TextField("关键词，每行一个", text: Binding(get: { filter["keywords"] ?? "" }, set: { filter["keywords"] = $0 }), axis: .vertical)
                Button("保存过滤规则", systemImage: "line.3.horizontal.decrease") { action = "filter" }
                    .disabled(busy || devices.readOnly || state == nil)
            }.disabled(busy)
            Button("重新读取", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(busy)
        }
        .task(id: devices.clientRevision) {
            revision = devices.clientRevision
            state = nil
            values = [:]
            filter = [:]
            await load()
        }
        .onChange(of: method) { _, _ in Task { await load() } }
        .confirmationDialog("确认短信转发操作", isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } }), titleVisibility: .visible) {
            Button("确认") {
                let selected = action
                action = nil
                Task { await perform(selected) }
            }
        } message: {
            Text(
                action == "save"
                    ? "UFI 保存后会向所填目标发送测试消息。接收目标：\(method == .smtp ? values["smtp_to"] ?? "" : "所填钉钉机器人")。开启转发后，新短信内容将发送到此目标。"
                    : "开启后将由设备转发新短信；过滤规则决定哪些号码和关键词不转发。")
        }
        .opacity(scenePhase == .active ? 1 : 0)
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }

    private func field(_ title: String, _ key: String) -> some View {
        FormField(title) { TextField(title, text: binding(key)).textInputAutocapitalization(.never).autocorrectionDisabled() }
    }

    private func load() async {
        let expected = devices.clientRevision
        let selected = method
        loading = true
        state = nil
        values = [:]
        filter = [:]
        defer { if expected == devices.clientRevision, selected == method { loading = false } }
        do {
            guard let api = devices.webClient as? any UFIForwardingService else { throw ManagementError.deviceChanged }
            let value = try await api.forwardingState(method: selected)
            guard expected == devices.clientRevision, selected == method else { return }
            state = value
            values = value.values
            if values["smtp_port"] == "" { values["smtp_port"] = "465" }
            filter = value.filter
            error = nil
        } catch {
            if expected == devices.clientRevision, selected == method { self.error = error.localizedDescription }
        }
    }

    private func perform(_ action: String?) async {
        guard let original = state else { return }
        let expected = revision
        await manager.run("保存 F50 短信转发") {
            let verified = try await manager.verifiedAPI(devices, capability: .factoryControl)
            guard expected == devices.clientRevision, let api = verified as? any UFIForwardingService else { throw ManagementError.deviceChanged }
            switch action {
            case "save": try await api.saveForwarding(values, method: method, replacing: original)
            case "toggle": try await api.toggleForwarding(!original.enabled, method: method, replacing: original)
            case "filter": try await api.saveForwardingFilter(filter, method: method, replacing: original)
            default: return
            }
        }
        guard expected == devices.clientRevision else { return }
        if let failure = manager.error { error = failure } else { await load() }
    }
}
