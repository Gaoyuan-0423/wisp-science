import Foundation
import XCTest
import WispProjectBrowser
@testable import WispProjectBrowserUI

private actor NavigationClient: ProjectBrowserQuerying {
    var continuation: CheckedContinuation<[BrowserSession], Error>?
    var suspend = false
    func setSuspended() { suspend = true }
    func isWaiting() -> Bool { continuation != nil }
    func finish() { continuation?.resume(returning: []); continuation = nil }
    func listProjects(databaseURL: URL) async throws -> ProjectListSnapshot {
        ProjectListSnapshot(projects: [], activitySource: "persisted_only")
    }
    func listSessions(databaseURL: URL, projectID: String?) async throws -> [BrowserSession] {
        if suspend { return try await withCheckedThrowingContinuation { continuation = $0 } }
        return try JSONDecoder().decode([BrowserSession].self, from: Data("""
        [{"id":"s1","project_id":"p","title":"First","ts":1,"status":"complete"},
         {"id":"s2","project_id":"p","title":"Second","ts":2,"status":"needs_you"}]
        """.utf8))
    }
    func transcript(databaseURL: URL, projectID: String, sessionID: String, beforeSeq: Int64?) async throws -> TranscriptPage {
        let data = Data("[{\"seq\":1,\"role\":\"user\",\"text\":\"\(sessionID)\",\"tool_name\":null}]".utf8)
        return TranscriptPage(messages: try JSONDecoder().decode([BrowserMessage].self, from: data), nextBeforeSeq: nil)
    }
}

final class ProjectNavigationTests: XCTestCase {
    @MainActor
    func testRecentSessionOpensExactConversationAndBackClearsWorkspace() async {
        let model = ProjectBrowserModel(client: NavigationClient(), databaseURL: URL(fileURLWithPath: "/unused"))
        await model.openProject("p", sessionID: "s2")
        XCTAssertEqual(model.activeProjectID, "p")
        XCTAssertEqual(model.activeSessionID, "s2")
        XCTAssertEqual(model.messages.first?.text, "s2")
        await model.openSession("s1")
        XCTAssertEqual(model.messages.first?.text, "s1")
        model.goHome()
        XCTAssertNil(model.activeProjectID)
        XCTAssertNil(model.activeSessionID)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertTrue(model.sessions.isEmpty)
    }

    @MainActor
    func testBackDuringQueryCannotReopenAnOldWorkspace() async {
        let client = NavigationClient()
        await client.setSuspended()
        let model = ProjectBrowserModel(client: client, databaseURL: URL(fileURLWithPath: "/unused"))
        let opening = Task { await model.openProject("p") }
        while !(await client.isWaiting()) { await Task.yield() }
        model.goHome()
        await client.finish()
        await opening.value
        XCTAssertNil(model.activeProjectID)
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertFalse(model.sessionsLoading)
    }
}
