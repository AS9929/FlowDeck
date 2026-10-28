import SwiftUI

/// 多设备管理独立于当前设备设置；新增始终使用新 ID，编辑保留已有凭据归属。
struct DeviceLibraryView: View {
    @Environment(DeviceStore.self) private var devices
    @Environment(ManagementStore.self) private var manager
    @Environment(DeviceStatusStore.self) private var status
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var presented = false
    @State private var pairing: PairingRequest?
    @State private var removing: DeviceProfile?
    @State private var matching = false
    @State private var onboarding = false

    private struct PairingRequest: Identifiable {
        let id = UUID()
        let device: DeviceProfile?
    }

    private var busy: Bool { manager.working || status.busy != nil || matching || DeviceOperationGate.active != nil }

    private func reachability(_ device: DeviceProfile) -> String {
        if device.id == devices.currentID, status.snapshotError == nil,
            let date = status.snapshotAt, Date().timeIntervalSince(date) < 15
        {
            return "在线"
        }
        if let date = devices.reachableAt[device.id] {
            return "上次连接 " + date.formatted(date: .omitted, time: .shortened)
        }
        return "尚未检查连接"
    }

    /// 辅助字号下将图标移到标题行，地址和身份信息使用整行宽度。
    @ViewBuilder
    private func deviceSummary(_ device: DeviceProfile) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    FeatureIcon(symbol: "wifi.router")
                    Text(device.name)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    selectionMark(device)
                }
                deviceMetadata(device)
            }
        } else {
            HStack(spacing: 12) {
                FeatureIcon(symbol: "wifi.router")
                VStack(alignment: .leading, spacing: 5) {
                    Text(device.name)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    deviceMetadata(device)
                }
                Spacer(minLength: 8)
                selectionMark(device)
            }
        }
    }

    private func deviceMetadata(_ device: DeviceProfile) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(device.host).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            // 元数据使用紧凑图文，不继承 List 的行级 Label 图标列宽。
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: device.needsVerification ? "exclamationmark.shield" : "checkmark.shield")
                    .accessibilityHidden(true)
                Text(device.needsVerification ? "已添加 · 待验证身份" : "身份已验证")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(device.needsVerification ? Color.orange : Color.secondary)
            .accessibilityElement(children: .combine)
            if device.id == devices.currentID {
                Text(devices.demoMode ? "当前选择 · 演示模式" : "当前选择 · \(reachability(device))")
                    .font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func selectionMark(_ device: DeviceProfile) -> some View {
        if device.id == devices.currentID {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)
        }
    }

    var body: some View {
        List {
            if let warning = devices.storageWarning {
                Text(warning).font(.footnote).foregroundStyle(.orange)
            }
            ForEach(devices.devices) { device in
                Section {
                    VStack(spacing: 16) {
                        Button {
                            devices.select(device)
                        } label: {
                            deviceSummary(device)
                                .padding(.vertical, 4)
                        }
                        .disabled(busy)
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("编辑连接") { pairing = PairingRequest(device: device) }
                                .disabled(busy)
                            Button("移除设备", role: .destructive) { removing = device }
                                .disabled(busy)
                        }
                        Divider()
                        Button {
                            pairing = PairingRequest(device: device)
                        } label: {
                            Label(device.needsVerification ? "验证连接" : "连接与凭据", systemImage: "checkmark.shield")
                        }
                        .disabled(busy)
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("移除", role: .destructive) { removing = device }
                            .disabled(busy)
                        Button("编辑") { pairing = PairingRequest(device: device) }
                            .tint(.blue).disabled(busy)
                    }
                    .padding(.vertical, 8)
                    .listRowBackground(GlassListBackground())
                    .listRowSeparator(.hidden)
                }
            }
            if devices.devices.isEmpty {
                ContentUnavailableView("添加设备", systemImage: "wifi.router", description: Text("连接设备 Wi-Fi 后，点击右上角 + 验证并保存。"))
                    .listRowBackground(Color.clear)
            }
            Text("当前选择仅决定管理目标；在线状态以最近一次身份读取为准。左滑可编辑或移除。")
                .font(.footnote.weight(.medium)).foregroundStyle(.secondary).listRowBackground(Color.clear)
            Section {
                Button {
                    matching = true
                    Task {
                        await devices.matchConnectedDevice()
                        matching = false
                    }
                } label: {
                    HStack {
                        Label("检查连接并识别设备", systemImage: "dot.radiowaves.left.and.right")
                        if matching { ProgressView() }
                    }
                }
                .disabled(busy || devices.demoMode)
                .listRowBackground(GlassListBackground())
                .listRowSeparator(.hidden)
                if let message = devices.matchingMessage {
                    Text(message).font(.footnote.weight(.medium)).foregroundStyle(.secondary).listRowBackground(Color.clear)
                }
            }
        }
        .listSectionSpacing(12)
        .contentMargins(.top, 12, for: .scrollContent)
        .nativeSettingsPage(title: "我的设备", inline: true)
        .toolbar {
            if presented {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    onboarding = true
                } label: {
                    Label("添加设备", systemImage: "plus")
                }
                .disabled(busy)
            }
        }
        .appPush(isPresented: $onboarding) {
            DeviceOnboardingView()
        }
        .appModal(item: $pairing) { request in
            PairingView(device: request.device, isNew: request.device == nil)
        }
        .confirmationDialog("移除本机保存的设备？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            if let removing {
                Button("移除 \(removing.name)", role: .destructive) { devices.remove(removing) }
            }
        } message: {
            Text("删除本机连接与凭据；同一设备的最后一条记录移除后，也会清除本机恢复副本、短信草稿和偏好。不会更改路由器。")
        }
    }
}
