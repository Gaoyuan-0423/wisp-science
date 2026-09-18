import AppKit
import Foundation
import SwiftUI
import XCTest
import WispProjectBrowser
@testable import WispProjectBrowserUI

final class NativeShareTests: XCTestCase {
    func fixture(_ name: String = "share") throws -> [NativeShareRow] {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try JSONDecoder().decode([NativeShareRow].self, from: Data(contentsOf: root.appendingPathComponent("contracts/native-conversations/v1/\(name).json")))
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
    func testTablesPreserveEscapedAndCodePipesAndPadShortRows() {
        let blocks = NativeShareMarkdown.blocks("| Sample | Value |\n| --- | :---: |\n| A | `x|y` |\n| B | one\\|two |\n| C |")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, "table")
        XCTAssertEqual(blocks[0].alignments, ["left", "center"])
        XCTAssertEqual(blocks[0].rows, [["Sample", "Value"], ["A", "`x|y`"], ["B", "one\\|two"], ["C", ""]])
        XCTAssertEqual(NativeShareMarkdown.blocks("a | b\nnot | divider").first?.kind, "paragraph")
    }
    func testNestedListsAndLongFencesKeepTheirStructure() {
        let blocks = NativeShareMarkdown.blocks("1. first\n   - nested\n2) second\n\n````markdown\n```python\nprint(1)\n```\n````\n## Results")
        XCTAssertEqual(blocks.map(\.kind), ["ordered", "bullet", "ordered", "code", "heading"])
        XCTAssertEqual(blocks[0].marker, "1.")
        XCTAssertEqual(blocks[1].level, 1)
        XCTAssertEqual(blocks[2].marker, "2.")
        XCTAssertEqual(blocks[3].text, "```python\nprint(1)\n```")
        XCTAssertEqual(blocks[4].level, 2)
    }
    @MainActor func testComplexMarkdownPNGAtNarrowAndWideWidths() throws {
        let rows = try fixture("share-complex")
        for width in [320, 840] {
            let data = try NativeSharePage.png(rows: rows, width: width, scheme: .light)
            let image = try XCTUnwrap(NSBitmapImageRep(data: data))
            XCTAssertEqual(image.pixelsWide, width)
            XCTAssertGreaterThan(image.pixelsHigh, 300)
            if let directory = ProcessInfo.processInfo.environment["WISP_NATIVE_SNAPSHOT_DIR"] {
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("share-complex-\(width).png"))
            }
        }
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
