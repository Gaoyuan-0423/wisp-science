import AppKit
import SwiftUI
import WispProjectBrowser

struct SearchResultSelection {
    private(set) var index = 0
    mutating func move(_ delta: Int, count: Int) { index = min(max(0, index + delta), max(0, count - 1)) }
    mutating func reset() { index = 0 }
    func selectedIndex(count: Int) -> Int? { count > 0 ? min(index, count - 1) : nil }
}

struct ProjectSearchSheet: View {
    @ObservedObject var model: ProjectBrowserModel
    var projectID: String? = nil
    let close: () -> Void
    @State private var query = ""
    @State private var selection = SearchResultSelection()
    @Environment(\.colorScheme) private var scheme
    private var projects: [ProjectSummary] { projectID == nil ? ProjectBrowserPresentation(search: query).visibleProjects(model.projects) : [] }
    private var sessions: [BrowserSession] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (projectID == nil ? model.recentSessions : model.sessions).filter { term.isEmpty || $0.title.localizedCaseInsensitiveContains(term) }
    }
    private var count: Int { projects.count + sessions.count }
    private func color(_ token: String) -> Color { WispDesign.color(token, scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                WispIcon(name: "search")
                SearchCommandField(text: $query, cancel: close, move: { selection.move($0, count: count) }, submit: {
                    if let index = selection.selectedIndex(count: count) { open(index) }
                })
                .frame(height: 24)
                Button("关闭", action: close).keyboardShortcut(.cancelAction)
            }
            Divider()
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if !projects.isEmpty {
                            Text("项目").font(.caption).foregroundStyle(color("text-faint"))
                            ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
                                result(index, title: project.name, icon: "folder")
                            }
                        }
                        if !sessions.isEmpty {
                            Text(projectID == nil ? "最近会话" : "会话").font(.caption).foregroundStyle(color("text-faint"))
                            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                                result(projects.count + index, title: session.title, icon: "chat")
                            }
                        }
                        if count == 0 {
                            Text("没有匹配的项目或会话").foregroundStyle(color("text-faint")).padding()
                        }
                    }
                }
                .onChange(of: selection.index) { index in scroll.scrollTo(index) }
            }
            Divider()
            Text("↑↓ 选择    ↵ 打开    esc 关闭").font(.caption).foregroundStyle(color("text-faint"))
        }
        .padding(24).frame(width: 560, height: 380).background(color("bg-app"))
        .onChange(of: query) { _ in selection.reset() }
        .onExitCommand(perform: close)
    }

    private func result(_ index: Int, title: String, icon: String) -> some View {
        Button { open(index) } label: {
            HStack { WispIcon(name: icon); Text(title).lineLimit(1); Spacer() }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(selection.selectedIndex(count: count) == index ? color("surface-hover") : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).id(index)
        .accessibilityAddTraits(selection.selectedIndex(count: count) == index ? [.isSelected] : [])
    }

    private func open(_ index: Int) {
        guard index >= 0 && index < count else { return }
        if index < projects.count {
            let id = projects[index].id
            close()
            Task { await model.openProject(id) }
        } else {
            let session = sessions[index - projects.count]
            close()
            Task {
                if projectID == session.projectID { await model.openSession(session.id) }
                else { await model.openProject(session.projectID, sessionID: session.id) }
            }
        }
    }
}

/// AppKit's field editor consumes arrow keys before SwiftUI's onMoveCommand.
/// Handle its navigation commands while preserving IME candidate selection.
private struct SearchCommandField: NSViewRepresentable {
    @Binding var text: String
    let cancel: () -> Void
    let move: (Int) -> Void
    let submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.placeholderString = "搜索项目、会话…"
        field.font = .systemFont(ofSize: 14)
        field.delegate = context.coordinator
        context.coordinator.installEscapeScope(field)
        field.setAccessibilityIdentifier("project-search")
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }
    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) { coordinator.removeEscapeScope() }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchCommandField
        init(_ parent: SearchCommandField) { self.parent = parent }
        private var monitor: Any?
        private var menuObservers: [NSObjectProtocol] = []
        private var menuTracking = false

        func installEscapeScope(_ field: NSTextField) {
            menuObservers = [
                NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in self?.menuTracking = true },
                NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in self?.menuTracking = false }
            ]
            // Scope Escape to this sheet's key window, regardless of focus. Menus,
            // child sheets, and IME composition get to consume it first.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak field] event in
                guard let self, let field, event.keyCode == 53,
                      let window = field.window, NSApp.keyWindow === window,
                      window.attachedSheet == nil, !self.menuTracking,
                      !((field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false) else { return event }
                self.parent.cancel()
                return nil
            }
        }
        func removeEscapeScope() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            menuObservers.forEach(NotificationCenter.default.removeObserver)
            menuObservers = []
        }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.insertNewline(_:)): parent.submit()
            default: return false
            }
            return true
        }
    }
}
