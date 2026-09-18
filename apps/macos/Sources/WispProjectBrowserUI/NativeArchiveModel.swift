import Foundation
import WispProjectBrowser

@MainActor
final class NativeArchiveModel: ObservableObject {
    @Published var archive: NativeResearchArchive? { didSet { if oldValue != archive { accepted = false } } }
    @Published var accepted = false
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private let client: any NativeConversationQuerying
    let projectID: String
    let sessionID: String
    init(client: any NativeConversationQuerying, projectID: String, sessionID: String) {
        self.client = client; self.projectID = projectID; self.sessionID = sessionID
    }
    var frozen: Bool { archive?.frozen_at != nil }
    var canConfirm: Bool { archive != nil && !frozen && accepted && !busy }
    var deletedBytes: UInt64 { archive?.files.filter { $0.action == "delete" }.reduce(0) { $0 + $1.size_bytes } ?? 0 }
    private func request(_ action: String, input: SettingsValue? = nil) async throws -> SettingsValue {
        var args: [String: SettingsValue] = ["session_id": .string(sessionID)]
        if let input { args["input"] = input }
        return try await client.invoke("native_conversation_archive_" + action, args: args, projectID: projectID)
    }
    private func decode(_ value: SettingsValue) throws -> NativeResearchArchive? {
        if value == .null { return nil }
        return try NativeResearchArchive.decode(value, project: projectID, session: sessionID)
    }
    func load() async {
        guard !busy else { return }; busy = true; error = nil
        defer { busy = false }
        do {
            archive = try decode(await request("get"))
            if archive == nil { archive = try decode(await request("prepare")) }
        } catch { self.error = error.localizedDescription }
    }
    func prepare() async { await mutate("prepare") }
    func retryCleanup() async { guard frozen else { return }; await mutate("retry") }
    func confirm() async {
        guard canConfirm, let archive else { return }
        do { await mutate("confirm", input: try archive.confirmation()) }
        catch { self.error = error.localizedDescription }
    }
    private func mutate(_ action: String, input: SettingsValue? = nil) async {
        guard !busy else { return }; busy = true; error = nil; accepted = false
        defer { busy = false }
        do { archive = try decode(await request(action, input: input)) }
        catch {
            self.error = error.localizedDescription
            // A cleanup or response failure can follow a committed freeze.
            // Reconcile once without replaying the mutation.
            if let value = try? await request("get"), let saved = try? decode(value) { archive = saved }
        }
    }
    func continueResearch() async -> String? {
        guard frozen, !busy else { return nil }; busy = true; error = nil
        defer { busy = false }
        do {
            let id = try await request("continue").string
            guard !id.isEmpty else { throw ProjectBrowserError.invalidResponse }
            return id
        } catch { self.error = "继续研究未确认成功，请刷新会话列表后检查：\(error.localizedDescription)"; return nil }
    }
}
