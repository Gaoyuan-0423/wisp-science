import XCTest
@testable import WispProjectBrowser

final class NativePanelTabsTests: XCTestCase {
    func testRestoresOrderAndSanitizesOldPreferences() {
        let state = NativePanelTabs(saved: "[\"hosts\",\"files\",\"hosts\",\"future\",\"notebook\"]", selected: "future")
        XCTAssertEqual(state.open, ["hosts", "files"])
        XCTAssertEqual(state.selected, "hosts")
        XCTAssertEqual(NativePanelTabs(saved: "broken").open, NativePanelTabs.defaults)
        XCTAssertEqual(NativePanelTabs(saved: state.saved, selected: state.selected), state)
    }
    func testClosingUsesLeftNeighborAndLastCloseKeepsEmptyUntilReopened() {
        var state = NativePanelTabs(selected: "files")
        state.remove("files")
        XCTAssertEqual(state.selected, "agents")
        state.remove("artifacts")
        XCTAssertEqual(state.selected, "agents")
        state.remove("agents")
        XCTAssertEqual(state.selected, "hosts")
        state.remove("hosts")
        XCTAssertTrue(state.open.isEmpty)
        XCTAssertTrue(NativePanelTabs(saved: state.saved).open.isEmpty)
        state.reopen()
        XCTAssertEqual(state.open, NativePanelTabs.defaults)
        XCTAssertEqual(state.selected, "artifacts")
    }
    func testMoveAndShowPreserveSelectionAndNeverDuplicate() {
        var state = NativePanelTabs(selected: "agents")
        state.move("artifacts", to: "files")
        XCTAssertEqual(state.open, ["agents", "files", "artifacts", "hosts"])
        XCTAssertEqual(state.selected, "agents")
        state.move("hosts", to: "agents")
        XCTAssertEqual(state.open, ["hosts", "agents", "files", "artifacts"])
        state.remove("files"); state.show("files"); state.show("files")
        XCTAssertEqual(state.open, ["hosts", "agents", "artifacts", "files"])
        XCTAssertEqual(state.selected, "files")
        state.show("notebook")
        XCTAssertEqual(state.selected, "files")
        state.move("unknown", to: "files")
        XCTAssertEqual(state.open.count, 4)
    }
    func testOptionalSurfacesCanOptIntoStableRegistry() {
        var state = NativePanelTabs(available: NativePanelTabs.all)
        state.show("notebook"); state.show("highlights"); state.show("provenance"); state.show("sidechat")
        XCTAssertEqual(state.open.count, 8)
        XCTAssertEqual(NativePanelTabs(saved: state.saved, selected: state.selected, available: NativePanelTabs.all), state)
    }
}
