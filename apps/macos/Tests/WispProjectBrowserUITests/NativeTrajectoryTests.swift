import Foundation
import XCTest
import WispProjectBrowser
@testable import WispProjectBrowserUI

private actor TrajectoryClient: NativeConversationQuerying {
    var value: SettingsValue
    var calls: [(String, String, String)] = []
    init(_ value: SettingsValue) { self.value = value }
    func snapshot(projectID: String, sessionID: String, beforeSeq: Int64?) async throws -> ConversationSnapshot { throw ProjectBrowserError.invalidResponse }
    func invoke(_ command: String, args: [String: SettingsValue], projectID: String) async throws -> SettingsValue {
        calls.append((command, projectID, args["session_id"]?.string ?? ""))
        if command == "native_conversation_trajectory_html" { return .string("<html>exported</html>") }
        return value
    }
    func requests() -> [(String, String, String)] { calls }
}
final class NativeTrajectoryTests: XCTestCase {
    func fixture() throws -> SettingsValue {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try JSONDecoder().decode(SettingsValue.self, from: Data(contentsOf: root.appendingPathComponent("contracts/native-conversations/v1/trajectory.json")))
    }
    func testIdentityAndSearchUseDetails() throws {
        let value = try fixture()
        let snapshot = try NativeTrajectory.decode(value, sessionID: "session-a")
        XCTAssertThrowsError(try NativeTrajectory.decode(value, sessionID: "other"))
        let cell = try XCTUnwrap(snapshot.turns.first?.cells.first)
        XCTAssertTrue(cell.matches("SAMPLE.CSV"))
        XCTAssertTrue(cell.matches("sample_id"))
        XCTAssertFalse(cell.matches("volcano"))
        XCTAssertEqual(cell.duration_ms, 40)
        XCTAssertEqual(snapshot.stats.output_tokens, 20)
    }
    @MainActor func testReadsAndExportsKeepProjectSessionScope() async throws {
        let client = TrajectoryClient(try fixture())
        let model = NativeTrajectoryModel(client: client, projectID: "project-a", sessionID: "session-a")
        await model.refresh()
        XCTAssertEqual(model.snapshot?.frame_id, "session-a")
        let html = try await model.exportHTML()
        XCTAssertTrue(html.contains("exported"))
        let calls = await client.requests()
        XCTAssertEqual(calls.map { $0.0 }, ["native_conversation_trajectory", "native_conversation_trajectory_html"])
        XCTAssertTrue(calls.allSatisfy { $0.1 == "project-a" && $0.2 == "session-a" })
        model.close()
    }
}
