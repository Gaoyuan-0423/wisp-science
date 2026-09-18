import AppKit
import SwiftUI
import WispProjectBrowser

struct NativeHighlightsView: View {
    @ObservedObject var model: NativePanelModel
    var query = ""
    let reveal: (String) -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        if model.highlights.isEmpty && !model.loading {
            Text("暂无划线摘录").font(.headline)
            Text("此会话中已收藏的文本将在这里显示。").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(model.highlights.filter { query.isEmpty || $0.code.localizedCaseInsensitiveContains(query) }) { item in
            VStack(alignment: .leading, spacing: 8) {
                Button { reveal(item.code) } label: {
                    Text(item.code).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).help("返回原文")
                HStack {
                    Spacer()
                    Button("复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.code, forType: .string) }
                    Button("取消收藏") { Task { await model.removeHighlight(item.id) } }.disabled(model.highlightRemoving.contains(item.id))
                    if model.highlightRemoving.contains(item.id) { ProgressView().controlSize(.small) }
                }.font(.caption)
            }.padding(12).background(WispDesign.color("bg-elev", scheme), in: RoundedRectangle(cornerRadius: 8))
        }
        if !model.highlights.isEmpty && !query.isEmpty && !model.highlights.contains(where: { $0.code.localizedCaseInsensitiveContains(query) }) {
            Text("没有匹配的摘录").foregroundStyle(.secondary)
        }
    }
}
