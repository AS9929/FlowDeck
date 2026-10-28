import SwiftUI
import UIKit

/// 文档由 UIKit 持有，SwiftUI 只观察加载、脏标记和重置版本，避免每次按键复制及比较全文。
@MainActor
@Observable
final class ConfigurationDocument {
    private(set) var loaded = false
    private(set) var modified = false
    private(set) var revision = 0
    private(set) var byteCount = 0
    @ObservationIgnored private var original = ""
    @ObservationIgnored private var retainedDraft: String?
    @ObservationIgnored weak var textView: UITextView?

    func load(_ text: String) {
        original = text
        retainedDraft = nil
        byteCount = text.utf8.count
        modified = false
        revision += 1
        loaded = true
    }

    var content: String { textView?.text ?? retainedDraft ?? original }
    var initialText: String { retainedDraft ?? original }

    func retainDraft(_ text: String) {
        if modified { retainedDraft = text }
    }

    func didEdit() {
        if !modified { modified = true }
    }

    func restore() {
        retainedDraft = nil
        modified = false
        revision += 1
    }
}

/// 全屏单一滚动视口；TextKit 2 按可见区域排版，不嵌入外层 ScrollView 或玻璃卡片。
struct ConfigurationTextView: UIViewRepresentable {
    let document: ConfigurationDocument
    let readOnly: Bool
    var focusRequest = 0

    func makeCoordinator() -> Coordinator { Coordinator(document: document) }

    func makeUIView(context: Context) -> UITextView {
        let view = ConfigurationCodeView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        view.adjustsFontForContentSizeCategory = true
        view.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: view.font!)
        view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 16, left: 50, bottom: 32, right: 16)
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.keyboardDismissMode = .interactive
        view.isFindInteractionEnabled = true
        view.accessibilityLabel = "配置草稿"
        document.textView = view
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        view.isEditable = !readOnly
        // 只有读取新文档或明确还原时替换全文；普通状态刷新保留选区、滚动和撤销栈。
        if context.coordinator.revision != document.revision {
            (view as? ConfigurationCodeView)?.loadCode(document.initialText)
            view.undoManager?.removeAllActions()
            context.coordinator.revision = document.revision
        }
        if !readOnly, focusRequest != context.coordinator.focusRequest {
            context.coordinator.focusRequest = focusRequest
            // 键盘在 isEditable 生效后进入；不要因普通状态刷新反复抢焦点。
            DispatchQueue.main.async { [weak view] in
                guard let view, view.isEditable else { return }
                view.becomeFirstResponder()
            }
        }
    }

    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        coordinator.document.retainDraft(view.text)
        if coordinator.document.textView === view { coordinator.document.textView = nil }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let document: ConfigurationDocument
        var revision = -1
        var focusRequest = 0

        init(document: ConfigurationDocument) { self.document = document }

        func textViewDidChange(_ textView: UITextView) { document.didEdit() }
    }
}

