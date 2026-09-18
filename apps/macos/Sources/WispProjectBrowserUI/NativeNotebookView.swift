import AppKit
import SwiftUI
import WispProjectBrowser

struct NativeNotebookView: View {
    @ObservedObject var model: NativePanelModel
    let cells: [NativeNotebookCell]
    var query = ""
    var body: some View {
        if cells.isEmpty {
            Text("暂无代码单元").font(.headline)
            Text("助手的代码块及 Python、R、Shell 执行记录将在这里显示。").font(.caption).foregroundStyle(.secondary)
        }
        let filtered = cells.filter { query.isEmpty || [$0.language, $0.source, $0.output].contains { $0.localizedCaseInsensitiveContains(query) } }
        if !cells.isEmpty && filtered.isEmpty { Text("没有匹配的代码单元").foregroundStyle(.secondary) }
        ForEach(filtered) { cell in NativeNotebookCellView(model: model, cell: cell).id(cell.origin + cell.starKey) }
    }
}
private struct NativeNotebookCellView: View {
    @ObservedObject var model: NativePanelModel
    let cell: NativeNotebookCell
    @State private var outputOpen: Bool?
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("[\(cell.index)] \(cell.language)").font(.system(size: 11, weight: .semibold, design: .monospaced))
                Spacer(minLength: 4)
                Text(["ok": "成功", "error": "失败", "source": "代码", "running": "进行中"][cell.status] ?? cell.status).font(.caption).foregroundStyle(cell.ok == false ? .red : .secondary)
                Button { Task { await model.toggleNotebookStar(cell) } } label: { WispIcon(name: model.notebookStar(cell) == nil ? "star" : "star-filled", size: 14) }
                    .buttonStyle(.plain).disabled(!model.notebookLoaded || model.notebookBusy.contains(cell.starKey))
                    .help(model.notebookStar(cell) == nil ? "收藏代码" : "取消收藏")
                    .accessibilityLabel(model.notebookStar(cell) == nil ? "收藏代码" : "取消收藏")
                Button("复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cell.source, forType: .string) }.font(.caption)
            }
            Text((cell.origin == "assistant" ? "助手" : cell.origin) + " · wisp-science").font(.caption2).foregroundStyle(.secondary)
            Text(cell.source).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !cell.output.isEmpty {
                DisclosureGroup("输出", isExpanded: Binding(get: { outputOpen ?? cell.outputInitiallyExpanded }, set: { outputOpen = $0 })) {
                    Text(cell.output).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }.font(.caption)
            }
        }.padding(12).background(WispDesign.color("bg-elev", scheme), in: RoundedRectangle(cornerRadius: 8))
    }
}
