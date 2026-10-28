import UIKit

/// YAML 的轻量词法配色，不作为校验器；每个布局段独立处理，超长段落保持原色。
enum YAMLCodeSyntax {
    enum Kind: Int {
        case string = 1
        case comment
        case key
        case literal
        case number
    }
    struct Token {
        let range: NSRange
        let kind: Kind
    }
    private static let pattern = try! NSRegularExpression(
        pattern: #"("(?:\\.|[^"\\])*"|'(?:''|[^'])*')|(#.*$)|([\w.-]+(?=\s*:\s|\s*:$))|\b(true|false|null|yes|no)\b|(?<![\w.])(-?\d+(?:\.\d+)?)(?![\w.])"#,
        options: [.anchorsMatchLines]
    )

    static func tokens(in text: String) -> [Token] {
        let length = (text as NSString).length
        guard length <= 16_384 else { return [] }
        return pattern.matches(in: text, range: NSRange(location: 0, length: length)).compactMap { match in
            for index in 1...5 where match.range(at: index).location != NSNotFound {
                if let kind = Kind(rawValue: index) { return Token(range: match.range(at: index), kind: kind) }
            }
            return nil
        }
    }

    static func color(_ kind: Kind) -> UIColor {
        switch kind {
        case .string: .systemOrange
        case .comment: .secondaryLabel
        case .key: .systemPurple
        case .literal: .systemCyan
        case .number: .systemTeal
        }
    }
}

/// UTF-16 行起点索引；编辑时只扫描替换片段，后续偏移整体平移，不重复扫描整份 YAML。
struct CodeLineIndex {
    private(set) var starts = [0]

    mutating func reset(_ text: String) {
        starts = [0]
        for (offset, unit) in text.utf16.enumerated() where unit == 10 { starts.append(offset + 1) }
    }

    mutating func replace(_ range: NSRange, with text: String) {
        let end = NSMaxRange(range)
        let delta = text.utf16.count - range.length
        let prefix = starts.filter { $0 <= range.location }
        let inserted = text.utf16.enumerated().compactMap { offset, unit in unit == 10 ? range.location + offset + 1 : nil }
        let suffix = starts.filter { $0 > end }.map { $0 + delta }
        starts = prefix + inserted + suffix
    }

    func line(at offset: Int) -> Int {
        var lower = 0
        var upper = starts.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if starts[middle] <= offset { lower = middle + 1 } else { upper = middle }
        }
        return max(1, lower)
    }
}

/// 保留 TextKit 2 按视口排版；行号只绘制可见段落，高亮使用 rendering attributes，不改草稿或撤销历史。
final class ConfigurationCodeView: UITextView, NSTextStorageDelegate {
    private var lineIndex = CodeLineIndex()
    private let gutter = UIView()
    private var lineLabels: [UILabel] = []
    private var refreshingGutter = false
    private var loadingCode = false
    private var indexReady = false
    private var indexRevision = 0
    private var indexingTask: Task<Void, Never>?
    private var pendingEdits: [(NSRange, String)] = []

