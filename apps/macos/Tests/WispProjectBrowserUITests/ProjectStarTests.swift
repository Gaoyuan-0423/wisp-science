import Foundation
import XCTest
import WispProjectBrowser
@testable import WispProjectBrowserUI

private actor StarClient: ProjectBrowserQuerying, ProjectBrowserWriting {
    let original: [ProjectSummary]
    let saved: [ProjectSummary]
    var continuation: CheckedContinuation<ProjectListSnapshot, Error>?
    var writes: [(String, Bool)] = []
    init() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("contracts/project-browser/v1/projects.json"))) as! [String: Any]
        let first = (json["projects"] as! [[String: Any]])[0]
        var second = first
        second["id"] = "second"
        second["starred"] = false
        original = try JSONDecoder().decode([ProjectSummary].self, from: JSONSerialization.data(withJSONObject: [first, second]))
        var unstarred = first
        unstarred["starred"] = false
        saved = try JSONDecoder().decode([ProjectSummary].self, from: JSONSerialization.data(withJSONObject: [second, unstarred]))
    }
    func listProjects(databaseURL: URL) async throws -> ProjectListSnapshot { ProjectListSnapshot(projects: original, activitySource: "persisted_only") }
    func listSessions(databaseURL: URL, projectID: String?) async throws -> [BrowserSession] { [] }
    func transcript(databaseURL: URL, projectID: String, sessionID: String, beforeSeq: Int64?) async throws -> TranscriptPage { TranscriptPage(messages: [], nextBeforeSeq: nil) }
    func setProjectStarred(databaseURL: URL, projectID: String, starred: Bool) async throws -> ProjectListSnapshot {
        writes.append((projectID, starred))
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func waiting() -> Bool { continuation != nil }
    func count() -> Int { writes.count }
    func desiredState() -> Bool? { writes.first?.1 }
    func finish(fail: Bool) {
        if fail { continuation?.resume(throwing: ProjectBrowserError.service("Database locked")) }
        else { continuation?.resume(returning: ProjectListSnapshot(projects: saved, activitySource: "persisted_only")) }
        continuation = nil
    }
}

final class ProjectStarTests: XCTestCase {
    @MainActor
    func testConfirmedWriteReordersWithoutChangingNavigationAndCoalescesClicks() async throws {
        let client = try StarClient()
        let model = ProjectBrowserModel(client: client, databaseURL: URL(fileURLWithPath: "/unused"))
        await model.refresh()
        await model.openProject("research-1")
        let writing = Task { await model.toggleStar("research-1") }
        while !(await client.waiting()) { await Task.yield() }
        XCTAssertEqual(model.projects.first?.id, "research-1")
        XCTAssertTrue(model.projects.first!.starred)
        XCTAssertTrue(model.isLoading)
        await model.toggleStar("research-1")
        await model.toggleStar("second")
        let count = await client.count()
        let state = await client.desiredState()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(state, false)
        await client.finish(fail: false)
        await writing.value
        XCTAssertEqual(model.projects.map(\.id), ["second", "research-1"])
        XCTAssertFalse(model.projects.last!.starred)
        XCTAssertEqual(model.activeProjectID, "research-1")
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.savingProjectID)
    }

    @MainActor
    func testFailureKeepsLastSnapshotAndExposesRetryableError() async throws {
        let client = try StarClient()
        let model = ProjectBrowserModel(client: client, databaseURL: URL(fileURLWithPath: "/unused"))
        await model.refresh()
        let before = model.projects
        let writing = Task { await model.toggleStar("research-1") }
        while !(await client.waiting()) { await Task.yield() }
        await client.finish(fail: true)
        await writing.value
        XCTAssertEqual(model.projects, before)
        XCTAssertTrue(model.error?.contains("Database locked") == true)
        XCTAssertFalse(model.isLoading)
    }
}
