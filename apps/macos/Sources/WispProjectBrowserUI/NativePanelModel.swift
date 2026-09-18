import Foundation
import WispProjectBrowser

@MainActor
final class NativePanelModel: ObservableObject {
    @Published private(set) var artifacts: [NativePanelArtifact] = []
    @Published private(set) var files: [NativePanelFile] = []
    @Published private(set) var path = "."
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var preview: NativePanelFileContent?
    let client: any NativeConversationQuerying
    let projectID: String
    let sessionID: String
    private var generation = UUID()
    private var previewGeneration = UUID()
    init(client: any NativeConversationQuerying, projectID: String, sessionID: String) {
        self.client = client; self.projectID = projectID; self.sessionID = sessionID
    }
    private func call(_ action: String, _ args: [String: SettingsValue] = [:]) async throws -> SettingsValue {
        var args = args; args["session_id"] = .string(sessionID)
        return try await client.invoke("native_conversation_panel_" + action, args: args, projectID: projectID)
    }
    private func decode<T: Decodable>(_ value: SettingsValue, as: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }
    func refresh(_ tab: String, directory: String? = nil) async {
        let current = UUID(); generation = current; loading = true; error = nil
        let requestedPath = directory ?? path
        defer { if generation == current { loading = false } }
        do {
            if tab == "artifacts" {
                let rows = try decode(await call("artifacts"), as: [NativePanelArtifact].self)
                guard generation == current, !Task.isCancelled else { return }; artifacts = rows
            } else {
                let rows = try decode(await call("files", ["path": .string(requestedPath)]), as: [NativePanelFile].self)
                guard generation == current, !Task.isCancelled else { return }; files = rows; path = requestedPath
            }
        } catch { if generation == current, !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func child(_ file: NativePanelFile) -> String { path == "." ? file.name : path + "/" + file.name }
    var parent: String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "." : parent
    }
    func readFile(_ path: String) async { await read("readfile", args: ["path": .string(path)]) }
    func readArtifact(_ id: String) async { await read("readartifact", args: ["artifact_id": .string(id)]) }
    private func read(_ action: String, args: [String: SettingsValue]) async {
        let current = UUID(); previewGeneration = current; error = nil
        do {
            let content = try decode(await call(action, args), as: NativePanelFileContent.self)
            guard previewGeneration == current, !Task.isCancelled else { return }
            preview = content
        } catch { if previewGeneration == current { self.error = error.localizedDescription } }
    }
    func dismissPreview() { previewGeneration = UUID(); preview = nil }
    func close() { generation = UUID(); dismissPreview() }
}
