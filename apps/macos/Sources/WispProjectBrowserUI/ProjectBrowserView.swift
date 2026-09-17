import SwiftUI
import WispProjectBrowser

public struct ProjectBrowserView: View {
    @ObservedObject private var model: ProjectBrowserModel
    @State private var presentation = ProjectBrowserPresentation()
    @AppStorage("projectBrowser.appearance") private var appearance = "system"

    public init(model: ProjectBrowserModel) { self.model = model }

    public var body: some View {
        ProjectLanding(model: model, presentation: $presentation, appearance: $appearance)
            .preferredColorScheme(appearance == "system" ? nil : (appearance == "dark" ? .dark : .light))
            .onChange(of: model.projects.map(\.id)) { _ in presentation.reconcile(model.projects) }
            .onChange(of: presentation.search) { _ in presentation.reconcile(model.projects) }
            .onChange(of: presentation.starredOnly) { _ in presentation.reconcile(model.projects) }
    }
}

private struct ProjectLanding: View {
    @ObservedObject var model: ProjectBrowserModel
    @Binding var presentation: ProjectBrowserPresentation
    @Binding var appearance: String
    @Environment(\.colorScheme) private var scheme
    @FocusState private var searchFocused: Bool

    private var projects: [ProjectSummary] { presentation.visibleProjects(model.projects) }
    private func color(_ token: String) -> Color { WispDesign.color(token, scheme) }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header.padding(.bottom, 32)
                    if let error = model.error { errorBanner(error).padding(.bottom, 20) }
                    let columns = geometry.size.width < 820
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 26))
                        : AnyLayout(HStackLayout(alignment: .top, spacing: 40))
                    columns {
                        projectList.frame(maxWidth: .infinity, alignment: .topLeading)
                        projectOverview.frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    Spacer(minLength: 40)
                    footer
                }
                .frame(maxWidth: 1200, minHeight: max(0, geometry.size.height - 80), alignment: .topLeading)
                .padding(.horizontal, min(48, max(24, geometry.size.width * 0.04)))
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity)
            }
            .background {
                color("bg-app")
                    .overlay(alignment: .top) {
                        Ellipse().fill(color("clay").opacity(0.08))
                            .frame(width: geometry.size.width * 0.7, height: 180)
                            .blur(radius: 80).offset(y: -150)
                    }
                    .ignoresSafeArea()
            }
        }
        .font(.system(size: 14)).foregroundStyle(color("text"))
        .tint(color("clay"))
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) { brand; Spacer(minLength: 0); actions }
            VStack(alignment: .leading, spacing: 24) {
                brand
                actions.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var brand: some View {
        HStack(spacing: 24) {
            Image(nsImage: WispDesign.image(scheme == .dark ? "wordmark-dark" : "wordmark-light"))
                .resizable().scaledToFit().frame(width: 180, height: 119)
                .accessibilityLabel("Wisp Science")
            VStack(alignment: .leading, spacing: 8) {
                Text("严谨做科研，").foregroundStyle(color("text-muted"))
                Text("Wisp Science 在身边。").foregroundStyle(color("clay-strong"))
            }
            .font(.system(size: 16, weight: .medium)).fixedSize()
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                WispIcon(name: "search", size: 16).foregroundStyle(color("text-faint"))
                TextField("搜索项目或目录", text: $presentation.search)
                    .textFieldStyle(.plain).font(.system(size: 13)).focused($searchFocused)
                    .accessibilityIdentifier("project-search")
            }
            .padding(.horizontal, 10).frame(width: 158, height: 38)
            .background(color("bg-elev"), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color(searchFocused ? "clay" : "border")))
            Button { presentation.starredOnly.toggle() } label: {
                WispIcon(name: presentation.starredOnly ? "star-filled" : "star")
                    .foregroundStyle(color(presentation.starredOnly ? "clay" : "text-muted"))
            }
            .buttonStyle(WispButtonStyle()).help(presentation.starredOnly ? "显示所有项目" : "只看已收藏项目")
            .accessibilityLabel(presentation.starredOnly ? "显示所有项目" : "只看已收藏项目")
            .accessibilityIdentifier("filter-starred")
            Button { Task { await model.refresh() } } label: {
                if model.isLoading { ProgressView().controlSize(.small).frame(width: 18, height: 18) }
                else { WispIcon(name: "refresh") }
            }
            .buttonStyle(WispButtonStyle()).disabled(model.isLoading)
            .help("刷新项目 · ⌘R").accessibilityLabel("刷新项目").accessibilityIdentifier("refresh-projects")
            Button { model.chooseDatabase() } label: {
                HStack(spacing: 7) { WispIcon(name: "database", size: 16); Text("选择数据库") }
            }
            .buttonStyle(WispButtonStyle(primary: true)).disabled(model.isLoading)
            .help("选择已有的 Wisp 数据库 · ⌘O")
        }
    }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(presentation.starredOnly ? "已收藏项目" : "项目").font(.system(size: 18, weight: .semibold))
                Text("\(projects.count)").font(.system(size: 12)).foregroundStyle(color("text-faint"))
            }
            if projects.isEmpty {
                emptyState(model.isLoading ? "正在读取本地项目…" : (model.projects.isEmpty ? "还没有项目记录" : "没有匹配的项目"),
                           model.projects.isEmpty ? "选择已有的 Wisp 数据库，读取你的研究项目。" : "试试其他关键词，或关闭收藏筛选。")
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(projects) { project in
                        ProjectCard(project: project, selected: project.id == presentation.selectedID,
                                    select: { presentation.selectedID = project.id }, reveal: { model.reveal(project) })
                    }
                }
            }
        }
    }

    private var projectOverview: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("项目概览").font(.system(size: 18, weight: .semibold))
            if let project = projects.first(where: { $0.id == presentation.selectedID }) {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(project.name).font(.system(size: 17, weight: .semibold)).textSelection(.enabled)
                        Text(project.description.isEmpty ? "尚未填写项目描述" : project.description)
                            .font(.system(size: 13)).foregroundStyle(color("text-muted"))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) { metrics(project) }
                        VStack(alignment: .leading, spacing: 10) { metrics(project) }
                    }
                    Rectangle().fill(color("border")).frame(height: 1)
                    field("工作目录", project.workspaceDirectory, monospaced: true)
                    field("最近活动", timestamp(project.updatedAt))
                    field("同步状态", project.syncConfigured ? "已建立同步" : "尚未建立同步")
                    if let synced = project.lastSyncedAt { field("上次同步", timestamp(synced)) }
                    field("项目 ID", project.id, monospaced: true)
                    Button { model.reveal(project) } label: {
                        HStack(spacing: 7) { WispIcon(name: "folder", size: 16); Text("在 Finder 中显示") }
                    }
                    .buttonStyle(WispButtonStyle())
                    .disabled(!ProjectBrowserModel.workspaceExists(project))
                    if !ProjectBrowserModel.workspaceExists(project) {
                        Text("工作目录当前不可用，项目记录仍保留。")
                            .font(.system(size: 12)).foregroundStyle(color("text-faint"))
                    }
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(color("bg-elev"), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color("border")))
                .accessibilityIdentifier("project-overview")
            } else {
                emptyState("选择一个研究项目", "项目的工作目录、会话和产物信息会显示在这里。")
            }
        }
    }

    private func metrics(_ project: ProjectSummary) -> some View {
        Group {
            metric("chat", "\(project.sessionCount) 会话")
            metric("doc", "\(project.artifactCount) 产物")
            Text("\(project.needsYouCount) 待查看回复")
                .font(.system(size: 12)).foregroundStyle(color("clay-strong"))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(color("clay").opacity(0.10), in: Capsule())
        }
    }

    private func metric(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 6) { WispIcon(name: icon, size: 15); Text(text) }
            .font(.system(size: 13)).foregroundStyle(color("text-muted"))
    }

    private func field(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 11)).foregroundStyle(color("text-faint"))
            Text(value).font(.system(size: 13, design: monospaced ? .monospaced : .default))
                .foregroundStyle(color("text-muted")).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func emptyState(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .medium))
            Text(detail).font(.system(size: 13)).foregroundStyle(color("text-faint"))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20).frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
        .background(color("bg-elev"), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color("border")))
    }

    private func errorBanner(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("无法刷新项目").font(.system(size: 13, weight: .semibold))
            Text(error).font(.system(size: 12)).textSelection(.enabled)
            if model.lastLoaded != nil { Text("当前显示上次成功读取的项目。实时数据可能已变化。").font(.system(size: 12)) }
        }
        .padding(13).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Text("SwiftUI 原生预览 · 只读 · 实时运行与审批状态尚未接入")
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                if let loaded = model.lastLoaded {
                    Text("更新于 \(loaded.formatted(date: .omitted, time: .standard))")
                }
                Text(model.databaseURL.lastPathComponent).help(model.databaseURL.path)
                Menu {
                    Picker("外观", selection: $appearance) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                } label: { Text("外观") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("外观")
            }
            .font(.system(size: 11))
        }
        .font(.system(size: 12)).foregroundStyle(color("text-faint"))
        .frame(maxWidth: .infinity)
    }
}

