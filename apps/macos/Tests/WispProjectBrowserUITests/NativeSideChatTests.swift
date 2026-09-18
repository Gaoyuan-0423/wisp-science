import AppKit
import SwiftUI
import XCTest
import WispProjectBrowser
@testable import WispProjectBrowserUI

private actor SideChatClient: NativeConversationQuerying {
    let response: SettingsValue
    let options: SettingsValue
    var fail = false
    var wrongScope = false
    var noEvidence = false
    var hold = false
    var calls: [[String: SettingsValue]] = []
    var pending: CheckedContinuation<SettingsValue, Error>?
    init(response: SettingsValue, options: SettingsValue) { self.response = response; self.options = options }
    func configure(fail: Bool = false, wrong: Bool = false, empty: Bool = false, hold: Bool = false) { self.fail = fail; wrongScope = wrong; noEvidence = empty; self.hold = hold }
    func history() -> [[String: SettingsValue]] { calls }
    func waiting() -> Bool { pending != nil }
    func finish() { pending?.resume(returning: response); pending = nil }
    func snapshot(projectID: String, sessionID: String, beforeSeq: Int64?) async throws -> ConversationSnapshot { throw ProjectBrowserError.invalidResponse }
    func invoke(_ command: String, args: [String: SettingsValue], projectID: String) async throws -> SettingsValue {
        if command.hasSuffix("side_chat_options") { return options }
        if command == "set_active_model" { if fail { throw ProjectBrowserError.invalidResponse }; return .array([]) }
        calls.append(args)
        if fail { throw ProjectBrowserError.invalidResponse }
        if hold && args["session_id"]?.string == "session-a" { hold = false; return try await withCheckedThrowingContinuation { pending = $0 } }
        var value = response
        value["sessionId"] = wrongScope ? .string("wrong") : args["session_id"]!
        if noEvidence { value["noEvidence"] = .bool(true); value["answer"] = .string(""); value["evidence"] = .array([]) }
        return value
    }
}
final class NativeSideChatTests: XCTestCase {
    func fixture(_ name: String) throws -> SettingsValue {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try JSONDecoder().decode(SettingsValue.self, from: Data(contentsOf: root.appendingPathComponent("contracts/native-conversations/v1/\(name).json")))
    }
    private func client() throws -> SideChatClient { SideChatClient(response: try fixture("panel-side-chat"), options: try fixture("panel-side-chat-options")) }
    func testQuotedReferencesAreReadOnlyAndPreserveSources() {
        XCTAssertEqual(NativeSideChatQuote.question("解释", quotes: [.init(text: "one\ntwo", source: "a`b\nc")]), "Selected excerpt from reference `a\\`b c`:\n> one\n> two\n\n解释")
        XCTAssertEqual(NativeSideChatQuote.question("  question  ", quotes: []), "question")
    }
    @MainActor func testSendingUsesSelectedAgentAndValidatesEvidenceIdentity() async throws {
        let client = try client(); let model = NativeSideChatModel(client: client, projectID: "project-a", sessionID: "session-a")
        await model.loadOptions(); await model.select(model.options[1])
        model.draft = "question"; await model.send()
        XCTAssertEqual(model.rows.last?.answer?.evidence.first?.eventSeq, 40)
        XCTAssertEqual(model.rows.last?.answer?.snapshotVersion, 42)
        let calls = await client.history(); XCTAssertEqual(calls[0]["acp_agent_id"]?.string, "agent-a")
        await client.configure(wrong: true); model.draft = "another"; await model.send()
        XCTAssertNil(model.rows.last?.answer); XCTAssertNotNil(model.rows.last?.error)
    }
    @MainActor func testInFlightAnswersStayWithOriginalSessionAndCannotBeSentTwice() async throws {
        let client = try client(); await client.configure(hold: true)
        let first = NativeSideChatModel(client: client, projectID: "project-a", sessionID: "session-a")
        let other = NativeSideChatModel(client: client, projectID: "project-a", sessionID: "session-b")
        first.draft = "a"; let send = Task { await first.send() }
        while !(await client.waiting()) { await Task.yield() }
        first.clear(); XCTAssertEqual(first.rows.count, 1)
        first.draft = "new draft"; await first.send()
        other.draft = "b"; await other.send()
        await client.finish(); await send.value
        XCTAssertEqual(first.rows.last?.answer?.sessionId, "session-a")
        XCTAssertEqual(other.rows.last?.answer?.sessionId, "session-b")
        XCTAssertEqual(first.draft, "new draft")
        let calls = await client.history(); XCTAssertEqual(calls.count, 2)
    }
    @MainActor func testFailureIsNotReplayedAndNoEvidenceIsAnExplicitResult() async throws {
        let client = try client(); let model = NativeSideChatModel(client: client, projectID: "project-a", sessionID: "session-a")
        await client.configure(fail: true); model.draft = "question"; await model.send()
        XCTAssertNotNil(model.rows.last?.error); XCTAssertFalse(model.busy)
        let calls = await client.history(); XCTAssertEqual(calls.count, 1)
        await client.configure(empty: true); model.draft = "unknown"; await model.send()
        XCTAssertTrue(model.rows.last?.answer?.noEvidence == true)
        model.clear(); XCTAssertTrue(model.rows.isEmpty)
    }
    @MainActor func testUncertainModelChangeRequiresReadReconciliationBeforeSend() async throws {
        let client = try client(); let model = NativeSideChatModel(client: client, projectID: "project-a", sessionID: "session-a")
        await model.loadOptions(); await model.select(model.options[1])
        await client.configure(fail: true); await model.select(model.options[0])
        model.draft = "question"
        XCTAssertTrue(model.modelSelectionUncertain); XCTAssertFalse(model.canSend)
        await model.send()
        let calls = await client.history(); XCTAssertTrue(calls.isEmpty)
        await client.configure(); await model.loadOptions()
        XCTAssertFalse(model.modelSelectionUncertain); XCTAssertNil(model.acpAgentID); XCTAssertTrue(model.canSend)
    }
    @MainActor func testRenderSideChat() async throws {
        guard let directory = ProcessInfo.processInfo.environment["WISP_NATIVE_SNAPSHOT_DIR"] else { throw XCTSkip("Opt-in rendering") }
        let model = NativeSideChatModel(client: try client(), projectID: "project-a", sessionID: "session-a")
        await model.loadOptions(); model.draft = "样本检查进展如何？"; await model.send()
        model.quotes = [.init(text: "质量检查通过。", source: "会话摘录")]
        model.draft = "请解释质量检查结果。\n需要补充哪些数据？"
        for (name, scheme) in [("sidechat-light", ColorScheme.light), ("sidechat-dark", ColorScheme.dark)] {
            let content = NativeSideChatView(model: model).padding(12).background(WispDesign.color("bg-sunken", scheme)).environment(\.colorScheme, scheme)
            let view = NSHostingView(rootView: content)
            view.frame = NSRect(x: 0, y: 0, width: 340, height: 680); view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }
}
