import AppKit
import Foundation
import SwiftUI
import XCTest
import WispProjectBrowser
@testable import WispProjectBrowserUI

final class NativeShareTests: XCTestCase {
    func fixture() throws -> [NativeShareRow] {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try JSONDecoder().decode([NativeShareRow].self, from: Data(contentsOf: root.appendingPathComponent("contracts/native-conversations/v1/share.json")))
    }
    func testSelectionAndRedactionExcludeThinkingByDefault() throws {
        let draft = NativeShare.draft(try fixture())
        XCTAssertEqual(draft.map(\.selected), [true, false, true])
        let rows = NativeShare.selected(draft, keywords: " Alice，Alice\n样本一 ")
        XCTAssertEqual(rows.count, 2)
        XCTAssertFalse(rows.map(\.text).joined().lowercased().contains("alice"))
        XCTAssertFalse(rows.map(\.text).joined().contains("样本一"))
        XCTAssertEqual(NativeShare.keywords("Alice,Alice,Ali"), ["Alice", "Ali"])
        XCTAssertTrue(draft[0].row.text.contains("Alice"), "Export must not mutate the stored transcript")
    }
    func testMarkdownBlocksPreserveCodeAndSeparateBullets() {
        let blocks = NativeShareMarkdown.blocks("# Results\n\n- first\n- second\n\n```python\n# literal\nprint(1)\n```")
        XCTAssertEqual(blocks.map(\.kind), ["heading", "bullet", "bullet", "code"])
        XCTAssertEqual(blocks.last?.text, "# literal\nprint(1)")
    }
    func testWidthMatchesWebViewBounds() {
        XCTAssertEqual(NativeShare.width(""), 840)
        XCTAssertEqual(NativeShare.width("bad"), 840)
        XCTAssertEqual(NativeShare.width("12"), 320)
        XCTAssertEqual(NativeShare.width("9999"), 2400)
        XCTAssertEqual(NativeShare.width("640"), 640)
    }
    @MainActor func testPNGHasRequestedPixelWidthAndCanRenderRedactedSelection() throws {
        let rows = NativeShare.selected(NativeShare.draft(try fixture()), keywords: "Alice")
        let data = try NativeSharePage.png(rows: rows, width: 640, scheme: .light)
        let image = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(image.pixelsWide, 640)
        XCTAssertGreaterThan(image.pixelsHigh, 100)
        if let directory = ProcessInfo.processInfo.environment["WISP_NATIVE_SNAPSHOT_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("share.png"))
        }
    }
}