private struct ProjectCard: View {
    let project: ProjectSummary
    let selected: Bool
    let select: () -> Void
    let reveal: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    private func color(_ token: String) -> Color { WispDesign.color(token, scheme) }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(project.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        if project.starred { WispIcon(name: "star-filled", size: 13).foregroundStyle(color("clay")) }
                    }
                    Text(project.workspaceDirectory).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(color("text-faint")).lineLimit(1).truncationMode(.head)
                        .help(project.workspaceDirectory)
                    HStack(spacing: 8) {
                        Text("\(project.sessionCount) 会话 · \(project.artifactCount) 产物")
                        if project.needsYouCount > 0 {
                            Text("\(project.needsYouCount) 待查看").foregroundStyle(color("clay-strong"))
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12)).foregroundStyle(color("text-faint"))
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 16).padding(.leading, 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityIdentifier("project-\(project.id)")
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            VStack(alignment: .trailing, spacing: 8) {
                Text(shortTimestamp(project.updatedAt)).font(.system(size: 11)).foregroundStyle(color("text-faint"))
                Button(action: reveal) { WispIcon(name: "folder", size: 16).frame(width: 28, height: 28) }
                    .buttonStyle(.plain).foregroundStyle(color("text-muted"))
                    .disabled(!ProjectBrowserModel.workspaceExists(project))
                    .help("在 Finder 中显示").accessibilityLabel("在 Finder 中显示 \(project.name)")
            }
            .padding(.trailing, 12)
        }
        .background(color("bg-elev"), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color(selected || hovering ? "clay" : "border")))
        .shadow(color: Color.black.opacity(0.035), radius: 2, y: 1)
        .onHover { hovering = $0 }
    }
}

private func timestamp(_ seconds: Int64) -> String {
    guard seconds > 0 else { return "暂无记录" }
    return Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(date: .abbreviated, time: .shortened)
}

private func shortTimestamp(_ seconds: Int64) -> String {
    guard seconds > 0 else { return "" }
    return Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(.dateTime.month().day())
}
