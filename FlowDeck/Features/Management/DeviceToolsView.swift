import SwiftUI

/// 管理扩展按任务组织；只读取当前设备，写入统一经过身份与只读校验。
struct DeviceToolsView: View {
    @State private var destination: Destination?
    enum Destination: String, Identifiable {
        case wifi, forwarding, command
        var id: String { rawValue }
    }

    var body: some View {
        DetailSheet(title: "设备工具") {
            DeviceDetailSummary(symbol: "wrench.and.screwdriver", title: "深入管理设备", subtitle: "通过 WebSSH 服务访问扩展能力。可用性取决于设备与服务版本。")
            GlassSection("网络与通知") {
                entry("Wi-Fi 性能", symbol: "wifi", subtitle: "查看无线接口并调整省电模式", target: .wifi)
                Divider()
                entry("短信转发", symbol: "paperplane", subtitle: "Bark 与 Telegram 通知通道", target: .forwarding)
            }
            GlassSection("高级工具") {
                entry("命令控制台", symbol: "terminal", subtitle: "单次执行命令、检查输出与退出码", target: .command)
            }
        }
        .appPush(item: $destination) { target in
            switch target {
            case .wifi: WiFiPerformanceView()
            case .forwarding: SMSForwardingView()
            case .command: DeviceCommandView()
            }
        }
    }

    private func entry(_ title: String, symbol: String, subtitle: String, target: Destination) -> some View {
        Button {
            destination = target
        } label: {
            SettingsRow(title, symbol: symbol, subtitle: subtitle)
        }
    }
}

