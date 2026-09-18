import AppKit
import SwiftUI
import XCTest
import WispProjectBrowser
@testable import WispProjectBrowserUI

private actor ActivityClient: NativeConversationQuerying {
    let snapshotValue: SettingsValue
    let run: SettingsValue
    let objects: SettingsValue
    var mutations = 0
    var wrongScope = false
    var pending: CheckedContinuation<SettingsValue, Error>?
    init(snapshot: SettingsValue, run: SettingsValue, objects: SettingsValue) { snapshotValue = snapshot; self.run = run; self.objects = objects }
    func snapshot(projectID: String, sessionID: String, beforeSeq: Int64?) async throws -> ConversationSnapshot { throw ProjectBrowserError.invalidResponse }
    func invoke(_ command: String, args: [String: SettingsValue], projectID: String) async throws -> SettingsValue {
        if projectID != "project-a" || args["session_id"]?.string != "session-a" { wrongScope = true }
        switch command {
        case "native_conversation_panel_activity": return snapshotValue
        case "native_conversation_panel_run_detail": return run
        case "native_conversation_panel_runtime_inspect": return try await withCheckedThrowingContinuation { pending = $0 }
        default: mutations += 1; throw ProjectBrowserError.invalidResponse
        }
    }
    func count() -> Int { mutations }
    func hasPending() -> Bool { pending != nil }
    func scopeMatches() -> Bool { !wrongScope }
    func finish() { pending?.resume(returning: objects); pending = nil }
}
final class NativeContextActivityTests: XCTestCase {
    func fixture(_ name: String) throws -> SettingsValue {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try JSONDecoder().decode(SettingsValue.self, from: Data(contentsOf: root.appendingPathComponent("contracts/native-conversations/v1/\(name).json")))
    }
    private func client(readOnly: Bool = false) throws -> ActivityClient {
        var snapshot = try fixture("panel-activity"); snapshot["read_only"] = .bool(readOnly)
        return ActivityClient(snapshot: snapshot, run: try fixture("panel-run"), objects: try fixture("panel-runtime-objects"))
    }
    @MainActor private func model(_ client: ActivityClient) -> NativeContextActivityModel { NativeContextActivityModel(client: client, projectID: "project-a", sessionID: "session-a", contextID: "local") }
    @MainActor func testScopedDetailsAndMutationAreNotReplayed() async throws {
        let client = try client(); let model = model(client)
        await model.refresh()
        XCTAssertEqual(model.runtimes.first?.key.sessionId, "session-a")
        XCTAssertEqual(model.runs.first?.title, "样本质量检查")
        await model.readRun("run-a")
        XCTAssertEqual(model.detail?.stdout_tail, "Processed 10 samples")
        await model.mutateRun("run-a", harvest: false)
        let count = await client.count(); XCTAssertEqual(count, 1)
        XCTAssertNotNil(model.error)
        await model.refresh()
        XCTAssertNotNil(model.error, "Polling must retain an uncertain mutation error")
        let matches = await client.scopeMatches(); XCTAssertTrue(matches)
    }
    @MainActor func testReadOnlyAndLateInspectionDismissal() async throws {
        let client = try client(readOnly: true); let model = model(client)
        await model.refresh()
        await model.mutateRun("run-a", harvest: true)
        let count = await client.count(); XCTAssertEqual(count, 0)
        let task = Task { await model.inspect("runtime-a") }
        for _ in 0..<100 { if await client.hasPending() { break }; await Task.yield() }
        let pending = await client.hasPending(); XCTAssertTrue(pending)
        model.dismissDetail()
        await client.finish(); await task.value
        XCTAssertNil(model.objects)
        XCTAssertNil(model.selectedRuntime)
    }
    @MainActor func testRenderActivityAndDetail() async throws {
        guard let directory = ProcessInfo.processInfo.environment["WISP_NATIVE_SNAPSHOT_DIR"] else { throw XCTSkip("Opt-in rendering") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for (name, runtimes, details) in [("activity-runtimes", true, false), ("activity-runs", false, false), ("activity-run-detail", false, true)] {
            let model = model(try client()); await model.refresh()
            if details { await model.readRun("run-a") }
            let view = NSHostingView(rootView: NativeContextActivityView(model: model, runtimes: runtimes, close: {}).environment(\.colorScheme, .light))
            view.frame = NSRect(x: 0, y: 0, width: 800, height: 650); view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }
}
