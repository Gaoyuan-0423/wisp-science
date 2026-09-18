import Foundation
import WispProjectBrowser

@MainActor
final class NativeTerminalModel: ObservableObject {
    @Published private(set) var terminals: [NativeTerminalInfo] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var contexts: [SettingsValue] = []
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published private(set) var inputUncertain = false
    @Published private(set) var exitCode: UInt32?
    var receive: ((Data, Bool) -> Void)?
    private var cursor: UInt64?
    private var generation = UUID()
    private var inputGeneration = UUID()
    private var writes: Task<Void, Never>?
    let client: any NativeConversationQuerying
    let projectID: String
    let sessionID: String
    init(client: any NativeConversationQuerying, projectID: String, sessionID: String) {
        self.client = client; self.projectID = projectID; self.sessionID = sessionID
    }
    private func call(_ action: String, _ arguments: [String: SettingsValue] = [:]) async throws -> SettingsValue {
        var args = arguments; args["session_id"] = .string(sessionID)
        return try await client.invoke("native_conversation_terminal_" + action, args: args, projectID: projectID)
    }
    func select(_ id: String?) { generation = UUID(); cursor = nil; selectedID = id; exitCode = nil; receive?(Data(), true) }
    func reload() async {
        do {
            let value = try await call("list")
            let rows = try JSONDecoder().decode([NativeTerminalInfo].self, from: JSONEncoder().encode(value))
            guard rows.allSatisfy({ $0.project_id == projectID }) else { throw ProjectBrowserError.invalidResponse }
            terminals = rows
            if !rows.contains(where: { $0.id == selectedID }) { select(rows.first?.id) }
        } catch { self.error = error.localizedDescription }
    }
    func load() async {
        await reload()
        do { contexts = try await client.invoke("list_execution_contexts", args: [:], projectID: projectID).array }
        catch { self.error = error.localizedDescription }
    }
    func open(_ contextID: String) async {
        guard !busy else { return }; busy = true; error = nil
        defer { busy = false }
        do {
            let value = try await call("open", ["context_id": .string(contextID)])
            let info = try JSONDecoder().decode(NativeTerminalInfo.self, from: JSONEncoder().encode(value))
            guard info.project_id == projectID else { throw ProjectBrowserError.invalidResponse }
            await reload(); select(info.id)
        } catch {
            self.error = "终端创建未确认成功，请刷新列表后检查：\(error.localizedDescription)"
            await reload() // reconcile; never retry opening a process automatically
        }
    }
    func read() async {
        guard let id = selectedID, receive != nil else { return }
        let current = generation
        do {
            let value = try await call("read", ["terminal_id": .string(id), "cursor": cursor.map { .integer(Int64($0)) } ?? .null])
            let output = try JSONDecoder().decode(NativeTerminalOutput.self, from: JSONEncoder().encode(value))
            guard current == generation, !Task.isCancelled, let receive else { return }
            let bytes = try output.bytes(expectedID: id, cursor: cursor)
            receive(bytes, output.reset); cursor = output.end; exitCode = output.exit_code
        } catch { if current == generation && !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func send(_ bytes: Data, terminalID: String? = nil) {
        guard let id = selectedID, terminalID == nil || terminalID == id, exitCode == nil, !inputUncertain else { return }
        let previous = writes; let inputEpoch = inputGeneration
        writes = Task { [weak self] in
            await previous?.value
            guard let self, !self.inputUncertain, inputEpoch == self.inputGeneration else { return }
            do { _ = try await self.call("write", ["terminal_id": .string(id), "base64": .string(bytes.base64EncodedString())]) }
            catch { self.inputUncertain = true; self.inputGeneration = UUID(); self.error = "输入未确认送达，不会自动重发：\(error.localizedDescription)" }
        }
    }
    func resumeInput() { inputUncertain = false; error = nil }
    func resize(cols: Int, rows: Int, terminalID: String? = nil) {
        guard let id = selectedID, terminalID == nil || terminalID == id else { return }
        let previous = writes
        writes = Task {
            await previous?.value
            do { _ = try await call("resize", ["terminal_id": .string(id), "cols": .integer(Int64(min(1000, max(2, cols)))), "rows": .integer(Int64(min(500, max(2, rows))))]) }
            catch { self.error = error.localizedDescription }
        }
    }
    func closeSelected() async {
        guard let id = selectedID, !busy else { return }; busy = true
        defer { busy = false }
        do { _ = try await call("close", ["terminal_id": .string(id)]); await reload() }
        catch { self.error = error.localizedDescription }
    }
    func detach() { generation = UUID(); cursor = nil; receive = nil }
}
