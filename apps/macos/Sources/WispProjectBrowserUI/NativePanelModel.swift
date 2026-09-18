import Foundation
import WispProjectBrowser

@MainActor
final class NativePanelModel: ObservableObject {
    @Published private(set) var artifacts: [NativePanelArtifact] = []
    @Published private(set) var files: [NativePanelFile] = []
    @Published private(set) var path = "."
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var contexts: NativePanelContexts?
    @Published private(set) var contextBusy = false
    @Published private(set) var agents: [NativeAgentSnapshot] = []
    @Published private(set) var agentLaunching: Set<String> = []
    @Published private(set) var agentActions: Set<String> = []
    private var agentEpoch = UUID()
    private var selectedTab = "artifacts"
    @Published var agentResult: NativeAgentResult?
    @Published private(set) var agentResultLoading = false
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
    func refresh(_ tab: String, directory: String? = nil, quiet: Bool = false) async {
        selectedTab = tab
        let current = UUID(); generation = current; loading = !quiet
        if !quiet { error = nil }
        let requestedPath = directory ?? path
        defer { if generation == current { loading = false } }
        do {
            if tab == "artifacts" {
                let rows = try decode(await call("artifacts"), as: [NativePanelArtifact].self)
                guard generation == current, !Task.isCancelled else { return }; artifacts = rows
            } else if tab == "agents" {
                let result = try decode(await call("agents"), as: [NativeAgentSnapshot].self)
                guard generation == current, !Task.isCancelled else { return }; agents = result
            } else if tab == "hosts" {
                let result = try decode(await call("contexts"), as: NativePanelContexts.self)
                guard generation == current, !Task.isCancelled else { return }; contexts = result
            } else {
                let rows = try decode(await call("files", ["path": .string(requestedPath)]), as: [NativePanelFile].self)
                guard generation == current, !Task.isCancelled else { return }; files = rows; path = requestedPath
            }
        } catch { if generation == current, !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func setContext(_ id: String, enabled: Bool) async {
        guard !contextBusy, contexts?.read_only == false else { return }
        let current = generation
        contextBusy = true
        defer { contextBusy = false }
        do {
            _ = try await call("context_enabled", ["context_id": .string(id), "enabled": .bool(enabled)])
            if generation == current, !Task.isCancelled { await refresh("hosts") }
        } catch { if generation == current { self.error = error.localizedDescription } }
    }
    func probeContext(_ id: String) async {
        guard !contextBusy else { return }
        let current = generation
        contextBusy = true
        defer { contextBusy = false }
        do {
            _ = try await client.invoke("probe_execution_context", args: ["contextId": .string(id)], projectID: projectID)
            if generation == current, !Task.isCancelled { await refresh("hosts") }
        } catch { if generation == current { self.error = error.localizedDescription } }
    }
    func performAgentAction(_ snapshot: NativeAgentSnapshot, action: NativeAgentAction, budgets: [String: NativeAgentBudgetOverride] = [:]) async {
        let id = snapshot.id
        guard snapshot.workflow.depth == 0 else { return }
        if action == .run { guard !agentLaunching.contains(id) else { return }; agentLaunching.insert(id) }
        else { guard !agentActions.contains(id) else { return }; agentActions.insert(id) }
        let epoch = agentEpoch; error = nil
        defer { if epoch == agentEpoch { if action == .run { agentLaunching.remove(id) } else { agentActions.remove(id) } } }
        do {
            var args: [String: SettingsValue] = ["workflow_id": .string(id), "action": .string(action.rawValue)]
            if action == .approve { args["expected_version"] = .integer(snapshot.workflow.version) }
            if !budgets.isEmpty { args["budget_overrides"] = try JSONDecoder().decode(SettingsValue.self, from: JSONEncoder().encode(budgets)) }
            _ = try await call("agent_action", args)
            guard epoch == agentEpoch, !Task.isCancelled else { return }
            if selectedTab == "agents" { await refresh("agents", quiet: true) }
        } catch { if epoch == agentEpoch { self.error = "操作结果未确认，未自动重试。" + error.localizedDescription } }
    }
    func readAgentResult(workflow: String, step: String) async {
        let current = UUID(); previewGeneration = current; agentResultLoading = true; error = nil
        defer { if previewGeneration == current { agentResultLoading = false } }
        do {
            let result = try decode(await call("agent_result", ["workflow_id": .string(workflow), "step_id": .string(step)]), as: NativeAgentResult.self)
            guard current == previewGeneration, !Task.isCancelled else { return }
            guard result.workflow_id == workflow, result.step_id == step else { throw ProjectBrowserError.invalidResponse }
            agentResult = result
        } catch { if current == previewGeneration { self.error = error.localizedDescription } }
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
    func dismissPreview() { previewGeneration = UUID(); preview = nil; agentResult = nil; agentResultLoading = false }
    func close() { agentEpoch = UUID(); agentLaunching = []; agentActions = []; generation = UUID(); dismissPreview() }
}
