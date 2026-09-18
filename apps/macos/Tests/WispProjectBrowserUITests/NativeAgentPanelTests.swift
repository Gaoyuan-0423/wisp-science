import AppKit
import SwiftUI
import XCTest
import WispProjectBrowser
@testable import WispProjectBrowserUI

private actor AgentPanelClient: NativeConversationQuerying {
    let rows: SettingsValue
    let result: SettingsValue
    let delayed: Bool
    var pending: CheckedContinuation<SettingsValue, Error>?
    init(rows: SettingsValue, result: SettingsValue, delayed: Bool = false) { self.rows = rows; self.result = result; self.delayed = delayed }
    func snapshot(projectID: String, sessionID: String, beforeSeq: Int64?) async throws -> ConversationSnapshot { throw ProjectBrowserError.invalidResponse }
    func invoke(_ command: String, args: [String: SettingsValue], projectID: String) async throws -> SettingsValue {
        guard projectID == "project-a", args["session_id"]?.string == "session-a" else { throw ProjectBrowserError.invalidResponse }
        if command.hasSuffix("agent_result") {
            if delayed { return try await withCheckedThrowingContinuation { pending = $0 } }
            return result
        }
        return rows
    }
    func waiting() -> Bool { pending != nil }
    func finish() { pending?.resume(returning: result); pending = nil }
}
final class NativeAgentPanelTests: XCTestCase {
    private func fixture(_ name: String) throws -> SettingsValue {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try JSONDecoder().decode(SettingsValue.self, from: Data(contentsOf: root.appendingPathComponent("contracts/native-conversations/v1/\(name).json")))
    }
    private func client(delayed: Bool = false) throws -> AgentPanelClient { AgentPanelClient(rows: try fixture("panel-agents"), result: try fixture("panel-agent-result"), delayed: delayed) }
    @MainActor func testResultsValidateIdentityAndQuietPollingRetainsErrors() async throws {
        let model = NativePanelModel(client: try client(), projectID: "project-a", sessionID: "session-a")
        await model.refresh("agents")
        XCTAssertEqual(model.agents[0].dynamic.tasks[0].stored_step_id, "workflow-a:review")
        await model.readAgentResult(workflow: "wrong", step: "workflow-a:review")
        XCTAssertNil(model.agentResult); XCTAssertNotNil(model.error)
        await model.refresh("agents", quiet: true)
        XCTAssertNotNil(model.error)
        await model.readAgentResult(workflow: "workflow-a", step: "workflow-a:review")
        XCTAssertEqual(model.agentResult?.attempt, 1)
    }
    @MainActor func testDismissalDropsLateAgentResult() async throws {
        let client = try client(delayed: true)
        let model = NativePanelModel(client: client, projectID: "project-a", sessionID: "session-a")
        let request = Task { await model.readAgentResult(workflow: "workflow-a", step: "workflow-a:review") }
        for _ in 0..<100 { if await client.waiting() { break }; await Task.yield() }
        let waiting = await client.waiting(); XCTAssertTrue(waiting)
        model.close(); await client.finish(); await request.value
        XCTAssertNil(model.agentResult); XCTAssertFalse(model.agentResultLoading)
    }
    func testResultPresentationMergesArtifactsAndPrefersPersistedEvidence() throws {
        let response = try fixture("panel-agent-result")["response"]
        let sections = NativeAgentResultPresentation(response).sections
        XCTAssertEqual(sections.first?.0, "摘要")
        XCTAssertEqual(sections.first { $0.0 == "产物" }?.1.array.count, 2)
        XCTAssertEqual(sections.first { $0.0 == "证据" }?.1.array[0]["reference"].string, "report.md")
    }
    @MainActor func testRenderAgentPanelAndResult() async throws {
        guard let directory = ProcessInfo.processInfo.environment["WISP_NATIVE_SNAPSHOT_DIR"] else { throw XCTSkip("Opt-in rendering") }
        let model = NativePanelModel(client: try client(), projectID: "project-a", sessionID: "session-a")
        await model.refresh("agents"); await model.readAgentResult(workflow: "workflow-a", step: "workflow-a:review")
        let result = try XCTUnwrap(model.agentResult)
        let views: [(String, AnyView, NSSize)] = [
            ("agents-panel", AnyView(NativeAgentPanelView(model: model).padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(WispDesign.color("bg-sunken", .light))), NSSize(width: 300, height: 600)),
            ("agents-result", AnyView(NativeAgentResultView(result: result, close: {})), NSSize(width: 800, height: 650)),
            ("agents-result-dark", AnyView(NativeAgentResultView(result: result, close: {})), NSSize(width: 600, height: 650))
        ]
        for (name, content, size) in views {
            let view = NSHostingView(rootView: content.environment(\.colorScheme, name.hasSuffix("dark") ? .dark : .light))
            view.frame = NSRect(origin: .zero, size: size); view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }
}
