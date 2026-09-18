import Foundation
import WispProjectBrowser

@MainActor
final class NativeTrajectoryModel: ObservableObject {
    @Published private(set) var snapshot: NativeTrajectory?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    let client: any NativeConversationQuerying
    let projectID: String
    let sessionID: String
    private var generation = UUID()
    init(client: any NativeConversationQuerying, projectID: String, sessionID: String) {
        self.client = client; self.projectID = projectID; self.sessionID = sessionID
    }
    func refresh() async {
        guard !loading else { return }
        loading = true
        let current = generation
        defer { if current == generation { loading = false } }
        do {
            let value = try await client.invoke("native_conversation_trajectory", args: ["session_id": .string(sessionID)], projectID: projectID)
            let snapshot = try NativeTrajectory.decode(value, sessionID: sessionID)
            guard current == generation, !Task.isCancelled else { return }
            self.snapshot = snapshot; error = nil
        } catch { if current == generation, !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func exportHTML() async throws -> String {
        let value = try await client.invoke("native_conversation_trajectory_html", args: ["session_id": .string(sessionID)], projectID: projectID)
        guard case .string(let html) = value, !html.isEmpty else { throw ProjectBrowserError.invalidResponse }
        return html
    }
    func close() { generation = UUID(); loading = false }
}
