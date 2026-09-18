import Foundation
import WispProjectBrowser

@MainActor
final class NativeShareModel: ObservableObject {
    @Published var rows: [NativeShareDraftRow] = []
    @Published var keywords = ""
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    let client: any NativeConversationQuerying
    let projectID: String
    let sessionID: String
    init(client: any NativeConversationQuerying, projectID: String, sessionID: String) {
        self.client = client; self.projectID = projectID; self.sessionID = sessionID
    }
    var selected: [NativeShareRow] { NativeShare.selected(rows, keywords: keywords) }
    func load() async {
        guard !loading else { return }; loading = true; error = nil
        defer { loading = false }
        do {
            let value = try await client.invoke("native_conversation_share", args: ["session_id": .string(sessionID)], projectID: projectID)
            let rows = try JSONDecoder().decode([NativeShareRow].self, from: JSONEncoder().encode(value))
            guard !Task.isCancelled else { return }
            self.rows = NativeShare.draft(rows)
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func html(rows: [NativeShareRow], dark: Bool) async throws -> String {
        let payload = try JSONDecoder().decode(SettingsValue.self, from: JSONEncoder().encode(rows))
        let value = try await client.invoke("native_conversation_share_html", args: ["session_id": .string(sessionID), "rows": payload, "dark": .bool(dark)], projectID: projectID)
        guard case .string(let html) = value, !html.isEmpty else { throw ProjectBrowserError.invalidResponse }
        return html
    }
    func selectAll(_ selected: Bool) { for index in rows.indices { rows[index].selected = selected } }
}
