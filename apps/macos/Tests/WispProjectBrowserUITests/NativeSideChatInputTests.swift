import AppKit
import XCTest
import WispProjectBrowser
@testable import WispProjectBrowserUI

final class NativeSideChatInputTests: XCTestCase {
    @MainActor private func editor() -> (NSWindow, NativeSideChatTextView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let editor = NativeSideChatTextView(frame: NSRect(x: 0, y: 0, width: 340, height: 100))
        editor.isRichText = false; editor.isEditable = true; editor.isSelectable = true
        window.contentView = editor
        XCTAssertTrue(window.makeFirstResponder(editor))
        return (window, editor)
    }
    @MainActor private func enter(_ window: NSWindow, flags: NSEvent.ModifierFlags = [], keypad: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: keypad ? 76 : 36)!
    }
    func testReturnPolicyAlwaysLetsIMEConfirmComposition() {
        XCTAssertEqual(NativeSideChatReturnAction.resolve(shift: false, composing: false), .send)
        XCTAssertEqual(NativeSideChatReturnAction.resolve(shift: true, composing: false), .newline)
        XCTAssertEqual(NativeSideChatReturnAction.resolve(shift: false, composing: true), .composition)
        XCTAssertEqual(NativeSideChatReturnAction.resolve(shift: true, composing: true), .composition)
    }
    @MainActor func testReturnSubmitsAndBusyReturnDoesNotInsertOrResubmit() {
        let (window, editor) = editor(); defer { window.close() }
        var sends = 0; var allowed = true
        editor.canSubmit = { allowed }; editor.submit = { sends += 1 }
        editor.apply("question")
        editor.keyDown(with: enter(window))
        XCTAssertEqual(sends, 1); XCTAssertEqual(editor.string, "question")
        allowed = false
        editor.keyDown(with: enter(window)); editor.keyDown(with: enter(window, keypad: true))
        XCTAssertEqual(sends, 1); XCTAssertEqual(editor.string, "question")
    }
    @MainActor func testShiftReturnInsertsNewlineAndNotifiesBinding() {
        let (window, editor) = editor(); defer { window.close() }
        var sends = 0; var changed: String?
        editor.canSubmit = { true }; editor.submit = { sends += 1 }; editor.onChange = { changed = $0 }
        editor.apply("line")
        editor.keyDown(with: enter(window, flags: .shift))
        XCTAssertEqual(sends, 0)
        XCTAssertEqual(editor.string, "line\n")
        XCTAssertEqual(changed, "line\n")
    }
    @MainActor func testIMEConfirmationAndExternalUpdatesDoNotSendOrReplaceMarkedText() {
        let (window, editor) = editor(); defer { window.close() }
        var sends = 0
        editor.canSubmit = { true }; editor.submit = { sends += 1 }
        editor.setMarkedText("候选", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        let composing = editor.string
        editor.apply("external draft")
        XCTAssertEqual(editor.string, composing)
        editor.keyDown(with: enter(window))
        XCTAssertEqual(sends, 0)
        editor.unmarkText(); editor.apply("confirmed")
        XCTAssertEqual(editor.string, "confirmed")
    }
    @MainActor func testCommandReturnIsConsumedOnlyByFocusedSideEditor() {
        let (window, editor) = editor(); defer { window.close() }
        var sends = 0
        editor.canSubmit = { true }; editor.submit = { sends += 1 }; editor.apply("side question")
        XCTAssertTrue(editor.performKeyEquivalent(with: enter(window, flags: .command)))
        XCTAssertEqual(sends, 1)
        _ = window.makeFirstResponder(nil)
        XCTAssertFalse(editor.performKeyEquivalent(with: enter(window, flags: .command)))
        XCTAssertEqual(sends, 1)
    }
    @MainActor func testUnchangedDraftDoesNotMoveSelection() {
        let (window, editor) = editor(); defer { window.close() }
        editor.apply("abc def"); editor.setSelectedRange(NSRange(location: 1, length: 2))
        editor.apply("abc def")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 1, length: 2))
        editor.apply("")
        XCTAssertEqual(editor.string, "")
        XCTAssertEqual(editor.selectedRange().location, 0)
    }
}
