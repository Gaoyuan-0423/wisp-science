import AppKit
import SwiftUI
import WispProjectBrowser

@main
struct WispSciencePreview: App {
    @StateObject private var model = ProjectBrowserModel()

    var body: some Scene {
        WindowGroup("Wisp Science — 原生预览") {
            ProjectBrowserView(model: model)
                .frame(minWidth: 860, minHeight: 560)
                .task { await model.refresh() }
        }
        .defaultSize(width: 1120, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("选择数据库…") { model.chooseDatabase() }
                    .keyboardShortcut("o")
                    .disabled(model.isLoading)
            }
            CommandGroup(after: .newItem) {
                Button("刷新项目") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
                    .disabled(model.isLoading)
            }
        }
    }
}

@MainActor
final class ProjectBrowserModel: ObservableObject {
    @Published private(set) var projects: [ProjectSummary] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var lastLoaded: Date?
    @Published private(set) var databaseURL: URL
    private let client: ProjectBrowserClient

    init() {
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

    func refresh() async {
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

    func chooseDatabase() {
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

struct ProjectBrowserView: View {
    @ObservedObject var model: ProjectBrowserModel
    @State private var selection: String?
    @State private var search = ""

    private var filtered: [ProjectSummary] {
        guard !search.isEmpty else { return model.projects }
        return model.projects.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.description.localizedCaseInsensitiveContains(search)
                || $0.workspaceDirectory.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Wisp Science").font(.title2.weight(.semibold))
                    Text("\(model.projects.count) 个本地项目").foregroundStyle(.secondary)
                }
                .padding(20)
                List(selection: $selection) {
                    ForEach(filtered) { project in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(project.name).font(.headline).lineLimit(1)
                                if project.starred {
                                    Text("已收藏").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Text("\(project.sessionCount) 会话 · \(project.artifactCount) 产物")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(project.workspaceDirectory)
                                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        .padding(.vertical, 6)
                        .tag(project.id)
                        .accessibilityIdentifier("project-\(project.id)")
                    }
                }
                .listStyle(.sidebar)
                .searchable(text: $search, prompt: "搜索项目或目录")
                if !search.isEmpty && filtered.isEmpty {
                    Text("没有匹配的项目").foregroundStyle(.secondary).padding()
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 310, max: 440)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                if let error = model.error {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("无法刷新项目").font(.headline)
                        Text(error).font(.callout).textSelection(.enabled)
                    }
                    .padding().frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12))
                }
                if let project = model.projects.first(where: { $0.id == selection }) {
                    projectDetail(project)
                } else {
                    VStack(spacing: 12) {
                        Text(model.isLoading ? "正在读取本地项目…" : "你的研究项目")
                            .font(.title.weight(.semibold))
                        Text(model.projects.isEmpty
                             ? "选择现有 Wisp 数据库，浏览项目、会话数量和产物。"
                             : "从左侧选择一个项目，查看详情与工作目录。")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        if model.projects.isEmpty && !model.isLoading {
                            Button("选择数据库…") { model.chooseDatabase() }
                        }
                    }
                    .padding(36).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("只读预览 · 实时运行与审批状态尚未接入")
                        .font(.callout.weight(.medium))
                    Text(model.databaseURL.path).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(2)
                    if let loaded = model.lastLoaded {
                        Text("上次成功读取：\(loaded.formatted(date: .omitted, time: .standard))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .toolbar {
            if model.isLoading { ProgressView().controlSize(.small) }
            Button("选择数据库…") { model.chooseDatabase() }.disabled(model.isLoading)
            Button("刷新") { Task { await model.refresh() } }
                .disabled(model.isLoading).accessibilityIdentifier("refresh-projects")
        }
        .onChange(of: model.projects.map(\.id)) { ids in
            if !ids.contains(selection ?? "") { selection = ids.first }
        }
    }

    private func projectDetail(_ project: ProjectSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("项目概览").font(.subheadline).foregroundStyle(.secondary)
                    Text(project.name).font(.largeTitle.weight(.semibold)).textSelection(.enabled)
                    Text(project.description.isEmpty ? "尚未填写项目描述" : project.description)
                        .foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack(spacing: 14) {
                    metric("会话", project.sessionCount)
                    metric("产物", project.artifactCount)
                    metric("待查看回复", project.needsYouCount)
                }
                VStack(alignment: .leading, spacing: 18) {
                    field("工作目录", project.workspaceDirectory)
                    field("最近活动", timestamp(project.updatedAt))
                    field("同步状态", project.syncConfigured ? "已建立同步" : "尚未建立同步")
                    if let synced = project.lastSyncedAt { field("上次同步", timestamp(synced)) }
                    field("项目 ID", project.id)
                }
                Button("在 Finder 中显示") { model.reveal(project) }
                    .controlSize(.large)
                    .disabled(!ProjectBrowserModel.workspaceExists(project))
                if !ProjectBrowserModel.workspaceExists(project) {
                    Text("工作目录当前不可用，项目记录仍保留在数据库中。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(36).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metric(_ label: String, _ count: Int64) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(count.formatted()).font(.title.weight(.semibold)).monospacedDigit()
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(18)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func timestamp(_ seconds: Int64) -> String {
        guard seconds > 0 else { return "暂无记录" }
        return Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(date: .abbreviated, time: .shortened)
    }
}
