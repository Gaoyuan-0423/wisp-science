import AppKit
import SwiftUI
import XCTest
import WispProjectBrowser
@testable import WispProjectBrowserUI

private actor ProvenanceClient: NativeConversationQuerying {
    var calls = 0
    func count() -> Int { calls }
    func snapshot(projectID: String, sessionID: String, beforeSeq: Int64?) async throws -> ConversationSnapshot { throw ProjectBrowserError.invalidResponse }
    func invoke(_ command: String, args: [String: SettingsValue], projectID: String) async throws -> SettingsValue {
        calls += 1
        throw ProjectBrowserError.invalidResponse
    }
}
final class NativeProvenanceTests: XCTestCase {
    func items() throws -> [ConversationItem] {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try JSONDecoder().decode([ConversationItem].self, from: Data(contentsOf: root.appendingPathComponent("contracts/native-conversations/v1/panel-provenance.json")))
    }
    func testProjectionPreservesToolOrderAndExactRecordedContent() throws {
        let rows = NativeProvenanceRow.collect(try items())
        XCTAssertEqual(rows.map(\.index), [1, 3, 4, 5])
        XCTAssertEqual(rows.map(\.name), ["python", "read", "shell", "empty"])
        XCTAssertEqual(rows.map(\.initiallyExpanded), [false, true, true, false])
        XCTAssertEqual(rows[0].output, "42\n")
        XCTAssertEqual(rows[1].input, "样本.csv")
        XCTAssertEqual(rows[3].input, "")
        XCTAssertTrue(rows[1].matches("not FOUND"))
        XCTAssertFalse(rows[1].matches("python"))
        XCTAssertTrue(rows[2].matches("LS"))
    }
    func testReplacingTranscriptDoesNotRetainAnotherPagesRows() throws {
        let items = try items()
        XCTAssertEqual(NativeProvenanceRow.collect([items[4]]).map(\.index), [0])
        XCTAssertEqual(NativeProvenanceRow.collect([items[4]]).first?.name, "shell")
        XCTAssertTrue(NativeProvenanceRow.collect([items[0], items[2]]).isEmpty)
    }
    @MainActor func testProvenanceTabNeverReadsFilesOrDispatchesAnExtraSnapshot() async {
        let client = ProvenanceClient()
        let model = NativePanelModel(client: client, projectID: "p", sessionID: "s")
        await model.refresh("provenance")
        let count = await client.count()
        XCTAssertEqual(count, 0)
        XCTAssertFalse(model.loading)
        XCTAssertNil(model.error)
    }
    @MainActor func testRenderRecordedToolsAtNarrowWidth() throws {
        guard let directory = ProcessInfo.processInfo.environment["WISP_NATIVE_SNAPSHOT_DIR"] else { throw XCTSkip("Opt-in rendering") }
        for (name, scheme) in [("provenance-light", ColorScheme.light), ("provenance-dark", ColorScheme.dark)] {
            let content = NativeProvenanceView(rows: NativeProvenanceRow.collect(try items())).padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(WispDesign.color("bg-sunken", scheme)).environment(\.colorScheme, scheme)
            let view = NSHostingView(rootView: content)
            view.frame = NSRect(x: 0, y: 0, width: 300, height: 600); view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }
}
