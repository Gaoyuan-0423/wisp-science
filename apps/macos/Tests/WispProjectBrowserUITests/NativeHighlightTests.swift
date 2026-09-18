import AppKit
import SwiftUI
import XCTest
import WispProjectBrowser
@testable import WispProjectBrowserUI

private actor HighlightClient: NativeConversationQuerying {
    var rows: SettingsValue
    var fail = false
    var writes = 0
    var hold = false
    var held: CheckedContinuation<SettingsValue, Error>?
    init(_ rows: SettingsValue) { self.rows = rows }
    func configureFail() { fail = true }
    func holdRead() { hold = true }
    func waiting() -> Bool { held != nil }
    func finish() { held?.resume(returning: rows); held = nil }
    func count() -> Int { writes }
    func snapshot(projectID: String, sessionID: String, beforeSeq: Int64?) async throws -> ConversationSnapshot { throw ProjectBrowserError.invalidResponse }
    func invoke(_ command: String, args: [String: SettingsValue], projectID: String) async throws -> SettingsValue {
        guard projectID == "project-a", args["session_id"]?.string == "session-a" else { throw ProjectBrowserError.invalidResponse }
        if command.hasSuffix("highlight_remove") {
            writes += 1
            guard args["library_item_id"]?.string == "highlight-a", !fail else { throw ProjectBrowserError.invalidResponse }
            return .bool(true)
        }
        if hold { hold = false; return try await withCheckedThrowingContinuation { held = $0 } }
        return rows
    }
}
final class NativeHighlightTests: XCTestCase {
    func fixture() throws -> SettingsValue {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try JSONDecoder().decode(SettingsValue.self, from: Data(contentsOf: root.appendingPathComponent("contracts/native-conversations/v1/panel-highlights.json")))
    }
    func testWhitespaceAndUnicodeMatchingReturnsOriginalCharacterOffsets() {
        XCTAssertEqual(NativeSavedExcerpt.range(in: "x样本 质量\n合格y", excerpt: "样本质量合格"), 1..<9)
        XCTAssertEqual(NativeSavedExcerpt.range(in: "🧬 A\tB", excerpt: "🧬AB"), 0..<5)
        XCTAssertEqual(NativeSavedExcerpt.range(in: "aaa", excerpt: "aa"), 0..<2)
        XCTAssertNil(NativeSavedExcerpt.range(in: "ABC", excerpt: "abc"))
        XCTAssertNil(NativeSavedExcerpt.range(in: "abc", excerpt: " \n"))
    }
    @MainActor func testScopeValidationAndFailedDeleteRetainTheSavedExcerpt() async throws {
        let client = HighlightClient(try fixture())
        let model = NativePanelModel(client: client, projectID: "project-a", sessionID: "session-a")
        await model.refresh("highlights")
        XCTAssertEqual(model.highlights.first?.code, "样本 质量\n合格")
        await client.configureFail(); await model.removeHighlight("highlight-a")
        XCTAssertEqual(model.highlights.count, 1); XCTAssertNotNil(model.error)
        let count = await client.count(); XCTAssertEqual(count, 1)
        var foreign = try fixture().array
        foreign[0]["source_session_id"] = .string("other")
        let other = NativePanelModel(client: HighlightClient(.array(foreign)), projectID: "project-a", sessionID: "session-a")
        await other.refresh("highlights")
        XCTAssertTrue(other.highlights.isEmpty); XCTAssertNotNil(other.error)
    }
    @MainActor func testLateReadCannotRestoreSuccessfullyRemovedHighlight() async throws {
        let client = HighlightClient(try fixture())
        let model = NativePanelModel(client: client, projectID: "project-a", sessionID: "session-a")
        await model.refresh("highlights"); await client.holdRead()
        let read = Task { await model.refresh("highlights") }
        while !(await client.waiting()) { await Task.yield() }
        await model.removeHighlight("highlight-a"); XCTAssertTrue(model.highlights.isEmpty)
        await client.finish(); await read.value
        XCTAssertTrue(model.highlights.isEmpty); XCTAssertFalse(model.loading)
    }
    @MainActor func testRenderHighlights() async throws {
        guard let directory = ProcessInfo.processInfo.environment["WISP_NATIVE_SNAPSHOT_DIR"] else { throw XCTSkip("Opt-in rendering") }
        let model = NativePanelModel(client: HighlightClient(try fixture()), projectID: "project-a", sessionID: "session-a")
        await model.refresh("highlights")
        for (name, scheme) in [("highlights-light", ColorScheme.light), ("highlights-dark", ColorScheme.dark)] {
            let content = VStack(alignment: .leading, spacing: 10) { NativeHighlightsView(model: model, reveal: { _ in }) }
                .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(WispDesign.color("bg-sunken", scheme)).environment(\.colorScheme, scheme)
            let view = NSHostingView(rootView: content)
            view.frame = NSRect(x: 0, y: 0, width: 300, height: 500); view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }
}
