import SwiftUI

/// F50 射频编辑采用显式提交和独立回读；切换设备立即丢弃旧草稿及异步结果。
struct UFIRadioView: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(ManagementStore.self) private var manager
    @State private var state: UFIRadioState?
    @State private var technology: UFIRadioTechnology = .lte
    @State private var bands: Set<Int> = []
    @State private var cellTechnology: UFIRadioTechnology = .nr
    @State private var pci = ""
    @State private var frequency = ""
    @State private var password = ""
    @State private var revision = 0
    @State private var loading = false
    @State private var credentialWarning: String?
    @State private var error: String?
    @State private var notice: String?
    @State private var action: Action?

    private enum Action {
        case bands, automatic, cell, unlock
        var title: String {
            switch self {
            case .bands: "应用所选频段"
            case .automatic: "恢复自动频段"
            case .cell: "锁定小区"
            case .unlock: "解除小区锁定"
            }
        }
    }

    private var busy: Bool { loading || manager.working }
    private var writable: Bool { !busy && !devices.readOnly && state != nil }
    private var options: [Int] {
        (technology == .lte ? UFIRadioState.lteOptions : state?.supportedNR ?? []).sorted()
    }

    var body: some View {
        DetailSheet(title: "频段与小区", closeDisabled: busy) {
            DeviceDetailSummary(
                symbol: "antenna.radiowaves.left.and.right", title: "射频控制",
                subtitle: "频段限制与小区锁定分别管理，每次操作后核对设备回读。")
            if loading { ProgressView("读取射频状态…") }
            if let credentialWarning {
                Text(credentialWarning).font(.footnote).foregroundStyle(.orange)
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
            if let notice { Label(notice, systemImage: "checkmark.circle").font(.footnote) }
            if let state {
                bandEditor(state)
                cellEditor(state)
            }
            GlassSection("原厂后台连接") {
                SecureField("原厂网页登录密码", text: $password).textContentType(.password)
                Button("验证并刷新", systemImage: "arrow.clockwise") { Task { await load() } }
                    .disabled(busy || password.isEmpty)
            }.disabled(busy)
        }
        .task(id: devices.clientRevision) {
            credentialWarning = nil
            revision = devices.clientRevision
            state = nil
            loading = false
            bands = []
            pci = ""
            frequency = ""
            action = nil
            error = nil
            notice = nil
            password = devices.current.map { devices.factoryPassword(for: $0) } ?? ""
            if !password.isEmpty { await load() }
        }
        .confirmationDialog(
            action?.title ?? "确认射频设置",
            isPresented: Binding(
                get: { action != nil }, set: { if !$0 { action = nil } }
            ), titleVisibility: .visible
        ) {
            if let action {
                Button(action.title, role: .destructive) { Task { await perform(action) } }
            }
        } message: {
            Text("设备会重新注册蜂窝网络，可能暂时断网。保留 Wi-Fi 管理连接；无信号时分别恢复自动频段、解除小区锁定。操作只提交一次。")
        }
    }

    private func bandEditor(_ state: UFIRadioState) -> some View {
        GlassSection("允许使用的频段") {
            Picker("制式", selection: $technology) {
                ForEach(UFIRadioTechnology.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).disabled(busy)
                .onChange(of: technology) { _, value in bands = state.selected(value) }
            Text(state.selected(technology).isEmpty ? "当前：自动选择" : "当前：" + summary(state.selected(technology)))
                .font(.subheadline.weight(.semibold))
            if technology == .nr && state.supportedNR == nil {
                Text("设备未返回支持的 5G 频段列表。仍可恢复自动选择。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 10)], spacing: 10) {
                ForEach(options, id: \.self) { band in
                    Button {
                        if bands.contains(band) { bands.remove(band) } else { bands.insert(band) }
                    } label: {
                        Text(technology.prefix + String(band)).font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(
                                bands.contains(band) ? Color.accentColor.opacity(0.24) : Color.secondary.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 12)
                            )
                            .overlay(alignment: .topTrailing) {
                                if bands.contains(band) { Image(systemName: "checkmark").font(.caption2).padding(4) }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(technology.prefix + String(band))
                    .accessibilityValue(bands.contains(band) ? "已选择" : "未选择")
                    .disabled(!writable)
                }
            }
            Button("应用所选频段", systemImage: "checkmark") { action = .bands }
                .disabled(
                    !writable || bands.isEmpty || bands == state.selected(technology)
                        || !bands.isSubset(of: Set(options)))
            Button("恢复自动选择", systemImage: "arrow.uturn.backward") { action = .automatic }
                .disabled(!writable || state.selected(technology).isEmpty)
        } footer: {
            Text("一次仅修改当前制式。5G 选项来自设备支持列表；4G 选项与 F50 的 UFI 管理页一致。")
        }
    }

    private func cellEditor(_ state: UFIRadioState) -> some View {
        GlassSection("小区锁定") {
            if state.cells.isEmpty {
                Label("未锁定小区", systemImage: "lock.open").font(.headline)
                Picker("制式", selection: $cellTechnology) {
                    ForEach(UFIRadioTechnology.allCases) { Text($0.title).tag($0) }
                }.disabled(!writable)
                FormField("PCI") { TextField("物理小区编号", text: $pci).keyboardType(.numberPad) }
                    .disabled(!writable)
                FormField(cellTechnology == .lte ? "EARFCN" : "NR-ARFCN") {
                    TextField("频点编号，不是 MHz", text: $frequency).keyboardType(.numberPad)
                }.disabled(!writable)
                Button("锁定此小区", systemImage: "lock") { action = .cell }
                    .disabled(!writable || pci.isEmpty || frequency.isEmpty)
            } else {
                ForEach(state.cells) { cell in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(cell.technology.title, systemImage: "lock.fill").font(.headline)
                        Text("PCI \(cell.pci) · ARFCN \(cell.frequency)").font(.subheadline).textSelection(.enabled)
                    }
                }
                Button("解除全部小区锁定", systemImage: "lock.open") { action = .unlock }.disabled(!writable)
            }
        } footer: {
            Text("只使用已确认的制式、PCI 与频点。锁定不保证更快；离开当前覆盖范围前应解除。")
        }
    }

    private func summary(_ values: Set<Int>) -> String {
        values.sorted().map { technology.prefix + String($0) }.joined(separator: "、")
    }

    private func api() throws -> any UFIRadioAPI {
        guard let client = devices.webClient as? any UFIRadioAPI else { throw ManagementError.deviceChanged }
        return client
    }

    private func load() async {
        guard !loading else { return }
        let expected = revision
        loading = true
        defer { if expected == devices.clientRevision { loading = false } }
        do {
            let value = try await api().radioState(password: password)
            guard expected == devices.clientRevision else { return }
            state = value
            bands = value.selected(technology)
            credentialWarning = try DeviceServiceContext(devices, revision: expected).rememberFactoryPasswordWarning(password)
            error = nil
        } catch {
            guard expected == devices.clientRevision else { return }
            state = nil
            self.error = error.localizedDescription
        }
    }

    private func perform(_ action: Action) async {
        guard writable, let original = state else { return }
        let expected = revision
        let password = password
        let selectedBands = bands
        let technology = technology
        let cell: UFILockedCell?
        if action == .cell {
            guard let pci = Int(pci), let frequency = Int(frequency) else {
                error = "PCI 与频点须为整数。"
                self.action = nil
                return
            }
            cell = UFILockedCell(technology: cellTechnology, pci: pci, frequency: frequency)
        } else {
            cell = nil
        }
        self.action = nil
        notice = nil
        error = nil
        await manager.run("F50 " + action.title) {
            let client = try await manager.verifiedService(
                (any UFIRadioAPI).self, devices: devices, revision: expected, capability: .factoryControl)
            switch action {
            case .bands, .automatic:
                try await client.setRadioBands(
                    action == .automatic ? [] : selectedBands, technology: technology,
                    replacing: original, password: password)
            case .cell, .unlock:
                try await client.setRadioCell(cell, replacing: original, password: password)
            }
        }
        guard expected == devices.clientRevision else { return }
        let failure = manager.error
        await load()
        error = failure ?? error
        if error == nil { notice = "已完成操作并确认设备回读" }
    }
}
