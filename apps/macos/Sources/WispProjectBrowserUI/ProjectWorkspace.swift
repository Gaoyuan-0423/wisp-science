import SwiftUI
import WispProjectBrowser

/// Native counterpart of the WebView's project shell: project navigation and
/// saved sessions on the left, the selected conversation in the main pane.
struct ProjectWorkspace: View {
    @ObservedObject var model: ProjectBrowserModel
    let project: ProjectSummary
    @Environment(\.colorScheme) private var scheme
    @State private var search = ""
    @State private var sidebarVisible = true
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    private func color(_ token: String) -> Color { WispDesign.color(token, scheme) }

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                sidebar.frame(width: 260)
                Rectangle().fill(color("border")).frame(width: 1)
            }
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    if !sidebarVisible {
                        Button { sidebarVisible = true } label: { WispIcon(name: "chevron-right") }
                            .buttonStyle(.plain).help("展开侧边栏").accessibilityLabel("展开侧边栏")
                    }
                    Text(model.sessions.first(where: { $0.id == model.activeSessionID })?.title ?? project.name)
                        .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Spacer()
                    WispUnavailableAction(title: "会话大纲", icon: "list", iconOnly: true)
                    WispUnavailableAction(title: "分享", icon: "share", iconOnly: true)
                    WispUnavailableAction(title: "运行轨迹", icon: "timeline", iconOnly: true)
                    WispUnavailableAction(title: "研究归档", icon: "archive", iconOnly: true)
                    WispUnavailableAction(title: "待查看", icon: "bell", iconOnly: true)
                }
                .padding(16)
                Rectangle().fill(color("border")).frame(height: 1)
                if let error = model.sessionError {
                    HStack {
                        Text(error).font(.system(size: 12)).textSelection(.enabled)
                        Button("重试") { Task { await model.openProject(project.id, sessionID: model.activeSessionID) } }
                    }.padding().foregroundStyle(.orange)
                }
                ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if model.nextBeforeSeq != nil, let id = model.activeSessionID {
                            Button("加载更早的消息") { Task { await model.openSession(id, older: true) } }
                                .buttonStyle(WispButtonStyle()).disabled(model.transcriptLoading)
                        }
                        ForEach(model.messages) { message in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(message.role == "user" ? "你" : (message.role == "tool" ? (message.toolName ?? "工具") : "Wisp Science"))
                                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(color("text-muted"))
                                Text((try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(message.text))
                                    .font(.system(size: 14)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(16)
                            .background(message.role == "user" ? color("bg-sunken") : .clear,
                                        in: RoundedRectangle(cornerRadius: 12))
                        }
                        if model.transcriptLoading || model.sessionsLoading {
                            ProgressView().frame(maxWidth: .infinity).padding()
                        } else if model.messages.isEmpty && model.sessionError == nil {
                            Text(model.sessions.isEmpty ? "这个项目还没有会话" : "这个会话暂无消息")
                                .foregroundStyle(color("text-faint")).padding(32)
                        }
                    }
                    .frame(maxWidth: 800).padding(24).frame(maxWidth: .infinity)
                }
                .onChange(of: model.messages.last?.id) { id in
                    if let id { scroll.scrollTo(id, anchor: .bottom) }
                }
                }
                VStack(alignment: .leading, spacing: 20) {
                    Text("向 Wisp Science 提问…").foregroundStyle(color("text-faint"))
                    HStack {
                        WispUnavailableAction(title: "添加附件", icon: "attach", iconOnly: true)
                        WispUnavailableAction(title: "选择模型")
                        Spacer()
                        WispUnavailableAction(title: "发送", primary: true)
                    }
                }
                .padding(16).background(color("bg-elev"), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(color("border")))
                .padding(.horizontal, 24).frame(maxWidth: 850)
                Text("原生预览 · 只读 · 灰色操作、发送消息与实时运行尚未接入")
                    .font(.system(size: 11)).foregroundStyle(color("text-faint"))
                    .padding(18).frame(maxWidth: .infinity)
            }
        }
        .background(color("bg-app")).foregroundStyle(color("text")).tint(color("clay"))
        .onChange(of: project.id) { _ in search = ""; searching = false }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Button { model.goHome() } label: { WispIcon(name: "arrow-left", size: 18) }
                    .buttonStyle(.plain).help("返回项目").accessibilityLabel("返回项目")
                    .accessibilityIdentifier("back-projects")
                Menu {
                    ForEach(model.projects) { item in
                        Button(item.name) { Task { await model.openProject(item.id) } }
                    }
                } label: { Text(project.name).font(.system(size: 14, weight: .semibold)).lineLimit(1) }
                .menuStyle(.borderlessButton).accessibilityLabel("切换项目")
                Button { sidebarVisible = false } label: { WispIcon(name: "chevron-left", size: 16) }
                    .buttonStyle(.plain).help("收起侧边栏").accessibilityLabel("收起侧边栏")
            }
            VStack(spacing: 4) {
                WispUnavailableAction(title: "新建会话", icon: "plus", primary: true, expanded: true)
                Button { searching.toggle(); searchFocused = searching } label: {
                    HStack { WispIcon(name: "search", size: 16); Text("搜索"); Spacer() }
                }.buttonStyle(WispButtonStyle(compact: true)).keyboardShortcut("k", modifiers: .command)
                if searching {
                    TextField("搜索会话", text: $search).textFieldStyle(.roundedBorder).focused($searchFocused)
                }
                WispUnavailableAction(title: "新建文件夹", icon: "folder-plus", expanded: true)
                WispUnavailableAction(title: "文件", icon: "doc", expanded: true)
                WispUnavailableAction(title: "研究历程", icon: "research-trail", expanded: true)
                WispUnavailableAction(title: "论文证据", icon: "book", expanded: true)
                WispUnavailableAction(title: "收藏", icon: "star", expanded: true)
            }
            Text("会话").font(.system(size: 11, weight: .semibold)).foregroundStyle(color("text-faint"))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(model.sessions.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { session in
                        Button { Task { await model.openSession(session.id) } } label: {
                            Text(session.title).font(.system(size: 13)).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .background(session.id == model.activeSessionID ? color("surface-hover") : .clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain).accessibilityIdentifier("session-\(session.id)")
                        .accessibilityAddTraits(session.id == model.activeSessionID ? [.isSelected] : [])
                    }
                }
            }
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                WispUnavailableAction(title: "能力", icon: "grid", expanded: true)
                WispUnavailableAction(title: "反馈问题", icon: "chat", expanded: true)
                WispUnavailableAction(title: "设置", icon: "gear", expanded: true)
            }
            Text(project.workspaceDirectory).font(.system(size: 10)).lineLimit(1).truncationMode(.head)
                .foregroundStyle(color("text-faint")).help(project.workspaceDirectory)
        }
        .padding(16).background(color("bg-sunken"))
    }
}
