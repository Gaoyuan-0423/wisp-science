import XCTest
import WispProjectBrowser
@testable import WispProjectBrowserUI

private actor SettingsFake: NativeSettingsQuerying {
    var writes: [(String, [String: SettingsValue], String?)] = []
    var persisted: SettingsValue = .object(["locale": .string("zh"), "notifications_enabled": .bool(true), "future_option": .string("preserve")])
    var fail = false
    var held: CheckedContinuation<SettingsValue, Error>?
    var holdReads = false
    func invoke(_ command: String, args: [String: SettingsValue], projectID: String?) async throws -> SettingsValue {
        if command == "get_settings" {
            if holdReads { return try await withCheckedThrowingContinuation { held = $0 } }
            return persisted
        }
        if command == "set_settings" {
            writes.append((command, args, projectID))
            if fail { throw ProjectBrowserError.service("Save rejected") }
            persisted = args["settings"]!; return .null
        }
        return .object([:])
    }
    func setFail() { fail = true }
    func writeCount() -> Int { writes.count }
    func lastWrite() -> (String, [String: SettingsValue], String?)? { writes.last }
    func hold() { holdReads = true }
    func isHeld() -> Bool { held != nil }
    func finish() { holdReads = false; held?.resume(returning: .object(["locale": .string("stale")])); held = nil }
}

final class NativeSettingsModelTests: XCTestCase {
    @MainActor func testDraftSurvivesTabsAndSaveKeepsUneditedFieldsAndProject() async {
        let client = SettingsFake(); let model = NativeSettingsModel(client: client, projectID: "project-a")
        await model.load()
        model.binding("get_settings", "locale").wrappedValue = .string("en")
        XCTAssertTrue(model.hasUnsavedChanges)
        model.section = .session; await model.load()
        XCTAssertEqual(model.values["get_settings"]?["locale"], .string("en"))
        await model.saveSettings()
        let write = await client.lastWrite()
        XCTAssertEqual(write?.2, "project-a")
        XCTAssertEqual(write?.1["settings"]?["future_option"], .string("preserve"))
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertNil(model.error)
    }
    @MainActor func testRejectedSaveKeepsDraftWithoutRetry() async {
        let client = SettingsFake(); let model = NativeSettingsModel(client: client, projectID: nil)
        await model.load(); model.binding("get_settings", "locale").wrappedValue = .string("en")
        await client.setFail(); await model.saveSettings()
        let count = await client.writeCount(); XCTAssertEqual(count, 1)
        XCTAssertNotNil(model.error); XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertEqual(model.values["get_settings"]?["locale"], .string("en"))
        model.discardDrafts(); XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertEqual(model.values["get_settings"]?["locale"], .string("zh"))
    }
    @MainActor func testLeavingIgnoresLateRead() async {
        let client = SettingsFake(); let model = NativeSettingsModel(client: client, projectID: "a")
        await client.hold()
        let loading = Task { await model.load() }
        while !(await client.isHeld()) { await Task.yield() }
        model.leave(); await client.finish(); await loading.value
        XCTAssertNil(model.values["get_settings"])
    }
    func testNineteenSectionsMatchSharedNavigation() {
        XCTAssertEqual(NativeSettingsSection.allCases.count, 19)
        XCTAssertEqual(NativeSettingsSection.allCases.map(\.rawValue), ["general", "session", "appearance", "pet", "models", "quick-actions", "workflows", "specialists", "memory", "skills", "plugins", "browser", "connections", "channels", "credentials", "permissions", "environments", "storage", "usage"])
    }
    func testSearchUsesWebViewAliasesAndRequiresEveryTerm() {
        XCTAssertTrue(NativeSettingsSection.channels.matches("同步"))
        XCTAssertTrue(NativeSettingsSection.models.matches("API key"))
        XCTAssertTrue(NativeSettingsSection.environments.matches(" SSH  runtime "))
        XCTAssertFalse(NativeSettingsSection.appearance.matches("theme ssh"))
        XCTAssertEqual(Set(NativeSettingsSection.allCases.map(\.group)), ["基础偏好", "AI 配置", "工具与连接", "系统与资源"])
    }

    func testEveryExportedThemeHasEveryPreviewToken() {
        for (_, palette) in WispDesign.palettes {
            for token in ["bg-app", "bg-elev", "bg-sunken", "text", "text-muted", "border", "clay"] {
                XCTAssertNotNil(palette[token], "Missing preview token: \(token)")
            }
        }
        XCTAssertEqual(WispDesign.modelPresets.count, 6)
        XCTAssertTrue(WispDesign.modelPresets.allSatisfy { $0["url"]?.hasPrefix("https://") == true })
    }

}
