import Foundation
import XCTest
import WispProjectBrowser
@testable import WispProjectBrowserUI

private actor OutlineClient: NativeConversationQuerying {
    let page: ConversationSnapshot
    let rows: SettingsValue
    var cursor: Int64?
    init(page: ConversationSnapshot, rows: SettingsValue) { self.page = page; self.rows = rows }
    func snapshot(projectID: String, sessionID: String, beforeSeq: Int64?) async throws -> ConversationSnapshot {
        cursor = beforeSeq; return page
    }
    func invoke(_ command: String, args: [String: SettingsValue], projectID: String) async throws -> SettingsValue {
        command == "native_conversation_outline" ? rows : .array([])
    }
    func lastCursor() -> Int64? { cursor }
}

final class NativeConversationOutlineTests: XCTestCase {
    private func items() throws -> [ConversationItem] {
        try JSONDecoder().decode([ConversationItem].self, from: Data("""
        [{"role":"assistant","text":"previous"},{"role":"user","text":"repeat"},
         {"role":"tool","text":"result"},{"role":"user","text":"repeat"}]
        """.utf8))
    }
    @MainActor func testGlobalQuestionIndexesDistinguishRepeatedPrompts() throws {
        let rows = try items()
        XCTAssertEqual(NativeConversationModel.questionItemIndex(20, offset: 20, items: rows), 1)
        XCTAssertEqual(NativeConversationModel.questionItemIndex(21, offset: 20, items: rows), 3)
        XCTAssertNil(NativeConversationModel.questionItemIndex(19, offset: 20, items: rows))
        XCTAssertNil(NativeConversationModel.questionItemIndex(22, offset: 20, items: rows))
    }
    @MainActor func testNavigationLoadsHistoricalPageAndSelectsIndexedQuestion() async throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        var payload = try JSONDecoder().decode(SettingsValue.self, from: Data(contentsOf: root.appendingPathComponent("contracts/native-conversations/v1/snapshot.json")))
        payload["user_offset"] = .integer(0)
        payload["items"] = try JSONDecoder().decode(SettingsValue.self, from: JSONEncoder().encode(items()))
        let rows = try JSONDecoder().decode(SettingsValue.self, from: Data(contentsOf: root.appendingPathComponent("contracts/native-conversations/v1/outline.json")))
        let page = try ConversationSnapshot.decode(payload, projectID: "project-a", sessionID: "session-a")
        let client = OutlineClient(page: page, rows: rows)
        let model = NativeConversationModel(client: client)
        await model.open(project: "project-a", session: "session-a")
        await model.loadOutline()
        XCTAssertEqual(model.outline.count, 2)
        model.outlinePresented = true
        await model.navigateToQuestion(model.outline[0])
        let cursor = await client.lastCursor()
        XCTAssertEqual(cursor, 8)
        XCTAssertEqual(model.scrollTarget, 1)
        XCTAssertTrue(model.showingHistory)
        XCTAssertFalse(model.outlinePresented)
        await model.navigateToQuestion(model.outline[1])
        XCTAssertEqual(model.scrollTarget, 3)
        model.latest()
        XCTAssertFalse(model.showingHistory)
        model.pause()
    }
    func testOutlineFixtureUsesExclusiveHistoryCursor() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let rows = try JSONDecoder().decode([ConversationOutlineEntry].self, from: Data(contentsOf: root.appendingPathComponent("contracts/native-conversations/v1/outline.json")))
        XCTAssertEqual(rows.map(\.user_index), [0, 1])
        XCTAssertEqual(rows[0].before_seq, 8)
        XCTAssertNil(rows[1].before_seq)
        XCTAssertEqual(rows[0].text, rows[1].text)
    }
}
