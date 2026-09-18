import SwiftUI

struct NativeConversationOutlineView: View {
    @ObservedObject var conversation: NativeConversationModel
    @State private var query = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("会话大纲").font(.headline)
                Spacer()
                Button("刷新") { Task { await conversation.loadOutline() } }
                Button("关闭") { conversation.outlinePresented = false }.keyboardShortcut(.cancelAction)
            }
            TextField("搜索问题", text: $query)
            if conversation.outlineLoading { ProgressView() }
            if let error = conversation.outlineError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(conversation.outline.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }) { entry in
                        Button { Task { await conversation.navigateToQuestion(entry) } } label: {
                            HStack(alignment: .top) {
                                Text("\(entry.user_index + 1)").foregroundStyle(.secondary).frame(width: 28)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.text).lineLimit(3)
                                    if let sent = entry.sent_at, sent > 0 {
                                        HStack {
                                            Text(Date(timeIntervalSince1970: Double(sent)), style: .time)
                                            if let response = entry.response_at, response >= sent { Text("\(response - sent) 秒") }
                                        }.font(.caption).foregroundStyle(.secondary)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(8)
                        }.buttonStyle(.plain)
                    }
                    if conversation.outline.isEmpty && !conversation.outlineLoading && conversation.outlineError == nil {
                        Text("暂无问题").foregroundStyle(.secondary)
                    }
                }
            }
        }.padding(16).frame(width: 360, height: 440)
            .background(NativeSettingsEscape { conversation.outlinePresented = false })
            .task {
                while !Task.isCancelled {
                    await conversation.loadOutline()
                    do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                }
            }
    }
}
