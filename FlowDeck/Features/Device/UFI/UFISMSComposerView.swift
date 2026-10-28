import SwiftUI

/// 短信发送独立取消/完成流程；结果未知时锁定重发，避免用户重复产生短信费用。
struct UFISMSComposerView: View {
    let password: String
    var initialNumber = ""
    var initialText = ""
    @Environment(DeviceStore.self) private var devices
    @Environment(ManagementStore.self) private var manager
    @Environment(\.scenePhase) private var scenePhase
    @State private var number = ""
    @State private var text = ""
    @State private var error: String?
    @State private var notice: String?
    @State private var confirm = false
    @State private var submitted = false
    @State private var revision = 0
    @State private var draft: UFISMSDraft?
    @State private var draftDeviceID = ""

    var body: some View {
        DetailSheet(title: "写短信", closeDisabled: manager.working) {
            GlassSection("收件人") {
                TextField("电话号码", text: $number).keyboardType(.phonePad)
            }
            GlassSection("内容") {
                TextEditor(text: $text).frame(minHeight: 180).scrollContentBackground(.hidden)
                Text("\(text.utf16.count) / 500 字符 · Unicode 编码可能拆分多条计费")
                    .font(.caption).foregroundStyle(.secondary)
            }
            GlassSection("本机草稿") {
                Text("仅保存在本机钥匙串，不会写入 F50，也不会自动发送。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("保存草稿", systemImage: "square.and.arrow.down") {
                    do {
                        let value = UFISMSDraft(number: number, text: text)
                        try value.save(deviceID: draftDeviceID)
                        draft = value
                        notice = "草稿已保存在本机"
                    } catch { self.error = error.localizedDescription }
                }.disabled(submitted || text.isEmpty)
                if let draft {
                    Button("恢复本机草稿", systemImage: "doc.text") {
                        number = draft.number
                        text = draft.text
                    }.disabled(submitted)
                    Button("删除本机草稿", systemImage: "trash", role: .destructive) {
                        do {
                            try UFISMSDraft.remove(deviceID: draftDeviceID)
                            self.draft = nil
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
            if let notice { Label(notice, systemImage: "checkmark.circle").font(.footnote) }
            Button("发送短信", systemImage: "paperplane.fill") {
                do {
                    _ = try UFISMSComposer.form(number: number, text: text)
                    confirm = true
                } catch { self.error = error.localizedDescription }
            }.disabled(manager.working || devices.readOnly || submitted || number.isEmpty || text.isEmpty)
            if submitted, notice == nil {
                Text("本页不允许重复发送。请先在原厂发件箱确认结果，再决定是否新建短信。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .disabled(manager.working || revision != devices.clientRevision)
        .task {
            revision = devices.clientRevision
            draftDeviceID = devices.storageID
            number = initialNumber
            text = initialText
            draft = UFISMSDraft.load(deviceID: draftDeviceID)
        }
        .confirmationDialog("发送到 \(number)？", isPresented: $confirm, titleVisibility: .visible) {
            Button("确认发送") { Task { await send() } }
        } message: {
            Text("使用 F50 的 SIM 卡发送，运营商可能计费。")
        }
        .opacity(scenePhase == .active ? 1 : 0)
        .accessibilityHidden(scenePhase != .active)
    }

    private func send() async {
        guard !manager.working, !submitted else { return }
        error = nil
        notice = nil
        await manager.run("发送 F50 短信") {
            _ = try await manager.verifiedAPI(devices, capability: .factoryControl)
            guard revision == devices.clientRevision, let api = devices.webClient as? any UFIMessagesService else {
                throw ManagementError.deviceChanged
            }
            // 即使 POST 因断线结果未知，也不能直接允许再次发送。
            submitted = true
            try await api.sendMessage(number: number, text: text, password: password)
        }
        guard revision == devices.clientRevision else { return }
        error = manager.error
        if error == nil { notice = "设备已报告发送完成" }
    }
}