/// 草稿只在本机编辑，预览继续使用既有配置校验、备份与应用事务。
struct ConfigurationEditorView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(DeviceStatusStore.self) private var status
    @Environment(DeviceStore.self) private var devices
    @Environment(\.dismiss) private var dismiss
    @State private var document = ConfigurationDocument()
    @State private var error: String?
    @State private var preview: ProxyConfigurationView.ImportedConfig?
    @State private var discard = false
    @State private var editing = false
    @State private var focusRequest = 0
    @State private var showSettings = false
    @State private var restoreDraft = false
    @State private var loadedDeviceID: String?
    @Environment(AppRouter.self) private var router

    var body: some View {
        VStack(spacing: 0) {
            if document.loaded {
                let statusLayout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout())
                statusLayout {
                    Label(document.modified ? "未应用的草稿" : editing ? "编辑本机草稿" : "设备上的配置", systemImage: editing ? "pencil" : "doc.text")
                        .fixedSize(horizontal: false, vertical: true)
                    if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                    Text(ByteCountFormatter.string(fromByteCount: Int64(document.byteCount), countStyle: .file))
                }
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.vertical, 12)
                Divider()
                if devices.readOnly {
                    HStack(alignment: .top, spacing: 12) {
                        Label("只读模式已开启，当前不能编辑。", systemImage: "lock")
                        Spacer(minLength: 0)
                        Button("设置") { showSettings = true }
                    }
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 20).padding(.vertical, 10)
                }
                ConfigurationTextView(
                    document: document, readOnly: devices.readOnly || !editing,
                    focusRequest: focusRequest
                )
            } else if let error {
                StatusBanner(title: "无法读取配置", message: error) { Task { await load() } }
                    .padding()
                Spacer()
            } else {
                ProgressView("读取设备配置…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AppBackground())
        .navigationTitle(dynamicTypeSize.isAccessibilitySize ? "配置编辑" : "config.yaml")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(document.modified)
        .toolbar {
            if document.modified {
                ToolbarItem(placement: .topBarLeading) {
                    Button("返回", systemImage: "chevron.left") { discard = true }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(editing ? "结束编辑" : "继续编辑", systemImage: editing ? "checkmark" : "pencil") {
                        setEditing(!editing)
                    }
                    .disabled(devices.readOnly)
                    Button("查找文本", systemImage: "magnifyingglass") {
                        document.textView?.findInteraction?.presentFindNavigator(showingReplace: false)
                    }
                    Button("还原草稿", systemImage: "arrow.uturn.backward") { restoreDraft = true }
                        .disabled(!document.modified)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .disabled(!document.loaded)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(editing || document.modified ? "预览" : "编辑") {
                    if !editing && !document.modified {
                        setEditing(true)
                    } else {
                        document.textView?.resignFirstResponder()
                        preview = .init(name: "App 编辑的 config.yaml", content: document.content)
                    }
                }
                .disabled(!document.loaded || devices.readOnly || status.busy != nil || (editing && !document.modified))
            }
        }
        .confirmationDialog("放弃尚未应用的草稿？", isPresented: $discard, titleVisibility: .visible) {
            Button("放弃并返回", role: .destructive) {
                document.restore()
                router.hasUnsavedConfiguration = false
                dismiss()
            }
            Button("继续编辑", role: .cancel) {}
        }
        .confirmationDialog("还原为打开时的配置？当前草稿将被清除。", isPresented: $restoreDraft, titleVisibility: .visible) {
            Button("还原草稿", role: .destructive) { document.restore() }
        }
        .onChange(of: document.modified) { router.hasUnsavedConfiguration = document.modified }
        .onChange(of: devices.readOnly) {
            if devices.readOnly {
                editing = false
                document.textView?.resignFirstResponder()
            }
        }
        .task { if !document.loaded { await load() } }
        .appPush(isPresented: $showSettings) { AppSettingsView() }
        .appModal(item: $preview) { item in ConfigImportView(name: item.name, content: item.content, expectedDeviceID: loadedDeviceID) }
    }

    private func setEditing(_ enabled: Bool) {
        editing = enabled
        if enabled {
            focusRequest += 1
        } else {
            document.textView?.resignFirstResponder()
        }
    }

    private func load() async {
        error = nil
        do {
            let deviceID = devices.storageID
            let content: String
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--large-config-audit") {
                    // 无凭据的 2 MB 长配置，用于复现首屏排版、查找及键盘交互。
                    content = String(
                        repeating: "# Layout audit: long configuration without credentials\nrules:\n  - DOMAIN,example.com,DIRECT\n", count: 24_000)
                } else {
                    content = try await status.deviceConfig()
                }
            #else
                content = try await status.deviceConfig()
            #endif
            guard !Task.isCancelled else { return }
            guard deviceID == devices.storageID else { throw ManagementError.deviceChanged }
            loadedDeviceID = deviceID
            document.load(content)
        } catch { self.error = error.localizedDescription }
    }
}
