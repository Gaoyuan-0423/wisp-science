import SwiftUI
import WispProjectBrowser

@MainActor
final class NativeInboxModel: ObservableObject {
    @Published private(set) var entries: [NativeInboxEntry] = []
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    private var generation = UUID()
    func refresh(client: any NativeConversationQuerying, projectID: String) async {
        guard !loading else { return }
        loading = true; let current = generation
        defer { if current == generation { loading = false } }
        do {
            let value = try await client.invoke("native_conversation_inbox", args: [:], projectID: projectID)
            let rows = try JSONDecoder().decode([NativeInboxEntry].self, from: JSONEncoder().encode(value))
            guard current == generation, !Task.isCancelled else { return }
            entries = rows.filter { $0.status == "needs_you" }; error = nil
        } catch { if current == generation, !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func reset() { generation = UUID(); entries = []; error = nil; loading = false }
}

struct NativeInboxView: View {
    @ObservedObject var inbox: NativeInboxModel
    let refresh: () -> Void
    let open: (NativeInboxEntry) -> Void
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("待查看").font(.headline); Spacer(); Button("刷新", action: refresh); Button("关闭", action: close) }
            if let error = inbox.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if inbox.loading { ProgressView() }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(inbox.entries) { entry in
                        Button { open(entry) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.project_name).font(.caption).foregroundStyle(.secondary)
                                Text(entry.title).lineLimit(3)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }.buttonStyle(.plain)
                    }
                    if inbox.entries.isEmpty && !inbox.loading && inbox.error == nil { Text("暂无待查看的会话").foregroundStyle(.secondary).padding() }
                }
            }
        }.padding(16).frame(width: 340, height: 350)
            .background(NativeSettingsEscape(close: close))
    }
}
