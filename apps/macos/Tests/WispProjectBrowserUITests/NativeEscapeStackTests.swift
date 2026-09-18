import AppKit
import XCTest
@testable import WispProjectBrowserUI

final class NativeEscapeStackTests: XCTestCase {
    @MainActor private func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
    @MainActor private func event(_ window: NSWindow, key: UInt16 = 53, repeatKey: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: repeatKey, keyCode: key)!
    }
    @MainActor private func overlay(_ window: NSWindow, close: @escaping () -> Void) -> NativeSettingsEscape.Coordinator {
        let view = NSView(frame: .zero); window.contentView!.addSubview(view)
        let owner = NativeSettingsEscape.Coordinator(enabled: true, close: close); owner.view = view
        return owner
    }
    @MainActor func testImmediateEscapeClosesOnlyTopmostWithoutMovingFocus() {
        let window = window(); defer { window.close() }
        let stack = NativeEscapeStack(); var closed: [String] = []
        let parent = overlay(window) { closed.append("parent") }
        let child = overlay(window) { closed.append("child") }
        stack.register(parent); stack.register(child)
        let originalFocus = window.firstResponder
        XCTAssertTrue(stack.consume(event(window), keyWindow: window, modalWindow: nil))
        XCTAssertEqual(closed, ["child"]); XCTAssertTrue(window.firstResponder === originalFocus)
        stack.remove(child)
        XCTAssertTrue(stack.consume(event(window), keyWindow: window, modalWindow: nil))
        XCTAssertEqual(closed, ["child", "parent"])
        stack.remove(parent)
        XCTAssertFalse(stack.consume(event(window), keyWindow: window, modalWindow: nil))
    }
    @MainActor func testDisabledTopAndKeyRepeatNeverDismissParent() {
        let window = window(); defer { window.close() }
        let stack = NativeEscapeStack(); var closed = 0
        let parent = overlay(window) { closed += 10 }; let child = overlay(window) { closed += 1 }
        stack.register(parent); stack.register(child); child.enabled = false
        XCTAssertTrue(stack.consume(event(window), keyWindow: window, modalWindow: nil)); XCTAssertEqual(closed, 0)
        child.enabled = true
        XCTAssertTrue(stack.consume(event(window, repeatKey: true), keyWindow: window, modalWindow: nil)); XCTAssertEqual(closed, 0)
        XCTAssertTrue(stack.consume(event(window), keyWindow: window, modalWindow: nil)); XCTAssertEqual(closed, 1)
        stack.remove(child); stack.remove(parent)
    }
    @MainActor func testWindowIsolationAndUpdatedCallback() {
        let first = window(), second = window(); defer { first.close(); second.close() }
        let stack = NativeEscapeStack(); var closed = ""
        let a = overlay(first) { closed = "first" }; let b = overlay(second) { closed = "second" }
        stack.register(a); stack.register(b)
        XCTAssertFalse(stack.consume(event(first), keyWindow: second, modalWindow: nil))
        XCTAssertTrue(stack.consume(event(first), keyWindow: first, modalWindow: nil)); XCTAssertEqual(closed, "first")
        b.close = { closed = "updated" }; stack.register(b) // Idempotent install.
        XCTAssertTrue(stack.consume(event(second), keyWindow: second, modalWindow: nil)); XCTAssertEqual(closed, "updated")
        XCTAssertFalse(stack.consume(event(second, key: 36), keyWindow: second, modalWindow: nil))
        stack.remove(a); stack.remove(b)
    }
    @MainActor func testMenusModalWindowsAndCompositionKeepEscape() {
        let window = window(), dialog = self.window(); defer { window.close(); dialog.close() }
        let stack = NativeEscapeStack(); var closed = 0
        let owner = overlay(window) { closed += 1 }; stack.register(owner)
        XCTAssertFalse(stack.consume(event(window), keyWindow: window, modalWindow: dialog))
        let menu = NSMenu()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        XCTAssertFalse(stack.consume(event(window), keyWindow: window, modalWindow: nil))
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        XCTAssertFalse(stack.consume(event(window), keyWindow: window, modalWindow: nil))
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        let editor = NSTextView(frame: .zero); window.contentView!.addSubview(editor); window.makeFirstResponder(editor)
        editor.setMarkedText("候选", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertFalse(stack.consume(event(window), keyWindow: window, modalWindow: nil)); XCTAssertEqual(closed, 0)
        editor.unmarkText()
        XCTAssertTrue(stack.consume(event(window), keyWindow: window, modalWindow: nil)); XCTAssertEqual(closed, 1)
        stack.remove(owner); XCTAssertEqual(stack.menuDepth, 0)
    }
    @MainActor func testUnregisteredOrDetachedOverlayCannotConsumeEscape() {
        let window = window(); defer { window.close() }
        let stack = NativeEscapeStack(); var closed = 0
        var owner: NativeSettingsEscape.Coordinator? = overlay(window) { closed += 1 }
        stack.register(owner!)
        owner!.view!.removeFromSuperview()
        XCTAssertFalse(stack.consume(event(window), keyWindow: window, modalWindow: nil))
        owner = nil
        XCTAssertFalse(stack.consume(event(window), keyWindow: window, modalWindow: nil)); XCTAssertEqual(closed, 0)
    }
}
