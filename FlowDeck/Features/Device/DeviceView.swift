import SwiftUI

/// 设备页：蜂窝、Wi-Fi、已连接设备、短信、本机信息。数据来自 WebSSH 代为调用的原厂接口。
struct DeviceView: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(DeviceStatusStore.self) private var status
    @Environment(ManagementStore.self) private var manager
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var sheet: Sheet?
    @State private var showBands = false
    @State private var pendingMode: NetworkMode?

    enum Sheet: String, Identifiable {
        case clients, sms, info, bands, wifi, cellular, advanced, hardware, performance, forwarding
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if devices.usesUFI {
                UFIDeviceView()
            } else {
                GlassSheet {
                    GlassSection("网络") {
                        deviceAction("蜂窝网络", "antenna.radiowaves.left.and.right", subtitle: cellularSummary, destination: .cellular)
                        deviceAction("Wi-Fi", "wifi", subtitle: wifiSummary, destination: .wifi)
                        deviceAction("Wi-Fi 性能", "speedometer", subtitle: "无线接口的性能与节能模式", destination: .performance)
                        deviceAction("接入设备", "person.2", subtitle: clientSummary, destination: .clients)
                    }
                    GlassSection("短信与通知") {
                        deviceAction("短信", "message", subtitle: status.unreadCount > 0 ? "\(status.unreadCount) 条未读" : "收件箱与发送", destination: .sms)
                        deviceAction("短信转发", "paperplane", subtitle: "Bark 与 Telegram 通知通道", destination: .forwarding)
                    }
                    GlassSection("硬件与系统") {
                        deviceAction("SIM 与 APN", "simcard", subtitle: "接入点、PIN 与漫游", destination: .advanced)
                        deviceAction("USB 与供电", "cable.connector", subtitle: "USB 网络模式与充电", destination: .hardware)
                        deviceAction("本机信息", "info.circle", subtitle: status.snapshot?.model, destination: .info)
                    }
                    GlassSection("备份与恢复") {
                        DestinationRow("原厂设置备份", symbol: "externaldrive", subtitle: "导出 Wi-Fi、APN 等设备设置", destination: .backup)
                        DestinationRow("重启设备", symbol: "arrow.clockwise", subtitle: "重启并跟踪恢复进度", destination: .recovery)
                        DestinationRow("恢复出厂设置", symbol: "arrow.counterclockwise", subtitle: "备份后重置原厂设置", destination: .factory)
                    }
                    if !devices.webAvailable {
                        GlassSection {
                            Text("请从左上角设备入口添加并验证连接，设备状态会在连接后显示。")
                                .foregroundStyle(.secondary)
                        }
                    } else if let error = status.snapshotError {
                        GlassSection {
                            Text(error).foregroundStyle(.orange)
                            Button("重新读取") {
                                Task { await status.refreshSnapshot() }
                            }
                        }
                    }
                }
                .nativeSettingsPage(title: "设备")
                .toolbar { DeviceContextToolbar() }
            }
        }
        .refreshable { await status.refreshSnapshot() }
        .visibleDeviceTask(tab: 2, enabled: devices.webAvailable && !devices.usesUFI) {
            await status.loadMessages()
            await status.poll()
        }
        .appPush(item: $sheet) { s in
            switch s {
            case .performance: WiFiPerformanceView()
            case .forwarding: SMSForwardingView()
            case .clients: ClientsView()
            case .sms: SMSView()
            case .info: DeviceInfoView()
            case .bands: BandLockView()
            case .wifi: WifiEditorView()
            case .advanced: AdvancedDeviceView()
            case .hardware: AdvancedDeviceView(scope: .hardware)
            case .cellular:
                DetailSheet(title: "蜂窝网络", onDone: { sheet = nil }) {
                    cellularSection
                    trafficSection
                }
                .appPush(isPresented: $showBands) { BandLockView() }
                .confirmationDialog("切换网络模式", isPresented: Binding(get: { pendingMode != nil }, set: { if !$0 { pendingMode = nil } })) {
                    if let mode = pendingMode {
                        Button("切换为\(mode.title)") {
                            Task { await status.setNetworkMode(mode) }
                        }
                    }
                } message: {
                    Text("蜂窝会重新注册，所有设备断网约 10 秒。")
                }
            }
        }
    }

    private var cellularSummary: String {
        [status.snapshot?.operatorName, status.snapshot?.networkType, status.snapshot?.bandLabel]
            .compactMap { $0 }.joined(separator: " · ").ifEmpty("未连接")
    }

    private func deviceAction(_ title: String, _ symbol: String, subtitle: String? = nil, destination: Sheet) -> some View {
        Button {
            sheet = destination
        } label: {
            SettingsRow(title, symbol: symbol, subtitle: subtitle, disclosure: true)
        }
        .foregroundStyle(.primary)
    }

    @ViewBuilder
    private var cellularSection: some View {
        let s = status.snapshot
        GlassSection {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text([s?.operatorName, s?.networkType].compactMap { $0 }.joined(separator: " · ").ifEmpty("读取中…"))
                            .font(.headline)
                        Text([s?.bandLabel, s?.pci.map { "PCI \($0)" }].compactMap { $0 }.joined(separator: " · ").ifEmpty("—"))
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let c = s?.connected {
                        Text(c ? "已联网" : "未联网")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background((c ? Color.green : Color.red).opacity(0.15), in: Capsule())
                            .foregroundStyle(c ? .green : .red)
                    }
                }
                metricLayout {
                    metric("RSRP", s?.rsrp.map { "\(Int($0))" }, unit: "dBm")
                    metric("SINR", s?.sinr.map { "\(Int($0))" }, unit: "dB")
                    metric("RSRQ", s?.rsrq.map { "\(Int($0))" }, unit: "dB")
                    metric("信号", s.map { $0.signalQuality }, unit: nil)
                }
            }
            .padding(.vertical, 4)
            Menu {
                ForEach(NetworkMode.allCases) { m in
                    Button {
                        pendingMode = m
                    } label: {
                        if s?.netSelect == m.rawValue { Label(m.title, systemImage: "checkmark") } else { Text(m.title) }
                    }
                }
            } label: {
                row("antenna.radiowaves.left.and.right", "网络模式", nil, value: NetworkMode(rawValue: s?.netSelect ?? "")?.title ?? "—")
            }
            Button {
                showBands = true
            } label: {
                row("dot.radiowaves.left.and.right", "频段锁定", "锁频可能导致没有信号，可一键恢复", value: nil)
            }
        } header: {
            Text("蜂窝网络")
        }
    }

    @ViewBuilder
    private var trafficSection: some View {
        if let s = status.snapshot {
            GlassSection {
                metricLayout {
                    metric("实时下行", TrafficMonitor.split(Int(s.rxSpeed)).0, unit: TrafficMonitor.split(Int(s.rxSpeed)).1)
                    metric("今日", s.dayRx.map { bytes($0 + (s.dayTx ?? 0)) }, unit: nil)
                    metric("本月", s.monthRx.map { bytes($0 + (s.monthTx ?? 0)) }, unit: nil)
                }
                .padding(.vertical, 4)
            } header: {
                Text("蜂窝流量")
            } footer: {
                Text("由设备统计的蜂窝总流量，含直连和代理；不代表运营商套餐的剩余量。")
            }
        }
    }

    private var metricLayout: AnyLayout {
        typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            : AnyLayout(HStackLayout(spacing: 0))
    }

    private var wifiSummary: String {
        guard let s = status.snapshot else { return "—" }
        return [s.ssid24, s.ssid5].compactMap { $0 }.joined(separator: " · ").ifEmpty("—")
    }

    private var clientSummary: String {
        guard let s = status.snapshot, s.clientsTotal != nil else { return "查看每台设备的地址和信号" }
        return "Wi-Fi \(s.clientsWifi ?? 0) 台 · 有线 \(s.clientsLan ?? 0) 台"
    }

    private func row(_ symbol: String, _ title: String, _ subtitle: String?, value: String?) -> some View {
        HStack(spacing: 12) {
            FeatureIcon(symbol: symbol)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(Color.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption.weight(.medium)).foregroundStyle(Color.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if let value { Text(value).foregroundStyle(Color.secondary) }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
    }

    private func metric(_ title: String, _ value: String?, unit: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value ?? "—").font(.system(.body, design: .monospaced).weight(.semibold))
                if let unit { Text(unit).font(.caption2.weight(.medium)).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bytes(_ v: Int64) -> String { ByteCountFormatter.string(fromByteCount: v, countStyle: .binary) }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

// MARK: - 本机信息

struct DeviceInfoView: View {
    @Environment(DeviceStatusStore.self) private var status
    @Environment(\.dismiss) private var dismiss
    @State private var reveal = false

    var body: some View {
        let s = status.snapshot
        DetailSheet(title: "本机信息", primaryTitle: "刷新", onPrimary: { Task { await status.refreshSnapshot() } }) {
            DeviceDetailSummary(
                symbol: "wifi.router", title: s?.marketName ?? "设备信息",
                subtitle: s?.model ?? "等待设备返回型号")
            if let error = status.snapshotError {
                Label(error, systemImage: "exclamationmark.triangle").font(.footnote.weight(.medium)).foregroundStyle(.orange)
            }
            GlassSection("运行概况") {
                LabeledContent("已运行", value: s?.uptime.map(duration) ?? "尚未读取")
                LabeledContent("电池", value: s?.battery.map { "\($0)%" + ((s?.charging ?? false) ? " · 充电中" : "") } ?? "尚未读取")
                Divider()
                LabeledContent("电池温度", value: s?.batteryTemp.map { "\(Int($0)) °C" } ?? "尚未读取")
                LabeledContent("CPU 温度", value: s?.cpuTemp.map { "\(Int($0)) °C" } ?? "尚未读取")
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("可用内存").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Text(memory(s)).font(.subheadline.monospacedDigit())
                    if let total = s?.memTotalKB, let available = s?.memAvailKB, total > 0 {
                        ProgressView(value: Double(max(0, min(available, total))), total: Double(total))
                            .accessibilityLabel("可用内存")
                    }
                }
            }
            GlassSection("硬件与软件版本") {
                DeviceParameterRow(title: "硬件版本", value: s?.hardware)
                Divider()
                DeviceParameterRow(title: "原厂软件版本", value: s?.firmware)
                Divider()
                DeviceParameterRow(title: "内部版本", value: s?.integrateVersion)
            }
            GlassSection("网络地址") {
                DeviceParameterRow(title: "蜂窝 IPv4", value: s?.wanIPv4)
            }
            GlassSection {
                Toggle("显示完整标识", isOn: $reveal)
                Divider()
                if reveal {
                    DeviceParameterRow(title: "IMEI · 设备身份", value: s?.imei)
                    DeviceParameterRow(title: "ICCID · SIM 卡", value: s?.iccid)
                    DeviceParameterRow(title: "IMSI · 用户身份", value: s?.imsi)
                } else {
                    LabeledContent("IMEI", value: Masking.tail(s?.imei))
                    LabeledContent("ICCID", value: Masking.tail(s?.iccid))
                    LabeledContent("IMSI", value: Masking.tail(s?.imsi))
                }
            } header: {
                Text("设备与 SIM 标识")
            } footer: {
                Text("默认只显示末 4 位。显示完整标识后可分别复制。")
            }
        }
        .task { await status.refreshSnapshot() }
    }

    private func memory(_ s: DeviceSnapshot?) -> String {
        guard let t = s?.memTotalKB, let a = s?.memAvailKB, t > 0 else { return "—" }
        return "\(a / 1024) MB / \(t / 1024) MB"
    }

    private func duration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return h > 0 ? "\(h) 小时 \(m) 分" : "\(m) 分"
    }
}

// MARK: - Wi-Fi

struct WifiView: View {
    @Environment(DeviceStatusStore.self) private var status
    @Environment(\.dismiss) private var dismiss
    @State private var draft: [String: WifiRadioSettings] = [:]

    var body: some View {
        let s = status.snapshot
        DetailSheet(title: "Wi-Fi", doneTitle: "关闭") {
            GlassSection("网络") {
                LabeledContent("2.4 GHz", value: (s?.ssid24 ?? "—") + ((s?.radio24On == false) ? "（已关闭）" : ""))
                LabeledContent("5 GHz", value: (s?.ssid5 ?? "—") + ((s?.radio5On == false) ? "（已关闭）" : ""))
            }
            ForEach([("wifi0", "2.4 GHz"), ("wifi1", "5 GHz")], id: \.0) { key, title in
                if draft[key] != nil {
                    GlassSection(title) {
                        LabeledContent("发射功率") {
                            LabeledContent("发射功率") {
                                Picker("发射功率", selection: binding(key, \.txPower)) {
                                    Text("40%").tag("40")
                                    Text("80%").tag("80")
                                    Text("100%").tag("100")
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                        LabeledContent("国家码", value: draft[key]?.country ?? "CN")
                    }
                }
            }
            GlassSection {
                Button("应用") { Task { await status.setWifi(draft) } }
                    .disabled(draft.isEmpty || draft == status.wifi)
            } footer: {
                Text("这里可以调整 Wi-Fi 发射功率。修改网络名称和密码，请使用设备的管理网页。")
            }
        }
        .task {
            await status.loadWifi()
            draft = status.wifi
        }
    }

    private func binding(_ key: String, _ path: WritableKeyPath<WifiRadioSettings, String>) -> Binding<String> {
        Binding(get: { draft[key]?[keyPath: path] ?? "" }, set: { draft[key]?[keyPath: path] = $0 })
    }
}

// MARK: - 频段锁定

struct BandLockView: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(DeviceStatusStore.self) private var status
    @Environment(\.dismiss) private var dismiss
    @State private var lte = Set(NetworkMode.lteBands)
    @State private var nr = Set(NetworkMode.nrBands)
    @State private var confirm = false
    @State private var loaded = false
    @State private var boundRevision: Int?
    @State private var loadError: String?

    var body: some View {
        DetailSheet(title: "频段锁定", doneTitle: "关闭") {
            GlassSection {
                Button("恢复自动选择（选中全部频段）") {
                    lte = Set(NetworkMode.lteBands)
                    nr = Set(NetworkMode.nrBands)
                }
            } footer: {
                Text("锁频后如果换地方没有信号，回到这里点“恢复自动选择”再应用。")
            }
            if let loadError { Text(loadError).foregroundStyle(.orange) }
            bandSection("5G 频段（SA）", all: NetworkMode.nrBands, prefix: "n", selection: $nr)
            bandSection("4G 频段", all: NetworkMode.lteBands, prefix: "B", selection: $lte)
            GlassSection {
                Button("应用") { confirm = true }
                    .disabled(!loaded || boundRevision != devices.clientRevision || lte.isEmpty || nr.isEmpty || status.busy != nil)
            } footer: {
                Text("每类至少保留一个频段。应用时蜂窝会短暂断开。")
            }
        }
        .task {
            boundRevision = devices.clientRevision
            do {
                let current = try await devices.webClient.read("zte_nwinfo_api", "nwinfo_get_netinfo")
                guard let selected = BandSelection.lte(current.string("lte_band_lock")) else {
                    throw ManagementError.unconfirmed("无法读取当前锁频设置。")
                }
                lte = selected
                nr = BandSelection.nr(current.string("nr5g_sa_band_lock"))
                loaded = !lte.isEmpty && !nr.isEmpty
            } catch { loadError = error.localizedDescription }
        }
        .confirmationDialog("应用频段设置", isPresented: $confirm, titleVisibility: .visible) {
            Button("应用") {
                Task {
                    guard boundRevision == devices.clientRevision else {
                        loadError = "设备连接已变化，请返回并重新读取频段设置。"
                        return
                    }
                    await status.lockBands(lte: lte.sorted(), nr: nr.sorted())
                    dismiss()
                }
            }
        } message: {
            Text("锁定后只会使用选中的频段，所有设备会断网几秒。")
        }
    }

    private func bandSection(_ title: String, all: [Int], prefix: String, selection: Binding<Set<Int>>) -> some View {
        GlassSection(title) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 90 : 52), spacing: 8)], spacing: 8) {
                ForEach(all, id: \.self) { b in
                    let on = selection.wrappedValue.contains(b)
                    Button {
                        if on { selection.wrappedValue.remove(b) } else { selection.wrappedValue.insert(b) }
                    } label: {
                        Text("\(prefix)\(b)")
                            .font(.caption.weight(.semibold).monospaced())
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(on ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05), in: Capsule())
                            .foregroundStyle(on ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
    }
}
