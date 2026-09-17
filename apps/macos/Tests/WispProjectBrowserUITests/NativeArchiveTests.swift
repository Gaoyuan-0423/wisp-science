import AppKit
import SwiftUI
import Foundation
import XCTest
import WispProjectBrowser
@testable import WispProjectBrowserUI

private actor ArchiveClient: NativeConversationQuerying {
    var value: SettingsValue
    var calls: [String] = []
    var failConfirm = false
    init(_ value: SettingsValue) { self.value = value }
    func failAfterFreeze() { failConfirm = true }
    func requests() -> [String] { calls }
    func snapshot(projectID: String, sessionID: String, beforeSeq: Int64?) async throws -> ConversationSnapshot { throw ProjectBrowserError.invalidResponse }
    func invoke(_ command: String, args: [String: SettingsValue], projectID: String) async throws -> SettingsValue {
        calls.append(command)
        if command == "native_conversation_archive_confirm" {
            value["frozen_at"] = .integer(3000)
            if failConfirm { throw ProjectBrowserError.service("cleanup failed after freeze") }
        }
        if command == "native_conversation_archive_continue" { return .string("continued-session") }
        return value
    }
}
final class NativeArchiveTests: XCTestCase {
    func fixture() throws -> SettingsValue {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try JSONDecoder().decode(SettingsValue.self, from: Data(contentsOf: root.appendingPathComponent("contracts/native-conversations/v1/archive.json")))
    }
    @MainActor func testRenderArchiveReview() async throws {
        guard let directory = ProcessInfo.processInfo.environment["WISP_NATIVE_SNAPSHOT_DIR"] else { throw XCTSkip("Opt-in native rendering") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for (name, width, scheme) in [("archive-desktop", 900.0, ColorScheme.light), ("archive-narrow", 660.0, ColorScheme.light), ("archive-dark", 900.0, ColorScheme.dark)] {
            let client = ArchiveClient(try fixture())
            let model = NativeArchiveModel(client: client, projectID: "project-a", sessionID: "session-a")
            await model.load()
            let view = NSHostingView(rootView: NativeArchiveView(model: model, workspace: "/tmp", close: {}, continued: { _ in }).environment(\.colorScheme, scheme))
            view.frame = NSRect(x: 0, y: 0, width: width, height: 750)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }
    func testScopeAndConfirmationOnlyContainReviewableFields() throws {
        let value = try fixture()
        XCTAssertThrowsError(try NativeResearchArchive.decode(value, project: "other", session: "session-a"))
        let archive = try NativeResearchArchive.decode(value, project: "project-a", session: "session-a")
        let input = try archive.confirmation()
        XCTAssertEqual(input["files"].array[0]["path"].string, "results/qc.txt")
        XCTAssertEqual(input["files"].array[0]["can_delete"], .null)
        XCTAssertEqual(input["frozen_at"], .null)
        XCTAssertEqual(input["source_hash"], .null)
    }
    @MainActor func testEditsRevokeConsentAndConfirmRequiresReview() async throws {
        let client = ArchiveClient(try fixture())
        let model = NativeArchiveModel(client: client, projectID: "project-a", sessionID: "session-a")
        await model.load()
        await model.confirm()
        var calls = await client.requests(); XCTAssertEqual(calls, ["native_conversation_archive_get"])
        model.accepted = true
        model.archive?.report = "reviewed changes"
        XCTAssertFalse(model.accepted)
        model.accepted = true
        await model.confirm()
        XCTAssertTrue(model.frozen)
        XCTAssertFalse(model.canConfirm)
        calls = await client.requests(); XCTAssertEqual(calls.filter { $0.hasSuffix("confirm") }.count, 1)
    }
    @MainActor func testFailedCleanupReconcilesFreezeWithoutRepeatingMutation() async throws {
        let client = ArchiveClient(try fixture())
        let model = NativeArchiveModel(client: client, projectID: "project-a", sessionID: "session-a")
        await model.load(); await client.failAfterFreeze(); model.accepted = true
        await model.confirm()
        XCTAssertTrue(model.frozen)
        XCTAssertNotNil(model.error)
        let calls = await client.requests()
        XCTAssertEqual(calls, ["native_conversation_archive_get", "native_conversation_archive_confirm", "native_conversation_archive_get"])
        let id = await model.continueResearch()
        XCTAssertEqual(id, "continued-session")
    }
}
