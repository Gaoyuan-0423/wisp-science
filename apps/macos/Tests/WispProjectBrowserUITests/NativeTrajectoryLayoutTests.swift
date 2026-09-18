import AppKit
import SwiftUI
import XCTest
import WispProjectBrowser
@testable import WispProjectBrowserUI

private actor TrajectoryLayoutClient: NativeConversationQuerying {
    let value: SettingsValue
    init(_ value: SettingsValue) { self.value = value }
    func snapshot(projectID: String, sessionID: String, beforeSeq: Int64?) async throws -> ConversationSnapshot { throw ProjectBrowserError.invalidResponse }
    func invoke(_ command: String, args: [String: SettingsValue], projectID: String) async throws -> SettingsValue { value }
}
final class NativeTrajectoryLayoutTests: XCTestCase {
    struct Fixture: Decodable {
        struct Case: Decodable { let name: String; let axis: NativeTrajectoryAxis; let query: String; let turns: [NativeTrajectoryTurn]; let segments: [NativeTrajectorySegment] }
        struct Timing: Decodable { let turn: Int64; let input: Double; let model: Double; let tools: Double }
        let cases: [Case]; let timing: [Timing]
    }
    func fixture() throws -> Fixture {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("contracts/native-conversations/v1/trajectory-layout.json")))
    }
    func testTimelineMatchesSharedWebViewFixture() throws {
        let fixture = try fixture()
        for item in fixture.cases {
            let rows = NativeTrajectoryRow.collect(item.turns, query: item.query)
            let actual = NativeTrajectorySegment.collect(rows, axis: item.axis)
            XCTAssertEqual(actual.count, item.segments.count, item.name)
            for (actual, expected) in zip(actual, item.segments) {
                XCTAssertEqual(actual.key, expected.key); XCTAssertEqual(actual.lane, expected.lane)
                XCTAssertEqual(actual.left_pct, expected.left_pct, accuracy: 0.000001)
                XCTAssertEqual(actual.width_pct, expected.width_pct, accuracy: 0.000001)
            }
        }
        for expected in fixture.timing {
            let turn = try XCTUnwrap(fixture.cases[0].turns.first { $0.index == expected.turn })
            let actual = try XCTUnwrap(NativeTrajectoryTiming.collect(turn.cells))
            XCTAssertEqual(actual.input, expected.input); XCTAssertEqual(actual.model, expected.model); XCTAssertEqual(actual.tools, expected.tools)
        }
        XCTAssertNil(NativeTrajectoryTiming.collect(fixture.cases[4].turns[0].cells))
    }
    func testInspectorUsesRecordedStatusPreviewAndSource() throws {
        let cells = try fixture().cases[0].turns[0].cells
        XCTAssertEqual(cells[2].status(running: true), "running")
        XCTAssertEqual(cells[2].status(running: false), "pending")
        XCTAssertEqual(cells[1].status(running: true), "completed")
        XCTAssertEqual(cells[0].preview, "Question"); XCTAssertEqual(cells[0].source, "Question")
        let raw = try JSONDecoder().decode(SettingsValue.self, from: Data(cells[0].rawJSON.utf8))
        XCTAssertEqual(raw["kind"].string, "user")
        var failed = try JSONDecoder().decode(SettingsValue.self, from: JSONEncoder().encode(cells[2]))
        failed["ok"] = .bool(false)
        let cell = try JSONDecoder().decode(NativeTrajectoryCell.self, from: JSONEncoder().encode(failed))
        XCTAssertEqual(cell.status(running: true), "error")
    }
    @MainActor func testRenderFullTrajectoryAtNarrowAndDesktopWidths() async throws {
        guard let directory = ProcessInfo.processInfo.environment["WISP_NATIVE_SNAPSHOT_DIR"] else { throw XCTSkip("Opt-in rendering") }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        var value = try JSONDecoder().decode(SettingsValue.self, from: Data(contentsOf: root.appendingPathComponent("contracts/native-conversations/v1/trajectory.json")))
        value["turns"] = try JSONDecoder().decode(SettingsValue.self, from: JSONEncoder().encode(fixture().cases[0].turns))
        let model = NativeTrajectoryModel(client: TrajectoryLayoutClient(value), projectID: "project-a", sessionID: "session-a")
        await model.refresh(); XCTAssertNil(model.error)
        for (name, scheme, width) in [("trajectory-full-light", ColorScheme.light, 640.0), ("trajectory-full-dark", ColorScheme.dark, 980.0)] {
            let view = NSHostingView(rootView: NativeTrajectoryView(model: model, close: {}).background(WispDesign.color("bg-elev", scheme)).environment(\.colorScheme, scheme))
            view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            view.frame = NSRect(x: 0, y: 0, width: width, height: 650); view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }
    @MainActor func testRenderTimelineLanesAtNarrowAndDesktopWidths() throws {
        guard let directory = ProcessInfo.processInfo.environment["WISP_NATIVE_SNAPSHOT_DIR"] else { throw XCTSkip("Opt-in rendering") }
        let rows = NativeTrajectoryRow.collect(try fixture().cases[0].turns)
        for (name, scheme, width) in [("trajectory-lanes-light", ColorScheme.light, 640.0), ("trajectory-lanes-dark", ColorScheme.dark, 980.0)] {
            let view = NSHostingView(rootView: VStack(alignment: .leading, spacing: 18) {
                Text("运行轨迹").font(.title2.bold())
                ForEach(NativeTrajectoryAxis.allCases, id: \.self) { axis in
                    Text(axis.rawValue).font(.caption)
                    NativeTrajectoryChart(rows: rows, axis: axis, selected: "1:1", select: { _ in })
                }
                Spacer()
            }.padding(20).background(WispDesign.color("bg-elev", scheme)).environment(\.colorScheme, scheme))
            view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            view.frame = NSRect(x: 0, y: 0, width: width, height: 460); view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }
}
