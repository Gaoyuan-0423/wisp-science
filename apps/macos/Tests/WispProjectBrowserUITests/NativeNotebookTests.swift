import AppKit
import SwiftUI
import XCTest
import WispProjectBrowser
@testable import WispProjectBrowserUI

private actor NotebookClient: NativeConversationQuerying {
    let star: SettingsValue
    var saved = false
    var fail = false
    var writes = 0
    var held: CheckedContinuation<SettingsValue, Error>?
    var hold = false
    init(star: SettingsValue) { self.star = star }
    func configureFail() { fail = true }
    func count() -> Int { writes }
    func holdRead() { hold = true }
    func waiting() -> Bool { held != nil }
    func finishStaleRead() { held?.resume(returning: .array([])); held = nil }
    func snapshot(projectID: String, sessionID: String, beforeSeq: Int64?) async throws -> ConversationSnapshot { throw ProjectBrowserError.invalidResponse }
    func invoke(_ command: String, args: [String: SettingsValue], projectID: String) async throws -> SettingsValue {
        guard projectID == "project-a", args["session_id"]?.string == "session-a" else { throw ProjectBrowserError.invalidResponse }
        if command.hasSuffix("notebook_stars") {
            if hold { hold = false; return try await withCheckedThrowingContinuation { held = $0 } }
            return .array(saved ? [star] : [])
        }
        writes += 1
        if fail { throw ProjectBrowserError.invalidResponse }
        if command.hasSuffix("notebook_unstar") { saved = false; return .bool(true) }
        guard args["language"]?.string == "python", args["code"]?.string == "print(1)" else { throw ProjectBrowserError.invalidResponse }
        saved = true; return star
    }
}
final class NativeNotebookTests: XCTestCase {
    func fixture(_ name: String) throws -> SettingsValue {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try JSONDecoder().decode(SettingsValue.self, from: Data(contentsOf: root.appendingPathComponent("contracts/native-conversations/v1/\(name).json")))
    }
    func cells() throws -> [NativeNotebookCell] {
        let items = try JSONDecoder().decode([ConversationItem].self, from: JSONEncoder().encode(fixture("panel-notebook")["items"]))
        return NativeNotebookCell.collect(items)
    }
    func testProjectionMatchesFixtureValidatedByWebView() throws {
        let actual = try cells()
        let expected = try JSONDecoder().decode([NativeNotebookCell].self, from: JSONEncoder().encode(fixture("panel-notebook")["cells"]))
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual[3].starKey, actual[4].starKey)
        XCTAssertEqual(actual[6].status, "running")
        XCTAssertTrue(actual[5].outputInitiallyExpanded)
        XCTAssertFalse(actual[3].outputInitiallyExpanded)
        XCTAssertTrue(NativeNotebookCell.collect([]).isEmpty)
    }
    @MainActor func testSaveUnsaveAndFailureNeverReplayOrOptimisticallyChangeState() async throws {
        let client = NotebookClient(star: try fixture("panel-notebook-stars").array[0])
        let model = NativePanelModel(client: client, projectID: "project-a", sessionID: "session-a")
        let cell = try cells()[3]
        await model.toggleNotebookStar(cell)
        let initial = await client.count(); XCTAssertEqual(initial, 0)
        await model.refresh("notebook"); await model.toggleNotebookStar(cell)
        XCTAssertNotNil(model.notebookStar(cell))
        await model.toggleNotebookStar(cell); XCTAssertNil(model.notebookStar(cell))
        await client.configureFail(); await model.toggleNotebookStar(cell)
        XCTAssertNil(model.notebookStar(cell)); XCTAssertNotNil(model.error)
        let count = await client.count(); XCTAssertEqual(count, 3)
    }
    @MainActor func testMismatchedSaveReplyDoesNotMarkAnotherSessionsCode() async throws {
        var foreign = try fixture("panel-notebook-stars").array[0]
        foreign["source_session_id"] = .string("other")
        let model = NativePanelModel(client: NotebookClient(star: foreign), projectID: "project-a", sessionID: "session-a")
        await model.refresh("notebook"); await model.toggleNotebookStar(try cells()[3])
        XCTAssertTrue(model.notebookStars.isEmpty)
        XCTAssertNotNil(model.error)
    }
    @MainActor func testLateLibraryReadCannotDropConfirmedStar() async throws {
        let client = NotebookClient(star: try fixture("panel-notebook-stars").array[0])
        let model = NativePanelModel(client: client, projectID: "project-a", sessionID: "session-a")
        let cell = try cells()[3]
        await model.refresh("notebook"); await client.holdRead()
        let read = Task { await model.refresh("notebook") }
        while !(await client.waiting()) { await Task.yield() }
        await model.toggleNotebookStar(cell)
        await client.finishStaleRead(); await read.value
        XCTAssertNotNil(model.notebookStar(cell)); XCTAssertFalse(model.loading)
    }
    @MainActor func testRenderNotebookOutputAndStars() async throws {
        guard let directory = ProcessInfo.processInfo.environment["WISP_NATIVE_SNAPSHOT_DIR"] else { throw XCTSkip("Opt-in rendering") }
        let client = NotebookClient(star: try fixture("panel-notebook-stars").array[0])
        let model = NativePanelModel(client: client, projectID: "project-a", sessionID: "session-a")
        await model.refresh("notebook"); await model.toggleNotebookStar(try cells()[3])
        let renderedCells = Array(try cells().suffix(3))
        for (name, scheme) in [("notebook-light", ColorScheme.light), ("notebook-dark", ColorScheme.dark)] {
            let content = VStack(alignment: .leading, spacing: 10) { NativeNotebookView(model: model, cells: renderedCells) }
                .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(WispDesign.color("bg-sunken", scheme)).environment(\.colorScheme, scheme)
            let view = NSHostingView(rootView: content)
            view.frame = NSRect(x: 0, y: 0, width: 320, height: 650); view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }
}
