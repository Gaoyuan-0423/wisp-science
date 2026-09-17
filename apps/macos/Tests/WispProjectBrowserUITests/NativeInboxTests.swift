import Foundation
import XCTest
import WispProjectBrowser
@testable import WispProjectBrowserUI

private actor InboxClient: NativeConversationQuerying {
    let value: SettingsValue
    var fail = false
    init(_ value: SettingsValue) { self.value = value }
    func setFail() { fail = true }
    func snapshot(projectID: String, sessionID: String, beforeSeq: Int64?) async throws -> ConversationSnapshot { throw ProjectBrowserError.invalidResponse }
    func invoke(_ command: String, args: [String: SettingsValue], projectID: String) async throws -> SettingsValue {
        if fail { throw ProjectBrowserError.service("offline") }
        return value
    }
}
final class NativeInboxTests: XCTestCase {
    @MainActor func testCrossProjectInboxAndFailurePreserveRows() async throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let value = try JSONDecoder().decode(SettingsValue.self, from: Data(contentsOf: root.appendingPathComponent("contracts/native-conversations/v1/inbox.json")))
        let client = InboxClient(value); let model = NativeInboxModel()
        await model.refresh(client: client, projectID: "project-a")
        XCTAssertEqual(model.entries.map(\.project_id), ["project-a", "project-b"])
        XCTAssertEqual(model.entries.map(\.id), ["session-a", "session-b"])
        await client.setFail()
        await model.refresh(client: client, projectID: "project-a")
        XCTAssertEqual(model.entries.count, 2)
        XCTAssertNotNil(model.error)
        model.reset()
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNil(model.error)
    }
}
