import Foundation
import XCTest
import WispProjectBrowser
@testable import WispProjectBrowserUI

private actor SelectionClient: NativeConversationQuerying {
    let snapshotValue: SettingsValue
    let saved: SettingsValue
    var writes = 0
    var fail = false
    var hold = false
    var pending: CheckedContinuation<SettingsValue, Error>?
    init(snapshot: SettingsValue, saved: SettingsValue) { snapshotValue = snapshot; self.saved = saved }
    func configure(fail: Bool = false, hold: Bool = false) { self.fail = fail; self.hold = hold }
    func waiting() -> Bool { pending != nil }
    func finish() { pending?.resume(returning: saved); pending = nil }
    func count() -> Int { writes }
    func snapshot(projectID: String, sessionID: String, beforeSeq: Int64?) async throws -> ConversationSnapshot {
        var value = snapshotValue; value["session_id"] = .string(sessionID); value["approvals"] = .array([])
        return try ConversationSnapshot.decode(value, projectID: projectID, sessionID: sessionID)
    }
    func invoke(_ command: String, args: [String: SettingsValue], projectID: String) async throws -> SettingsValue {
        if command == "native_conversation_panel_highlight_star" {
            writes += 1
            if fail { throw ProjectBrowserError.invalidResponse }
            if hold { hold = false; return try await withCheckedThrowingContinuation { pending = $0 } }
            return saved
        }
        if command == "native_conversation_panel_highlights" { return .array([saved]) }
        return .array([])
    }
}
final class NativeSelectionModelTests: XCTestCase {
    func fixture(_ name: String) throws -> SettingsValue {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try JSONDecoder().decode(SettingsValue.self, from: Data(contentsOf: root.appendingPathComponent("contracts/native-conversations/v1/\(name).json")))
    }
    private func client() throws -> SelectionClient { SelectionClient(snapshot: try fixture("snapshot"), saved: try fixture("panel-highlights").array[0]) }
    @MainActor func testSaveMarksOnlyConfirmedExactSelectionAndFailedSaveDoesNotReplay() async throws {
        let client = try client(); let model = NativeConversationModel(client: client)
        await model.open(project: "project-a", session: "session-a")
        let text = "样本 质量\n合格"
        await model.saveSelection(text, project: "project-a", session: "session-a")
        XCTAssertEqual(model.savedHighlights.map(\.code), [text]); XCTAssertEqual(model.savedHighlightRevision, 1)
        await client.configure(fail: true)
        await model.saveSelection("not saved", project: "project-a", session: "session-a")
        XCTAssertEqual(model.savedHighlights.map(\.code), [text]); XCTAssertNotNil(model.operationError)
        let count = await client.count(); XCTAssertEqual(count, 2)
        model.removeSavedHighlight("highlight-a", project: "project-a", session: "other")
        XCTAssertEqual(model.savedHighlights.count, 1)
        model.removeSavedHighlight("highlight-a", project: "project-a", session: "session-a")
        XCTAssertTrue(model.savedHighlights.isEmpty)
        model.pause()
    }
    @MainActor func testLateSaveCannotMarkNewSessionAndOldMenuCannotSendThere() async throws {
        let client = try client(); let model = NativeConversationModel(client: client)
        await model.open(project: "project-a", session: "session-a"); await client.configure(hold: true)
        let save = Task { await model.saveSelection("样本 质量\n合格", project: "project-a", session: "session-a") }
        while !(await client.waiting()) { await Task.yield() }
        await model.saveSelection("样本 质量\n合格", project: "project-a", session: "session-a")
        await model.open(project: "project-a", session: "session-b")
        await client.finish(); await save.value
        await model.saveSelection("old menu", project: "project-a", session: "session-a")
        XCTAssertTrue(model.savedHighlights.isEmpty)
        let count = await client.count(); XCTAssertEqual(count, 1)
        model.pause()
    }
    @MainActor func testInitialHighlightsReadRejectsForeignRowsAndMismatchedSaveText() async throws {
        let client = try client(); let model = NativeConversationModel(client: client)
        await model.open(project: "project-a", session: "session-b")
        await model.loadSavedHighlights(project: "project-a", session: "session-b")
        XCTAssertTrue(model.savedHighlights.isEmpty); XCTAssertNotNil(model.operationError)
        await model.open(project: "project-a", session: "session-a")
        await model.saveSelection("different selection", project: "project-a", session: "session-a")
        XCTAssertTrue(model.savedHighlights.isEmpty); XCTAssertNotNil(model.operationError)
        await model.loadSavedHighlights(project: "project-a", session: "session-a")
        XCTAssertEqual(model.savedHighlights.count, 1)
        model.pause()
    }
}
