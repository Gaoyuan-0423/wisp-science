import Foundation
import XCTest
import WispProjectBrowser
@testable import WispProjectBrowserUI

private actor PanelClient: NativeConversationQuerying {
    let rows: SettingsValue
    var held: CheckedContinuation<SettingsValue, Error>?
    init(_ rows: SettingsValue) { self.rows = rows }
    func snapshot(projectID: String, sessionID: String, beforeSeq: Int64?) async throws -> ConversationSnapshot { throw ProjectBrowserError.invalidResponse }
    func invoke(_ command: String, args: [String: SettingsValue], projectID: String) async throws -> SettingsValue {
        if args["path"]?.string == "slow" { return try await withCheckedThrowingContinuation { held = $0 } }
        return rows
    }
    func pending() -> Bool { held != nil }
    func finish() { held?.resume(returning: rows); held = nil }
}
final class NativePanelTests: XCTestCase {
    func fixture(_ name: String) throws -> SettingsValue {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try JSONDecoder().decode(SettingsValue.self, from: Data(contentsOf: root.appendingPathComponent("contracts/native-conversations/v1/\(name).json")))
    }
    @MainActor func testLateDirectoryReadCannotReplaceNewerNavigation() async throws {
        let client = PanelClient(try fixture("panel-files"))
        let model = NativePanelModel(client: client, projectID: "p", sessionID: "s")
        let slow = Task { await model.refresh("files", directory: "slow") }
        for _ in 0..<100 { if await client.pending() { break }; await Task.yield() }
        let isPending = await client.pending(); XCTAssertTrue(isPending)
        await model.refresh("files", directory: "results")
        await client.finish(); await slow.value
        XCTAssertEqual(model.path, "results")
        XCTAssertEqual(model.parent, ".")
        XCTAssertEqual(model.child(model.files[1]), "results/README.md")
        model.close()
    }
    func testTruncatedPreviewRetainsFullSize() throws {
        let preview = try JSONDecoder().decode(NativePanelFileContent.self, from: JSONEncoder().encode(fixture("panel-preview")))
        XCTAssertTrue(preview.truncated)
        XCTAssertEqual(preview.total_bytes, 8_000_000)
        XCTAssertEqual(preview.text, "preview prefix")
    }
}
