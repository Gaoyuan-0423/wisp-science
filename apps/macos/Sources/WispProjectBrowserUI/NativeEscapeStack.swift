import AppKit

/// One monitor for the application's native overlay registrations. Later
/// presentations win within a window; child windows and native menus take
/// precedence before the stack is consulted. Entries do not retain their views.
final class NativeEscapeStack {
    static let shared = NativeEscapeStack()
    private struct Entry {
        weak var owner: NativeSettingsEscape.Coordinator?
    }
    private var entries: [Entry] = []
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private(set) var menuDepth = 0

    func register(_ owner: NativeSettingsEscape.Coordinator) {
        guard !entries.contains(where: { $0.owner === owner }) else { return }
        entries.removeAll { $0.owner == nil }
        entries.append(Entry(owner: owner))
        guard monitor == nil else { return }
        observers = [
            NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in self?.menuDepth += 1 },
            NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                if let self { self.menuDepth = max(0, self.menuDepth - 1) }
            }
        ]
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.consume(event, keyWindow: NSApp.keyWindow, modalWindow: NSApp.modalWindow) == true ? nil : event
        }
    }
    func remove(_ owner: NativeSettingsEscape.Coordinator) {
        entries.removeAll { $0.owner == nil || $0.owner === owner }
        if entries.isEmpty { uninstall() }
    }
    /// The monitor calls this before responder dispatch, so focus need not enter
    /// the newly opened overlay. Explicit window arguments also permit isolated
    /// AppKit tests without activating or stealing focus from the user's app.
    func consume(_ event: NSEvent, keyWindow: NSWindow?, modalWindow: NSWindow?) -> Bool {
        guard event.type == .keyDown, event.keyCode == 53, menuDepth == 0,
              modalWindow == nil, let window = keyWindow,
              event.window === window, window.attachedSheet == nil else { return false }
        if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        guard let owner = entries.reversed().compactMap(\.owner).first(where: { $0.view?.window === window }) else { return false }
        // A held Escape and a temporarily nondismissible top surface must not
        // fall through to a parent overlay or the underlying responder chain.
        guard !event.isARepeat, owner.enabled else { return true }
        owner.close()
        return true
    }
    private func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        observers.forEach(NotificationCenter.default.removeObserver)
        monitor = nil; observers = []; menuDepth = 0
    }
    deinit { uninstall() }
}