struct WiFiPerformanceView: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(ManagementStore.self) private var manager
    @State private var state: WiFiPowerState?
    @State private var error: String?
    @State private var pending: Bool?
    @State private var started = false

    var body: some View {
        DetailSheet(title: "Wi-Fi 性能", closeDisabled: manager.working) {
            DeviceDetailSummary(symbol: "wifi", title: state?.summary ?? "读取无线状态", subtitle: "性能优先关闭接口省电；节能优先允许接口进入省电状态。")
            if let error { StatusBanner(title: "无法读取", message: error, tone: .warning) { Task { await load() } } }
            if let state {
                GlassSection("当前接口") {
                    if state.interfaces.isEmpty { Text("当前服务未报告支持此设置的接口。").foregroundStyle(.secondary) }
                    ForEach(state.interfaces, id: \.self) { interface in
                        LabeledContent(interface, value: state.modes[interface] == "on" ? "节能优先" : "性能优先")
                    }
                }
                GlassSection("应用模式") {
                    Button {
                        pending = false
                    } label: {
                        Label("性能优先", systemImage: "bolt")
                    }
                    Divider()
                    Button {
                        pending = true
                    } label: {
                        Label("节能优先", systemImage: "leaf")
                    }
                }
                .disabled(manager.working || devices.readOnly || state.interfaces.isEmpty)
                Text("仅应用到上方已识别的接口，完成后重新读取确认。设备重启后的行为由固件决定。")
                    .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            } else if error == nil {
                ProgressView()
            }
            if started { ManagementProgress() }
        }
        .task(id: devices.clientRevision) { await load() }
        .refreshable { await load() }
        .confirmationDialog("应用无线模式？", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            if let pending {
                Button(pending ? "应用节能优先" : "应用性能优先") { apply(pending) }
            }
        }
    }

    private func load() async {
        let revision = devices.clientRevision
        state = nil
        error = nil
        do {
            let result = try await devices.webClient.wifiPowerState()
            guard revision == devices.clientRevision, !Task.isCancelled else { return }
            state = result
        } catch {
            guard revision == devices.clientRevision, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func apply(_ saving: Bool) {
        let interfaces = state?.interfaces ?? []
        started = true
        Task {
            await manager.run("应用 Wi-Fi 模式") {
                let api = try await manager.verifiedAPI(devices)
                state = try await api.setWiFiPowerSaving(saving, interfaces: interfaces)
                await manager.setStage("无线接口已回读确认", progress: 1)
            }
        }
    }
}

/// 通知配置与服务启停分离，保存不会偷偷启动转发。
struct SMSForwardingView: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(ManagementStore.self) private var manager
    @State private var settings = SMSForwardSettings()
    @State private var status: JSONObject?
    @State private var error: String?
    @State private var pending: Action?
    @State private var started = false

    enum Action: String {
        case save = "保存转发设置"
        case start = "启动转发"
        case stop = "停止转发"
        case autostart = "切换开机启动"
    }

    var body: some View {
        DetailSheet(title: "短信转发", closeDisabled: manager.working) {
            DeviceDetailSummary(
                symbol: "paperplane", title: status?.bool("running") == true ? "正在转发新短信" : "转发未运行", subtitle: "将设备收到的新短信发送到你指定的通知通道。保存通道后，再单独启动服务。")
            if let error { StatusBanner(title: "读取失败", message: error, tone: .warning) { Task { await load() } } }
            if let status {
                GlassSection("通知通道") {
                    Toggle("Bark", isOn: $settings.barkEnabled)
                    if settings.barkEnabled {
                        FormField("推送地址") { SecureField("https://…", text: $settings.barkURL).textInputAutocapitalization(.never).autocorrectionDisabled() }
                        FormField("通知分组") { TextField("短信", text: $settings.barkGroup) }
                    }
                    Divider()
                    Toggle("Telegram", isOn: $settings.telegramEnabled)
                    if settings.telegramEnabled {
                        FormField("Bot Token") {
                            SecureField("机器人凭据", text: $settings.telegramToken).textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                        FormField("Chat ID") {
                            TextField("接收方 ID", text: $settings.telegramChatID).textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                    }
                    Button {
                        pending = .save
                    } label: {
                        Label("保存通道设置", systemImage: "checkmark")
                    }
                }
                .disabled(manager.working || devices.readOnly)
                GlassSection("服务状态") {
                    LabeledContent("本次已发送", value: "\(status.int("sent_count") ?? 0) 条")
                    LabeledContent("开机启动", value: status.bool("autostart_enabled") == true ? "开启" : "关闭")
                    Button {
                        pending = status.bool("running") == true ? .stop : .start
                    } label: {
                        Label(status.bool("running") == true ? "停止转发" : "启动转发", systemImage: "power")
                    }
                    Button {
                        pending = .autostart
                    } label: {
                        Label(status.bool("autostart_enabled") == true ? "关闭开机启动" : "开启开机启动", systemImage: "arrow.clockwise.circle")
                    }
                }
                .disabled(manager.working || devices.readOnly)
                Text("凭据保存在设备端。只有启用并启动的通道才会发送；收件地址请确认属于你。")
                    .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            } else if error == nil {
                ProgressView("读取通知服务…")
            }
            if started { ManagementProgress() }
        }
        .task(id: devices.clientRevision) { await load() }
        .confirmationDialog(
            pending?.rawValue ?? "确认操作", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible
        ) {
            if let pending { Button(pending.rawValue) { perform(pending) } }
        }
    }

    private func load() async {
        let revision = devices.clientRevision
        status = nil
        error = nil
        do {
            let actual = try await devices.webClient.smsForwardStatus()
            guard revision == devices.clientRevision, !Task.isCancelled else { return }
            status = actual
            settings = SMSForwardSettings(actual.object("config") ?? JSONObject())
        } catch {
            guard revision == devices.clientRevision, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func perform(_ action: Action) {
        started = true
        Task {
            await manager.run(action.rawValue) {
                let api = try await manager.verifiedAPI(devices)
                if action == .save {
                    status = try await api.saveSMSForwardSettings(settings)
                } else {
                    let enabled = !(status?.bool("autostart_enabled") ?? false)
                    if action == .start {
                        let saved = status?.object("config")
                        guard saved?.bool("bark_enabled") == true || saved?.bool("tg_enabled") == true else {
                            throw ManagementError.invalid("请先启用并保存至少一个通知通道。")
                        }
                    }
                    if action == .autostart {
                        _ = try await api.management("POST", "api/system/sms-forward/autostart", body: JSONObject(["enabled": enabled]))
                    } else {
                        _ = try await api.management(
                            "POST", "api/system/sms-forward/control", body: JSONObject(["action": action == .start ? "start" : "stop"]))
                    }
                    let actual = try await api.smsForwardStatus()
                    status = actual
                    let confirmed = action == .autostart ? actual.bool("autostart_enabled") == enabled : actual.bool("running") == (action == .start)
                    guard confirmed else { throw ManagementError.unconfirmed("服务未回读到预期状态，请重新检查。") }
                }
                await manager.setStage("操作完成，已重新读取设备状态", progress: 1)
            }
        }
    }
}

struct DeviceCommandView: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(ManagementStore.self) private var manager
    @State private var command = ""
    @State private var result: DeviceCommandResult?
    @State private var confirming = false
    @State private var started = false

    var body: some View {
        DetailSheet(title: "命令控制台", closeDisabled: manager.working) {
            DeviceDetailSummary(symbol: "terminal", title: "在设备上执行", subtitle: "一次命令、一次结果。适合状态检查；不支持交互式登录或持续运行的终端程序。")
            GlassSection("命令") {
                TextEditor(text: $command)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 100)
                    .scrollContentBackground(.hidden)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("设备命令")
                Menu {
                    Button("系统信息") { command = "uname -a" }
                    Button("运行时间") { command = "uptime" }
                    Button("存储空间") { command = "df -h" }
                    Button("内存信息") { command = "free -m" }
                } label: {
                    Label("填入检查命令", systemImage: "text.badge.plus")
                }
                Button {
                    confirming = true
                } label: {
                    Label("执行命令", systemImage: "play.fill")
                }
                .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .disabled(manager.working || devices.readOnly)
            if started && (manager.working || result == nil) { ManagementProgress() }
            if let result {
                GlassSection("执行结果 · 退出码 \(result.code)") {
                    Text(result.output.isEmpty ? "命令未产生输出" : result.output)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Button {
                        UIPasteboard.general.setItems([["public.utf8-plain-text": result.output]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
                    } label: {
                        Label("复制输出", systemImage: "doc.on.doc")
                    }
                }
            }
            Text("命令使用设备管理权限。超时或退出页面不代表远端命令已停止；输出仅在本页保留，最多显示 64 KB。")
                .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
        }
        .onChange(of: devices.clientRevision) {
            result = nil
            command = ""
        }
        .confirmationDialog("在当前设备执行这条命令？", isPresented: $confirming, titleVisibility: .visible) {
            Button("执行") { execute() }
        } message: {
            Text(command)
        }
    }

    private func execute() {
        let submitted = command
        started = true
        result = nil
        Task {
            await manager.run("执行设备命令") {
                let api = try await manager.verifiedAPI(devices)
                result =
                    devices.demoMode
                    ? DeviceCommandResult(code: 0, output: "[演示模式] 未向设备发送命令。")
                    : try await api.executeUserCommand(submitted)
                await manager.setStage("执行结束 · 退出码 \(result?.code ?? -1)", progress: 1)
                if result?.code != 0 { throw ManagementError.unconfirmed("命令以非零状态退出，请查看输出。") }
            }
        }
    }
}
