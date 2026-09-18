import Foundation
import SwiftUI
import AppKit
import XCTest
import WispProjectBrowser
@testable import WispProjectBrowserUI

private actor PanelClient: NativeConversationQuerying {
    let rows: SettingsValue
    var mutations = 0
    func mutationCount() -> Int { mutations }
    var held: CheckedContinuation<SettingsValue, Error>?
    init(_ rows: SettingsValue) { self.rows = rows }
    func snapshot(projectID: String, sessionID: String, beforeSeq: Int64?) async throws -> ConversationSnapshot { throw ProjectBrowserError.invalidResponse }
    func invoke(_ command: String, args: [String: SettingsValue], projectID: String) async throws -> SettingsValue {
        if command.hasSuffix("context_enabled") { mutations += 1; throw ProjectBrowserError.invalidResponse }
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
    @MainActor func testPreviewQuotePreservesSourceAndRejectsDismissedOrChangedFile() throws {
        let rows = try fixture("panel-preview")
        let model = NativePanelModel(client: PanelClient(rows), projectID: "p", sessionID: "s")
        let preview = try JSONDecoder().decode(NativePanelFileContent.self, from: JSONEncoder().encode(rows))
        let text = try XCTUnwrap(preview.text)
        model.preview = preview
        let quote = try XCTUnwrap(model.selectedPreviewQuote(text, path: preview.path))
        XCTAssertEqual(quote.text, text); XCTAssertEqual(quote.source, preview.path)
        XCTAssertNil(model.selectedPreviewQuote(text, path: "other.txt"))
        XCTAssertNil(model.selectedPreviewQuote("not contained in the preview", path: preview.path))
        XCTAssertNil(model.selectedPreviewQuote("  ", path: preview.path))
        model.dismissPreview()
        XCTAssertNil(model.selectedPreviewQuote(text, path: preview.path))
        model.preview = preview; model.close()
        XCTAssertNil(model.selectedPreviewQuote(text, path: preview.path))
    }
    @MainActor func testRenderContextsAtNarrowPanelWidth() async throws {
        guard let directory = ProcessInfo.processInfo.environment["WISP_NATIVE_SNAPSHOT_DIR"] else { throw XCTSkip("Opt-in native rendering") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let model = NativePanelModel(client: PanelClient(try fixture("panel-contexts")), projectID: "p", sessionID: "s")
        await model.refresh("hosts")
        for (name, scheme) in [("contexts-light", ColorScheme.light), ("contexts-dark", ColorScheme.dark)] {
            let view = NSHostingView(rootView: VStack(alignment: .leading, spacing: 10) {
                NativePanelContextsView(model: model)
                Spacer()
            }.padding(12).frame(width: 280, height: 500).background(WispDesign.color("bg-sunken", scheme)).environment(\.colorScheme, scheme))
            view.frame = NSRect(x: 0, y: 0, width: 280, height: 500)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
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
    @MainActor func testContextsAreSessionScopedAndFailedMutationIsNotReplayed() async throws {
        let client = PanelClient(try fixture("panel-contexts"))
        let model = NativePanelModel(client: client, projectID: "p", sessionID: "s")
        await model.refresh("hosts")
        XCTAssertEqual(model.contexts?.attached.map(\.id), ["local", "ssh:gpu"])
        XCTAssertEqual(model.contexts?.available.map(\.id), ["wsl:ubuntu"])
        await model.setContext("wsl:ubuntu", enabled: true)
        let count = await client.mutationCount()
        XCTAssertEqual(count, 1)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.contexts?.enabled_ids, ["ssh:gpu"])
    }
    @MainActor func testReadOnlyContextCannotBeChanged() async throws {
        var rows = try fixture("panel-contexts"); rows["read_only"] = .bool(true)
        let client = PanelClient(rows)
        let model = NativePanelModel(client: client, projectID: "p", sessionID: "s")
        await model.refresh("hosts")
        await model.setContext("ssh:gpu", enabled: false)
        let count = await client.mutationCount(); XCTAssertEqual(count, 0)
    }
    func testTruncatedPreviewRetainsFullSize() throws {
        let preview = try JSONDecoder().decode(NativePanelFileContent.self, from: JSONEncoder().encode(fixture("panel-preview")))
        XCTAssertTrue(preview.truncated)
        XCTAssertEqual(preview.total_bytes, 8_000_000)
        XCTAssertEqual(preview.text, "preview prefix")
    }
}
