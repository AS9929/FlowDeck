import SwiftUI
import UIKit
import XCTest

@testable import FlowDeck

/// 大文档编辑与视图重建的回归；只使用合成配置，不连接真实设备。
@MainActor
final class ConfigurationEditorTests: XCTestCase {
    func testDraftSurvivesViewRemovalAndRestoreUsesOriginal() {
        let document = ConfigurationDocument()
        document.load("mode: rule\n")
        let view = UITextView(usingTextLayoutManager: true)
        document.textView = view
        view.text = "mode: global\n"
        document.didEdit()
        document.retainDraft(view.text)
        document.textView = nil
        XCTAssertEqual(document.content, "mode: global\n")
        XCTAssertTrue(document.modified)
        document.restore()
        XCTAssertFalse(document.modified)
        XCTAssertEqual(document.initialText, "mode: rule\n")
    }

    func testEditingDoesNotInvalidateDocumentRevision() {
        let document = ConfigurationDocument()
        document.load("mode: rule")
        let revision = document.revision
        for _ in 0..<100 { document.didEdit() }
        XCTAssertEqual(document.revision, revision)
        document.restore()
        XCTAssertEqual(document.revision, revision + 1)
    }

    func testEditorCanFocusAndInsertTextWithoutLosingDraftOnReadOnlyChange() async {
        let document = ConfigurationDocument()
        document.load("mode: rule")
        let host = UIHostingController(rootView: ConfigurationTextView(document: document, readOnly: true))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        // 等待实际视图状态，避免把固定 50ms 的调度时机当作编辑器契约。
        let readOnlyReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            document.textView?.isEditable == false
        }, object: nil)
        await fulfillment(of: [readOnlyReady], timeout: 2)
        XCTAssertEqual(document.textView?.isEditable, false)

        host.rootView = ConfigurationTextView(document: document, readOnly: false, focusRequest: 1)
        host.view.layoutIfNeeded()
        // 等待实际视图状态，避免把固定 50ms 的调度时机当作编辑器契约。
        let focusReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            document.textView?.isFirstResponder == true
        }, object: nil)
        await fulfillment(of: [focusReady], timeout: 2)
        XCTAssertEqual(document.textView?.isEditable, true)
        XCTAssertEqual(document.textView?.isFirstResponder, true)
        document.textView?.selectedRange = NSRange(location: 10, length: 0)
        document.textView?.insertText(" # draft")
        XCTAssertTrue(document.modified)
        XCTAssertTrue(document.content.contains("# draft"))
        let revision = document.revision

        host.rootView = ConfigurationTextView(document: document, readOnly: true)
        host.view.layoutIfNeeded()
        // 等待实际视图状态，避免把固定 50ms 的调度时机当作编辑器契约。
        let readOnlyRestored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            document.textView?.isEditable == false
        }, object: nil)
        await fulfillment(of: [readOnlyRestored], timeout: 2)
        XCTAssertEqual(document.textView?.isEditable, false)
        XCTAssertEqual(document.revision, revision)
        XCTAssertTrue(document.content.contains("# draft"))
        window.isHidden = true
    }

    func testLineIndexHandlesUnicodeReplacementAndDeletedNewlines() {
        var index = CodeLineIndex()
        var value = "name: 🇯🇵\nmode: rule\n  port: 7890\n"
        index.reset(value)
        let changes: [(NSRange, String)] = [
            (NSRange(location: 0, length: 0), "# header\n"),
            (NSRange(location: 5, length: 8), "中\n文"),
            (NSRange(location: 2, length: 6), ""),
        ]
        for (range, replacement) in changes {
            index.replace(range, with: replacement)
            value = (value as NSString).replacingCharacters(in: range, with: replacement)
            var rebuilt = CodeLineIndex()
            rebuilt.reset(value)
            XCTAssertEqual(index.starts, rebuilt.starts)
            for offset in 0...(value as NSString).length {
                XCTAssertEqual(index.line(at: offset), rebuilt.line(at: offset))
            }
        }
    }

    func testSyntaxDoesNotTreatQuotedHashAsCommentAndBoundsLongParagraph() {
        let value = "name: \"# true 123\" # comment\nactive: true\nport: 7890"
        let tokens = YAMLCodeSyntax.tokens(in: value)
        XCTAssertEqual(tokens.filter { $0.kind == .comment }.count, 1)
        XCTAssertEqual(tokens.filter { $0.kind == .literal }.count, 1)
        XCTAssertEqual(tokens.filter { $0.kind == .number }.count, 1)
        XCTAssertTrue(YAMLCodeSyntax.tokens(in: String(repeating: "x", count: 16_385)).isEmpty)
    }

    func testCodeViewAutoIndentUndoAndTextKit2RemainIntact() {
        let view = ConfigurationCodeView()
        view.isEditable = true
        view.loadCode("root:\n  key: true")
        view.selectedRange = NSRange(location: (view.text as NSString).length, length: 0)
        view.insertText("\n")
        XCTAssertTrue(view.text.hasSuffix("\n  "))
        XCTAssertNotNil(view.textLayoutManager)
        XCTAssertNotNil(view.inputAccessoryView)
        view.undoManager?.undo()
        XCTAssertEqual(view.text, "root:\n  key: true")
        view.undoManager?.redo()
        XCTAssertTrue(view.text.hasSuffix("\n  "))
        view.isEditable = false
        view.insertText("blocked")
        XCTAssertFalse(view.text.contains("blocked"))
    }

    func testLargeDocumentViewportPerformance() {
        let content = String(repeating: "# Long config audit\nrules:\n  - DOMAIN,example.com,DIRECT\n", count: 40_000)
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric()], options: options) {
            let document = ConfigurationDocument()
            document.load(content)
            let host = UIHostingController(rootView: ConfigurationTextView(document: document, readOnly: false))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            window.isHidden = true
            XCTAssertEqual(document.textView?.text.utf8.count, content.utf8.count)
            XCTAssertNotNil(document.textView?.textLayoutManager)
        }
    }
}
