import XCTest
import WispProjectBrowser
@testable import WispProjectBrowserUI

private actor FileActionClient: NativeConversationQuerying {
    var writes: [[String: SettingsValue]] = []
    var reads = 0
    var fail = false
    func failNext() { fail = true }
    func counts() -> (Int, Int) { (writes.count, reads) }
    func lastWrite() -> [String: SettingsValue] { writes.last ?? [:] }
    func snapshot(projectID: String, sessionID: String, beforeSeq: Int64?) async throws -> ConversationSnapshot { throw ProjectBrowserError.invalidResponse }
    func invoke(_ command: String, args: [String: SettingsValue], projectID: String) async throws -> SettingsValue {
        guard projectID == "project-a", args["session_id"]?.string == "session-a" else { throw ProjectBrowserError.invalidResponse }
        if command.hasSuffix("file_action") {
            writes.append(args)
            if fail { throw ProjectBrowserError.service("lost response") }
            return .bool(true)
        }
        reads += 1
        return .array([])
    }
}

final class NativeFileActionTests: XCTestCase {
    func testNamesKeepOperationsInsideDisplayedDirectory() throws {
        XCTAssertEqual(try NativePanelFileAction.destination(directory: ".", name: "分析.R"), "分析.R")
        XCTAssertEqual(try NativePanelFileAction.destination(directory: "results", name: "figure 1.svg"), "results/figure 1.svg")
        for name in ["", " ", ".", "..", "../file", "a/b", "a\\b", "a\n", "a\0"] {
            XCTAssertThrowsError(try NativePanelFileAction.destination(directory: ".", name: name))
        }
    }
    @MainActor func testConfirmedRenameRefreshesAndFailedDeleteIsNotReplayed() async throws {
        let client = FileActionClient()
        let model = NativePanelModel(client: client, projectID: "project-a", sessionID: "session-a")
        await model.refresh("files", directory: "results")
        try await model.performFileAction(.rename, path: "results/a", newPath: "results/b")
        let args = await client.lastWrite()
        XCTAssertEqual(args["file_action"]?.string, "rename")
        XCTAssertEqual(args["path"]?.string, "results/a")
        XCTAssertEqual(args["new_path"]?.string, "results/b")
        let counts = await client.counts(); XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 2)
        await client.failNext()
        do { try await model.performFileAction(.delete, path: "results/b"); XCTFail("Expected lost reply") } catch { }
        let after = await client.counts(); XCTAssertEqual(after.0, 2); XCTAssertEqual(after.1, 2)
        XCTAssertFalse(model.fileActionBusy)
    }
}
