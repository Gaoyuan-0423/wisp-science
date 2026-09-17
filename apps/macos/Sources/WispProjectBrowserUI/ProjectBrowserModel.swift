import AppKit
import SwiftUI
import WispProjectBrowser

@MainActor
public final class ProjectBrowserModel: ObservableObject {
    @Published private(set) var projects: [ProjectSummary] = []
    @Published public private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var lastLoaded: Date?
    @Published private(set) var databaseURL: URL
    private let client: ProjectBrowserClient

    public init() {
        let environment = ProcessInfo.processInfo.environment
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let defaultDatabase = support.appendingPathComponent("science.wisp-science/wisp-science/wisp.sqlite")
        let saved = environment["WISP_BROWSER_DATABASE"] ?? UserDefaults.standard.string(forKey: "projectBrowser.database")
        databaseURL = saved.map { URL(fileURLWithPath: $0) } ?? defaultDatabase
        let executable = environment["WISP_SERVICE_PATH"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.url(forAuxiliaryExecutable: "wisp-service")
            ?? Bundle.main.bundleURL.appendingPathComponent("wisp-service")
        client = ProjectBrowserClient(executableURL: executable)
    }

    public func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let snapshot = try await client.listProjects(databaseURL: databaseURL)
            projects = snapshot.projects
            lastLoaded = Date()
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func chooseDatabase() {
        let panel = NSOpenPanel()
        panel.title = "选择 Wisp 数据库"
        panel.message = "仅查询已有的 wisp.sqlite，不修改数据或执行数据库升级。"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = databaseURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        databaseURL = url
        UserDefaults.standard.set(url.path, forKey: "projectBrowser.database")
        projects = []
        lastLoaded = nil
        Task { await refresh() }
    }

    func reveal(_ project: ProjectSummary) {
        let url = URL(fileURLWithPath: project.workspaceDirectory, isDirectory: true)
        guard Self.workspaceExists(project) else {
            error = "项目目录不存在或当前无法访问：\(project.workspaceDirectory)"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func workspaceExists(_ project: ProjectSummary) -> Bool {
        guard !project.workspaceDirectory.isEmpty else { return false }
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: project.workspaceDirectory, isDirectory: &directory)
            && directory.boolValue
    }
}

