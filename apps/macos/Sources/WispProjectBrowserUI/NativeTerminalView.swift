import AppKit
import SwiftUI
import SwiftTerm
import WispProjectBrowser

struct NativeTerminalPanel: View {
    @StateObject private var model: NativeTerminalModel
    let hide: () -> Void
    init(client: any NativeConversationQuerying, projectID: String, sessionID: String, hide: @escaping () -> Void) {
        _model = StateObject(wrappedValue: NativeTerminalModel(client: client, projectID: projectID, sessionID: sessionID)); self.hide = hide
    }
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Picker("终端", selection: Binding(get: { model.selectedID ?? "" }, set: { model.select($0) })) {
                    if model.terminals.isEmpty { Text("无终端").tag("") }
                    ForEach(model.terminals) { Text($0.title).tag($0.id) }
                }.frame(maxWidth: 320)
                Menu("新建终端") {
                    ForEach(Array(model.contexts.enumerated()), id: \.offset) { _, context in
                        Button(context["label"].string.isEmpty ? context["id"].string : context["label"].string) { Task { await model.open(context["id"].string) } }
                    }
                }.disabled(model.busy)
                Button("刷新") { Task { await model.load() } }
                Button("中断") { model.send(Data([3])) }.disabled(model.selectedID == nil)
                Button("关闭终端") { Task { await model.closeSelected() } }.disabled(model.selectedID == nil || model.busy)
                Spacer(); Button("隐藏", action: hide)
            }
            if let error = model.error { Text(error).foregroundStyle(.orange).font(.caption).textSelection(.enabled) }
            if model.inputUncertain { Button("已核对终端，恢复输入") { model.resumeInput() } }
            if let code = model.exitCode { Text("进程已退出：\(code)").font(.caption).foregroundStyle(.secondary) }
            if model.selectedID == nil { Text("选择执行环境并新建终端").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { NativeTerminalEmulator(model: model, terminalID: model.selectedID).id(model.selectedID) }
        }.padding(10).frame(minHeight: 220, idealHeight: 300)
            .task {
                await model.load()
                if model.terminals.isEmpty && model.error == nil { await model.open("local") }
                var tick = 0
                while !Task.isCancelled {
                    await model.read(); tick += 1
                    if tick % 100 == 0 { await model.reload() }
                    do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
                }
            }
            .onDisappear { model.detach() }
    }
}
struct NativeTerminalEmulator: NSViewRepresentable {
    let model: NativeTerminalModel
    let terminalID: String?
    func makeCoordinator() -> Coordinator { Coordinator(model, terminalID: terminalID) }
    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        model.receive = { [weak view] data, reset in
            if reset { view?.feed(text: "\u{1b}c") }
            if !data.isEmpty { view?.feed(byteArray: Array(data)[...]) }
        }
        return view
    }
    func updateNSView(_ view: TerminalView, context: Context) {}
    static func dismantleNSView(_ view: TerminalView, coordinator: Coordinator) { view.terminalDelegate = nil }
    final class Coordinator: NSObject, TerminalViewDelegate {
        let model: NativeTerminalModel
        let terminalID: String?
        init(_ model: NativeTerminalModel, terminalID: String?) { self.model = model; self.terminalID = terminalID }
        func send(source: TerminalView, data: ArraySlice<UInt8>) { let bytes = Data(data); Task { @MainActor in guard let terminalID else { return }; model.send(bytes, terminalID: terminalID) } }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { Task { @MainActor in guard let terminalID else { return }; model.resize(cols: newCols, rows: newRows, terminalID: terminalID) } }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
            NSWorkspace.shared.open(url)
        }
        func bell(source: TerminalView) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func clipboardCopy(source: TerminalView, content: Data) {}
    }
}
