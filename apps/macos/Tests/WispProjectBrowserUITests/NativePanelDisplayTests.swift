import AppKit
import SwiftUI
import XCTest
@testable import WispProjectBrowserUI

final class NativePanelDisplayTests: XCTestCase {
    @MainActor func testRenderBothModesAtSidebarWidths() throws {
        guard let directory = ProcessInfo.processInfo.environment["WISP_NATIVE_SNAPSHOT_DIR"] else { throw XCTSkip("Opt-in native rendering") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for grid in [false, true] {
            for scheme in [ColorScheme.light, .dark] {
                let view = NSHostingView(rootView: VStack(alignment: .leading) {
                    NativePanelDisplayControls(grid: .constant(grid))
                    LazyVGrid(columns: grid ? [GridItem(.adaptive(minimum: 130), alignment: .top)] : [GridItem(.flexible())], alignment: .leading) {
                        ForEach(0..<4) { index in
                            NativePanelTile(title: index == 0 ? "样本质量控制汇总报告.md" : "counts-\(index).csv", subtitle: "results/quality-control/样本批次/analysis-output", icon: index == 3 ? "folder" : "doc", grid: grid)
                        }
                    }
                    Spacer()
                }.padding(12).background(WispDesign.color("bg-sunken", scheme)).environment(\.colorScheme, scheme))
                view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                view.frame = NSRect(x: 0, y: 0, width: 320, height: 480)
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(data.count, 1000)
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("panel-\(grid ? "grid" : "list")-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }
}
