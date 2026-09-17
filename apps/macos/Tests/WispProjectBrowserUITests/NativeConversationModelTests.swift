import Foundation
import XCTest
import WispProjectBrowser
@testable import WispProjectBrowserUI

private func fixture(_ session: String = "session-a", sequence: UInt64 = 7, epoch: String = "host-one", running: Bool = false, requestID: String? = nil, error: String? = nil) throws -> ConversationSnapshot {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    var value = try JSONDecoder().decode(SettingsValue.self, from: Data(contentsOf: url.appendingPathComponent("contracts/native-conversations/v1/snapshot.json")))
    value["session_id"] = .string(session); value["sequence"] = .integer(Int64(sequence)); value["epoch"] = .string(epoch)
    value["running"] = .bool(running); value["request_id"] = requestID.map(SettingsValue.string) ?? .null
    value["error"] = error.map(SettingsValue.string) ?? .null
    value["approvals"] = .array([])
    return try ConversationSnapshot.decode(value, projectID: "project-a", sessionID: session)
}
private actor ConversationFake: NativeConversationQuerying {
    var reads: [ConversationSnapshot] = []
    var writes: [(String, [String: SettingsValue], String)] = []
    var failSend = false
    var failRead = false
    var held: CheckedContinuation<ConversationSnapshot, Error>?
    var holdRead = false
    func configure(_ values: [ConversationSnapshot], failSend: Bool = false, failRead: Bool = false) { reads = values; self.failSend = failSend; self.failRead = failRead }
    func snapshot(projectID: String, sessionID: String, beforeSeq: Int64?) async throws -> ConversationSnapshot {
        if holdRead { holdRead = false; return try await withCheckedThrowingContinuation { held = $0 } }
        if failRead { throw ProjectBrowserError.service("offline") }
        return reads.count > 1 ? reads.removeFirst() : try reads.first ?? fixture(sessionID)
    }
    func invoke(_ command: String, args: [String: SettingsValue], projectID: String) async throws -> SettingsValue {
        if command == "list_models" { return .array([]) }
        writes.append((command, args, projectID))
        if failSend { throw ProjectBrowserError.service("response lost") }
        return .null
    }
    func count() -> Int { writes.count }
    func lastArgs() -> [String: SettingsValue] { writes.last?.1 ?? [:] }
    func hold() { holdRead = true }
    func isHeld() -> Bool { held != nil }
    func finish(_ value: ConversationSnapshot) { held?.resume(returning: value); held = nil }
}
final class NativeConversationModelTests: XCTestCase {
    @MainActor func testSnapshotOrderingAndRestartNeverAppendOrRestoreRetiredHost() async throws {
        let client = ConversationFake(); let model = NativeConversationModel(client: client)
        await client.configure([try fixture(sequence: 7), try fixture(sequence: 6), try fixture(sequence: 1, epoch: "host-two"), try fixture(sequence: 99)])
        await model.open(project: "project-a", session: "session-a")
        await model.refresh(); XCTAssertEqual(model.snapshot?.sequence, 7)
        await model.refresh(); XCTAssertEqual(model.snapshot?.epoch, "host-two")
        await model.refresh(); XCTAssertEqual(model.snapshot?.epoch, "host-two")
        XCTAssertEqual(model.visibleItems.count, 2); model.pause()
    }
    @MainActor func testAmbiguousSendKeepsDraftAndDoesNotReplayThenAcknowledgesFromSnapshot() async throws {
        let client = ConversationFake(); let model = NativeConversationModel(client: client)
        await client.configure([try fixture()], failSend: true)
        await model.open(project: "project-a", session: "session-a")
        model.draft = "do work"; await model.send()
        XCTAssertTrue(model.uncertainSend); XCTAssertEqual(model.draft, "do work"); XCTAssertFalse(model.canSend)
        await model.send(); let count = await client.count(); XCTAssertEqual(count, 1)
        let args = await client.lastArgs()
        await client.configure([try fixture(sequence: 9, running: true, requestID: args["request_id"]?.string)])
        await model.refresh()
        XCTAssertEqual(model.draft, ""); XCTAssertFalse(model.uncertainSend); XCTAssertTrue(model.snapshot?.running == true)
        model.pause()
    }
    @MainActor func testNavigationIgnoresLateReadAndPreservesDraftWithoutStoppingAgent() async throws {
        let client = ConversationFake(); let model = NativeConversationModel(client: client)
        await model.open(project: "project-a", session: "session-a"); model.draft = "unsent"
        await client.hold(); let old = Task { await model.refresh() }
        while !(await client.isHeld()) { await Task.yield() }
        await model.open(project: "project-a", session: "session-b")
        await client.finish(try fixture(sequence: 999)); await old.value
        XCTAssertEqual(model.snapshot?.session_id, "session-b")
        await model.open(project: "project-a", session: "session-a")
        XCTAssertEqual(model.draft, "unsent")
        let count = await client.count(); XCTAssertEqual(count, 0); model.pause()
    }
    @MainActor func testReconnectDoesNotClearTranscriptOrAllowSendingWhileOffline() async throws {
        let client = ConversationFake(); let model = NativeConversationModel(client: client)
        await model.open(project: "project-a", session: "session-a"); model.draft = "hello"
        await client.configure([], failRead: true); await model.refresh()
        XCTAssertEqual(model.visibleItems.count, 2); XCTAssertFalse(model.canSend)
        await client.configure([try fixture(sequence: 8)]); await model.refresh()
        XCTAssertNil(model.connectionError); XCTAssertTrue(model.canSend); model.pause()
    }
    @MainActor func testAmbiguousAcceptedFailureRestoresDraftAfterNavigation() async throws {
        let client = ConversationFake(); let model = NativeConversationModel(client: client)
        await client.configure([try fixture()], failSend: true)
        await model.open(project: "project-a", session: "session-a")
        model.draft = "recover me"; await model.send()
        let args = await client.lastArgs()
        await client.configure([try fixture("session-b")])
        await model.open(project: "project-a", session: "session-b")
        await client.configure([try fixture(sequence: 10, requestID: args["request_id"]?.string, error: "model unavailable")])
        await model.open(project: "project-a", session: "session-a")
        XCTAssertFalse(model.uncertainSend); XCTAssertEqual(model.draft, "recover me")
        XCTAssertTrue(model.canSend)
        let count = await client.count(); XCTAssertEqual(count, 1); model.pause()
    }
    @MainActor func testStopAndApprovalCarrySessionAndExactApprovalIdentity() async throws {
        let client = ConversationFake(); let model = NativeConversationModel(client: client)
        await model.open(project: "project-a", session: "session-a")
        await model.stop()
        var args = await client.lastArgs(); XCTAssertEqual(args["session_id"]?.string, "session-a")
        let approval = try JSONDecoder().decode(ConversationApproval.self, from: Data(#"{"approval_id":"exact-id","frame_id":"session-a","message":"Run?","tool":"shell","preview":"echo test"}"#.utf8))
        await model.approve(approval, allowed: false)
        args = await client.lastArgs()
        XCTAssertEqual(args["session_id"]?.string, "session-a")
        XCTAssertEqual(args["approval_id"]?.string, "exact-id")
        XCTAssertEqual(args["approved"], .bool(false)); model.pause()
    }
    func testSnapshotRejectsWrongProjectOrApprovalScope() throws {
        let data = try JSONEncoder().encode(fixture())
        var value = try JSONDecoder().decode(SettingsValue.self, from: data)
        XCTAssertThrowsError(try ConversationSnapshot.decode(value, projectID: "other", sessionID: "session-a"))
        value["approvals"] = .array([.object(["approval_id": .string("a"), "frame_id": .string("other"), "message": .string("?"), "tool": .string("shell"), "preview": .string("")])])
        XCTAssertThrowsError(try ConversationSnapshot.decode(value, projectID: "project-a", sessionID: "session-a"))
    }

}
