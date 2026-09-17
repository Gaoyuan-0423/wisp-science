import AppKit
import SwiftUI
import WispProjectBrowser

@MainActor
public final class ProjectBrowserModel: ObservableObject {
    @Published private(set) var projects: [ProjectSummary] = []
    @Published private(set) var recentSessions: [BrowserSession] = []
    @Published private(set) var sessions: [BrowserSession] = []
    @Published private(set) var activeProjectID: String?
    @Published private(set) var activeSessionID: String?
    @Published private(set) var messages: [BrowserMessage] = []
    @Published private(set) var transcriptLoading = false
    @Published private(set) var nextBeforeSeq: Int64?
    private var transcriptGeneration = UUID()
    @Published private(set) var sessionsLoading = false
    @Published private(set) var sessionError: String?
    private var navigationGeneration = UUID()
    @Published public private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var lastLoaded: Date?
    @Published private(set) var databaseURL: URL
    private let client: any ProjectBrowserQuerying

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

    init(client: any ProjectBrowserQuerying, databaseURL: URL) {
        self.client = client
        self.databaseURL = databaseURL
    }

    public func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let snapshot = try await client.listProjects(databaseURL: databaseURL)
            let recent = try await client.listSessions(databaseURL: databaseURL, projectID: nil)
            projects = snapshot.projects
            recentSessions = recent
            lastLoaded = Date()
            if let id = activeProjectID { await openProject(id, sessionID: activeSessionID) }
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
        goHome()
        projects = []
        recentSessions = []
        lastLoaded = nil
        Task { await refresh() }
    }

    func goHome() {
        navigationGeneration = UUID()
        transcriptGeneration = UUID()
        messages = []
        nextBeforeSeq = nil
        transcriptLoading = false
        activeProjectID = nil
        activeSessionID = nil
        sessions = []
        sessionError = nil
        sessionsLoading = false
    }

    func openProject(_ id: String, sessionID: String? = nil) async {
        let generation = UUID()
        navigationGeneration = generation
        transcriptGeneration = UUID()
        messages = []
        nextBeforeSeq = nil
        transcriptLoading = false
        activeProjectID = id
        activeSessionID = sessionID
        sessions = []
        sessionError = nil
        sessionsLoading = true
        do {
            let rows = try await client.listSessions(databaseURL: databaseURL, projectID: id)
            guard generation == navigationGeneration else { return }
            sessions = rows
            if let sessionID, !rows.contains(where: { $0.id == sessionID }) {
                sessionError = "这个会话已不存在，请刷新项目列表。"
            } else if let selected = sessionID ?? rows.first?.id {
                await openSession(selected)
            }
        } catch {
            guard generation == navigationGeneration else { return }
            sessionError = error.localizedDescription
        }
        if generation == navigationGeneration { sessionsLoading = false }
    }

    func openSession(_ id: String, older: Bool = false) async {
        guard let projectID = activeProjectID, sessions.contains(where: { $0.id == id }) else { return }
        if older && transcriptLoading { return }
        let generation = UUID()
        transcriptGeneration = generation
        activeSessionID = id
        let cursor = older ? nextBeforeSeq : nil
        if !older { messages = []; nextBeforeSeq = nil }
        transcriptLoading = true
        sessionError = nil
        do {
            let page = try await client.transcript(databaseURL: databaseURL, projectID: projectID, sessionID: id, beforeSeq: cursor)
            guard generation == transcriptGeneration else { return }
            messages = older ? page.messages + messages : page.messages
            nextBeforeSeq = page.nextBeforeSeq
        } catch {
            guard generation == transcriptGeneration else { return }
            sessionError = error.localizedDescription
        }
        if generation == transcriptGeneration { transcriptLoading = false }
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

