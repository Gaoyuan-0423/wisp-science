import AppKit
import SwiftUI
import WispProjectBrowser

/// A native editor owns Return handling, so keyboard events never escape to the
/// main conversation's send shortcut. IME composition stays with AppKit.
struct NativeSideChatInput: NSViewRepresentable {
    @Binding var text: String
    let canSubmit: () -> Bool
    let submit: () -> Void
    @Environment(\.colorScheme) private var scheme

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let editor = NativeSideChatTextView(frame: .zero)
        editor.isRichText = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 6, height: 6)
        editor.setAccessibilityLabel("侧聊问题")
        scroll.documentView = editor
        configure(editor)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NativeSideChatTextView else { return }
        configure(editor)
    }
    private func configure(_ editor: NativeSideChatTextView) {
        editor.onChange = { text = $0 }
        editor.canSubmit = canSubmit
        editor.submit = submit
        editor.font = .systemFont(ofSize: 13)
        editor.textColor = NSColor(WispDesign.color("text", scheme))
        editor.backgroundColor = NSColor(WispDesign.color("bg-elev", scheme))
        editor.insertionPointColor = editor.textColor ?? .textColor
        editor.apply(text)
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: ()) {
        guard let editor = scroll.documentView as? NativeSideChatTextView else { return }
        editor.onChange = nil; editor.canSubmit = nil; editor.submit = nil
    }
}

class NativeSideChatTextView: NSTextView {
    var onChange: ((String) -> Void)?
    var canSubmit: (() -> Bool)?
    var submit: (() -> Void)?

    func apply(_ text: String) {
        guard !hasMarkedText(), string != text else { return }
        string = text
        setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }
    override func didChangeText() { super.didChangeText(); onChange?(string) }
    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 36 || event.keyCode == 76 else { super.keyDown(with: event); return }
        switch NativeSideChatReturnAction.resolve(shift: event.modifierFlags.contains(.shift), composing: hasMarkedText()) {
        case .composition, .newline: super.keyDown(with: event)
        case .send: if canSubmit?() == true { submit?() }
        }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Keep Command-Return inside this editor rather than activating the
        // main conversation's window-level Command-Return button.
        if window?.firstResponder === self, event.modifierFlags.contains(.command),
           event.keyCode == 36 || event.keyCode == 76 {
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