    init() {
        let storage = NSTextContentStorage()
        let manager = NSTextLayoutManager()
        storage.addTextLayoutManager(manager)
        let container = NSTextContainer(size: .zero)
        manager.textContainer = container
        super.init(frame: .zero, textContainer: container)
        textStorage.delegate = self
        gutter.isUserInteractionEnabled = false
        gutter.accessibilityElementsHidden = true
        gutter.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.35)
        addSubview(gutter)
        textLayoutManager?.renderingAttributesValidator = { manager, fragment in
            guard let paragraph = fragment.textElement as? NSTextParagraph,
                let content = manager.textContentManager
            else { return }
            // 编辑后旧 token 可能变成普通文字，先清除该段落上一轮的颜色。
            manager.setRenderingAttributes([.foregroundColor: UIColor.label], for: fragment.rangeInElement)
            for token in YAMLCodeSyntax.tokens(in: paragraph.attributedString.string) {
                guard let start = content.location(fragment.rangeInElement.location, offsetBy: token.range.location),
                    let end = content.location(start, offsetBy: token.range.length),
                    let range = NSTextRange(location: start, end: end)
                else { continue }
                manager.setRenderingAttributes([.foregroundColor: YAMLCodeSyntax.color(token.kind)], for: range)
            }
        }
        inputAccessoryView = makeKeyboardTools()
    }

    required init?(coder: NSCoder) { fatalError("仅支持代码创建") }

    func loadCode(_ text: String) {
        loadingCode = true
        self.text = text
        selectedRange = NSRange(location: 0, length: 0)
        loadingCode = false
        indexReady = false
        pendingEdits.removeAll()
        indexRevision += 1
        let revision = indexRevision
        indexingTask?.cancel()
        // 首次索引放在后台，避免几 MB 文档的扫描阻塞首屏；期间的输入按顺序补到索引。
        indexingTask = Task.detached(priority: .userInitiated) { [weak self] in
            var index = CodeLineIndex()
            index.reset(text)
            guard !Task.isCancelled else { return }
            let completed = index
            await MainActor.run { [weak self] in
                guard let self, self.indexRevision == revision else { return }
                self.lineIndex = completed
                for (range, replacement) in self.pendingEdits {
                    self.lineIndex.replace(range, with: replacement)
                }
                self.pendingEdits.removeAll()
                self.indexReady = true
                self.setNeedsLayout()
            }
        }
        setNeedsLayout()
    }

    deinit { indexingTask?.cancel() }

    func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions, range editedRange: NSRange, changeInLength delta: Int
    ) {
        guard !loadingCode, editedMask.contains(.editedCharacters) else { return }
        let oldRange = NSRange(location: editedRange.location, length: editedRange.length - delta)
        let replacement = (textStorage.string as NSString).substring(with: editedRange)
        if indexReady {
            lineIndex.replace(oldRange, with: replacement)
        } else {
            pendingEdits.append((oldRange, replacement))
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard indexReady else {
            for label in lineLabels { label.isHidden = true }
            return
        }
        guard !refreshingGutter, let manager = textLayoutManager,
            let content = manager.textContentManager,
            let viewport = manager.textViewportLayoutController.viewportRange
        else { return }
        refreshingGutter = true
        defer { refreshingGutter = false }
        gutter.frame = CGRect(x: contentOffset.x, y: contentOffset.y, width: 44, height: bounds.height)
        var used = 0
        manager.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            let frame = fragment.layoutFragmentFrame
            let y = frame.minY + self.textContainerInset.top - self.contentOffset.y
            if y > self.bounds.height { return false }
            guard y + frame.height >= 0, let line = fragment.textLineFragments.first else { return true }
            if used == self.lineLabels.count {
                let label = UILabel()
                label.textAlignment = .right
                label.textColor = .tertiaryLabel
                self.gutter.addSubview(label)
                self.lineLabels.append(label)
            }
            let label = self.lineLabels[used]
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            label.text = String(self.lineIndex.line(at: offset))
            label.font = .monospacedDigitSystemFont(ofSize: min(18, (self.font?.pointSize ?? 14) * 0.8), weight: .regular)
            label.frame = CGRect(x: 2, y: y + line.typographicBounds.minY, width: 34, height: line.typographicBounds.height)
            label.isHidden = false
            used += 1
            return true
        }
        for label in lineLabels.dropFirst(used) { label.isHidden = true }
        bringSubviewToFront(gutter)
    }

    override func insertText(_ text: String) {
        guard isEditable else { return }
        if text == "\n" {
            let source = textStorage.string as NSString
            let cursor = min(selectedRange.location, source.length)
            let line = source.lineRange(for: NSRange(location: cursor, length: 0))
            let prefix = source.substring(with: NSRange(location: line.location, length: cursor - line.location))
            let indentation = prefix.prefix { $0 == " " || $0 == "\t" }
            super.insertText("\n" + indentation)
        } else {
            super.insertText(text)
        }
    }

    private func makeKeyboardTools() -> UIView {
        let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: 320, height: 52), inputViewStyle: .keyboard)
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(scroll)
        // 查找与收起键盘始终固定在右侧，窄屏只滚动符号区。
        let pinned = UIStackView()
        pinned.axis = .horizontal
        pinned.spacing = 4
        pinned.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(pinned)
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: bar.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: pinned.leadingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: bar.topAnchor), scroll.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            pinned.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            pinned.topAnchor.constraint(equalTo: bar.topAnchor, constant: 4), pinned.heightAnchor.constraint(equalToConstant: 44),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -4),
            stack.heightAnchor.constraint(equalToConstant: 44),
        ])
        func tool(_ title: String, symbol: String? = nil, fixed: Bool = false, action: @escaping (ConfigurationCodeView) -> Void) {
            var config = UIButton.Configuration.tinted()
            config.baseForegroundColor = .label
            config.cornerStyle = .medium
            config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var result = attributes
                result.font = .monospacedSystemFont(ofSize: 17, weight: .medium)
                return result
            }
            if let symbol { config.image = UIImage(systemName: symbol) } else { config.title = title }
            let button = UIButton(
                configuration: config,
                primaryAction: UIAction { [weak self] _ in
                    guard let self else { return }
                    action(self)
                })
            button.accessibilityLabel = title
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
            (fixed ? pinned : stack).addArrangedSubview(button)
        }
        tool("撤销", symbol: "arrow.uturn.backward") { if $0.isEditable { $0.undoManager?.undo() } }
        tool("重做", symbol: "arrow.uturn.forward") { if $0.isEditable { $0.undoManager?.redo() } }
        tool("缩进", symbol: "increase.indent") { $0.insertText("  ") }
        for symbol in [":", "-", "#", "\""] { tool(symbol) { $0.insertText(symbol) } }
        tool("查找", symbol: "magnifyingglass", fixed: true) { $0.findInteraction?.presentFindNavigator(showingReplace: false) }
        tool("收起键盘", symbol: "keyboard.chevron.compact.down", fixed: true) { $0.resignFirstResponder() }
        return bar
    }
}
