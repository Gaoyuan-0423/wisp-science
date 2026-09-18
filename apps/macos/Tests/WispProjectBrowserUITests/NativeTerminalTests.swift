import AppKit
import SwiftTerm
import Foundation
import XCTest
import WispProjectBrowser
@testable import WispProjectBrowserUI

private actor TerminalClient: NativeConversationQuerying {
    var calls: [String] = []
    var arguments: [[String: SettingsValue]] = []
    func recorded() -> [[String: SettingsValue]] { arguments }
    var failWrites = false
    func failInput() { failWrites = true }
    func writes() -> Int { calls.filter { $0.hasSuffix("write") }.count }
    func snapshot(projectID: String, sessionID: String, beforeSeq: Int64?) async throws -> ConversationSnapshot { throw ProjectBrowserError.invalidResponse }
    func invoke(_ command: String, args: [String: SettingsValue], projectID: String) async throws -> SettingsValue {
        calls.append(command); arguments.append(args)
        if command.hasSuffix("write"), failWrites { throw ProjectBrowserError.service("lost response") }
        return .null
    }
}
final class NativeTerminalTests: XCTestCase {
    @MainActor func testNativeEmulatorHandlesCursorControlAndAlternateScreen() throws {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
        view.feed(text: "abc\rXY")
        let normal = view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true)
        XCTAssertEqual(normal, "XYc")
        view.feed(text: "\u{1b}[?1049hAlternate\u{1b}[?1049l")
        XCTAssertEqual(view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true), normal)
        if let directory = ProcessInfo.processInfo.environment["WISP_NATIVE_SNAPSHOT_DIR"] {
            view.feed(text: "\r\n\u{1b}[32mWisp terminal ready\u{1b}[0m\r\n$ ")
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("terminal.png"))
        }
    }
    func testCursorChecksDetectWrongTerminalMissingBytesAndReplay() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        var value = try JSONDecoder().decode(SettingsValue.self, from: Data(contentsOf: root.appendingPathComponent("contracts/native-conversations/v1/terminal-output.json")))
        func decode() throws -> NativeTerminalOutput { try JSONDecoder().decode(NativeTerminalOutput.self, from: JSONEncoder().encode(value)) }
        XCTAssertEqual(try decode().bytes(expectedID: "terminal-a", cursor: nil), Data("hello".utf8))
        XCTAssertThrowsError(try decode().bytes(expectedID: "other", cursor: nil))
        value["reset"] = .bool(false)
        XCTAssertThrowsError(try decode().bytes(expectedID: "terminal-a", cursor: 5))
        XCTAssertEqual(try decode().bytes(expectedID: "terminal-a", cursor: 0).count, 5)
        value["end"] = .integer(6)
        XCTAssertThrowsError(try decode().bytes(expectedID: "terminal-a", cursor: 0))
    }
    @MainActor func testContextLaunchCapturesRequestedContextAndDoesNotReplayFailure() async throws {
        let client = TerminalClient()
        let model = NativeTerminalModel(client: client, projectID: "p", sessionID: "s")
        model.requestOpen("ssh:qa")
        model.requestOpen("local")
        XCTAssertTrue(model.explicitOpenRequested, "The panel must not auto-open local while an explicit launch is pending")
        for _ in 0..<100 { if await client.recorded().count >= 2 { break }; await Task.yield() }
        let calls = await client.recorded()
        XCTAssertEqual(calls.count, 2, "One open and one reconciliation list; no replay or second concurrent launch")
        XCTAssertEqual(calls[0]["context_id"]?.string, "ssh:qa")
        XCTAssertEqual(calls[0]["session_id"]?.string, "s")
        XCTAssertNil(calls[1]["context_id"])
        XCTAssertNotNil(model.error)
    }
    @MainActor func testCoordinatorKeepsOriginWhenCallbacksCrossActorBoundary() async throws {
        let client = TerminalClient()
        let model = NativeTerminalModel(client: client, projectID: "p", sessionID: "s")
        model.select("terminal-a")
        let coordinator = NativeTerminalEmulator.Coordinator(model, terminalID: "terminal-a")
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
        coordinator.send(source: view, data: Array("stale".utf8)[...])
        coordinator.sizeChanged(source: view, newCols: 40, newRows: 10)
        model.select("terminal-b")
        for _ in 0..<30 { await Task.yield() }
        let calls = await client.recorded()
        XCTAssertTrue(calls.isEmpty)
        model.detach()
    }
    @MainActor func testOldEmulatorEventsCannotTargetNewTerminal() async throws {
        let client = TerminalClient()
        let model = NativeTerminalModel(client: client, projectID: "p", sessionID: "s")
        model.select("terminal-a")
        model.select("terminal-b")
        model.send(Data("stale".utf8), terminalID: "terminal-a")
        model.resize(cols: 40, rows: 10, terminalID: "terminal-a")
        model.send(Data("current".utf8), terminalID: "terminal-b")
        model.resize(cols: 80, rows: 24, terminalID: "terminal-b")
        for _ in 0..<100 { if await client.recorded().count == 2 { break }; await Task.yield() }
        let calls = await client.recorded()
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.allSatisfy { $0["terminal_id"]?.string == "terminal-b" })
        XCTAssertEqual(calls[0]["base64"]?.string, Data("current".utf8).base64EncodedString())
        XCTAssertEqual(calls[1]["cols"], .integer(80))
        model.detach()
    }
    @MainActor func testAmbiguousInputStopsQueuedBytesWithoutAutomaticReplay() async throws {
        let client = TerminalClient(); await client.failInput()
        let model = NativeTerminalModel(client: client, projectID: "p", sessionID: "s")
        model.select("terminal-a")
        model.send(Data("first".utf8)); model.send(Data("second".utf8))
        for _ in 0..<100 { if model.inputUncertain { break }; await Task.yield() }
        XCTAssertTrue(model.inputUncertain)
        for _ in 0..<20 { await Task.yield() }
        let count = await client.writes(); XCTAssertEqual(count, 1)
        model.send(Data("third".utf8)); await Task.yield()
        let final = await client.writes(); XCTAssertEqual(final, 1)
        model.detach()
    }
}
