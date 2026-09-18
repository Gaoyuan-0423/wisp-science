import AppKit
import SwiftUI
import XCTest
import WispProjectBrowser
@testable import WispProjectBrowserUI

final class NativeSelectionTests: XCTestCase {
    @MainActor func testMenuRetainsSelectedTextAndOriginalCallbackAcrossStreamingUpdate() {
        let view = NativeMessageTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        view.apply(NSAttributedString(string: "prefix 🧬 selected suffix"))
        view.setSelectedRange((view.string as NSString).range(of: "🧬 selected"))
        var original: [String] = []; var newer: [String] = []
        view.quote = { original.append("quote:" + $0) }; view.save = { original.append("save:" + $0) }
        let items = view.selectionActions()
        XCTAssertEqual(items.map(\.title), ["引用到侧聊", "收藏划线"])
        view.apply(NSAttributedString(string: "new stream"))
        view.quote = { newer.append($0) }; view.save = { newer.append($0) }
        for item in items { (item.representedObject as? NativeSelectionAction)?.invoke(nil) }
        XCTAssertEqual(original, ["quote:🧬 selected", "save:🧬 selected"])
        XCTAssertTrue(newer.isEmpty)
    }
    @MainActor func testQuoteOnlyPreviewDoesNotOfferTranscriptHighlightSave() {
        let view = NativeMessageTextView(frame: .zero)
        view.apply(NSAttributedString(string: "file excerpt"))
        view.setSelectedRange(NSRange(location: 0, length: 4)); view.quote = { _ in }
        XCTAssertEqual(view.selectionActions().map(\.title), ["引用到侧聊"])
        view.quote = nil
        XCTAssertTrue(view.selectionActions().isEmpty)
    }
    @MainActor func testEmptyAndWhitespaceSelectionsHaveNoCustomActions() {
        let view = NativeMessageTextView(frame: .zero)
        view.apply(NSAttributedString(string: " \ntext")); view.quote = { _ in }; view.save = { _ in }
        view.setSelectedRange(NSRange(location: 0, length: 0)); XCTAssertTrue(view.selectionActions().isEmpty)
        view.setSelectedRange(NSRange(location: 0, length: 2)); XCTAssertTrue(view.selectionActions().isEmpty)
        view.setSelectedRange(NSRange(location: 2, length: 4)); XCTAssertEqual(view.selectionActions().count, 2)
    }
    @MainActor func testPersistentMarksCoverEveryOccurrenceAndKeepMarkdownTraits() throws {
        let text = try AttributedString(markdown: "**🧬 A B** then 🧬AB", options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        let marked = NativeSelectableMessage.content(text, saved: ["🧬AB"], scheme: .light)
        let first = (marked.string as NSString).range(of: "🧬 A B")
        let second = (marked.string as NSString).range(of: "🧬AB")
        XCTAssertNotNil(marked.attribute(.underlineStyle, at: first.location, effectiveRange: nil))
        XCTAssertNotNil(marked.attribute(.underlineStyle, at: second.location, effectiveRange: nil))
        let font = try XCTUnwrap(marked.attribute(.font, at: first.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        let plain = NativeSelectableMessage.content(text, saved: [], scheme: .light)
        XCTAssertNil(plain.attribute(.underlineStyle, at: first.location, effectiveRange: nil))
    }
    @MainActor func testToolOutputUsesConfiguredCodeFontAndSize() throws {
        let defaults = UserDefaults.standard
        let sizeKey = "nativeSettings.code_font_size", familyKey = "nativeSettings.code_font_family"
        let oldSize = defaults.object(forKey: sizeKey), oldFamily = defaults.object(forKey: familyKey)
        defer {
            if let oldSize { defaults.set(oldSize, forKey: sizeKey) } else { defaults.removeObject(forKey: sizeKey) }
            if let oldFamily { defaults.set(oldFamily, forKey: familyKey) } else { defaults.removeObject(forKey: familyKey) }
        }
        let chosen = NSFont.monospacedSystemFont(ofSize: 19, weight: .regular)
        defaults.set(19, forKey: sizeKey); defaults.set(chosen.fontName, forKey: familyKey)
        let content = NativeSelectableMessage.content(AttributedString("print(1)"), saved: [], scheme: .light, monospaced: true)
        let font = try XCTUnwrap(content.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, 19); XCTAssertEqual(font.fontName, chosen.fontName)
    }
    @MainActor func testToolOutputRemainsLiteralMonospacedAndSelectable() throws {
        let source = "**literal**\n🧬 result = [1, 2]"
        let content = NativeSelectableMessage.content(AttributedString(source), saved: ["🧬 result"], scheme: .dark, monospaced: true)
        XCTAssertEqual(content.string, source)
        let font = try XCTUnwrap(content.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.isFixedPitch)
        let range = (source as NSString).range(of: "🧬 result")
        XCTAssertNotNil(content.attribute(.underlineStyle, at: range.location, effectiveRange: nil))
        let view = NativeMessageTextView(frame: .zero)
        view.apply(content); view.setSelectedRange(range)
        var quotes: [String] = []; var saves: [String] = []
        view.quote = { quotes.append($0) }; view.save = { saves.append($0) }
        for action in view.selectionActions() { (action.representedObject as? NativeSelectionAction)?.invoke(nil) }
        XCTAssertEqual(quotes, ["🧬 result"]); XCTAssertEqual(saves, ["🧬 result"])
    }
    @MainActor func testMarkRefreshPreservesSelectedRangeAndText() throws {
        let view = NativeMessageTextView(frame: .zero)
        let text = AttributedString("selected text")
        view.apply(NativeSelectableMessage.content(text, saved: [], scheme: .light))
        view.setSelectedRange(NSRange(location: 0, length: 8))
        view.apply(NativeSelectableMessage.content(text, saved: ["text"], scheme: .dark))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 8))
        XCTAssertEqual(view.string, "selected text")
    }
    @MainActor func testRenderSelectableMarkdownWithSavedMarks() throws {
        guard let directory = ProcessInfo.processInfo.environment["WISP_NATIVE_SNAPSHOT_DIR"] else { throw XCTSkip("Opt-in rendering") }
        let text = try AttributedString(markdown: "样本 **质量合格**。\n这是一段较长的研究说明，用于检查窄窗口里的自动换行。\n再次检查：质量 合格。", options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        for (name, scheme) in [("selection-light", ColorScheme.light), ("selection-dark", ColorScheme.dark)] {
            let content = NativeSelectableMessage(text: text, saved: ["质量合格"], quote: { _ in }, save: { _ in })
                .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(WispDesign.color("bg-elev", scheme)).environment(\.colorScheme, scheme)
            let view = NSHostingView(rootView: content)
            view.frame = NSRect(x: 0, y: 0, width: 300, height: 220); view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }
}
