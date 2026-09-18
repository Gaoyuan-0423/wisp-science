import SwiftUI
import WispProjectBrowser

struct NativePanelView: View {
    @StateObject private var model: NativePanelModel
    @AppStorage("native.workspace.panel.tab") private var tab = "artifacts"
    @AppStorage("native.workspace.panel.tabs") private var savedTabs = ""
    @State private var draggedTab: String?
    @Environment(\.colorScheme) private var scheme
    @State private var query = ""
    @State private var activity: NativeContextActivitySelection?
    private var availableTabs: [String] { NativePanelTabs.defaults + ["notebook", "highlights", "provenance"] + (sideChat == nil ? [] : ["sidechat"]) }
    let sideChat: NativeSideChatModel?
    let revealExcerpt: (String) -> Void
    let transcript: [ConversationItem]
    let transcriptPage: String
    let manageWorkflows: () -> Void
    let readOnly: Bool
    let close: () -> Void
    init(client: any NativeConversationQuerying, projectID: String, sessionID: String, sideChat: NativeSideChatModel? = nil, transcript: [ConversationItem] = [], transcriptPage: String = "latest", revealExcerpt: @escaping (String) -> Void = { _ in }, readOnly: Bool = false, manageWorkflows: @escaping () -> Void = {}, close: @escaping () -> Void) {
        _model = StateObject(wrappedValue: NativePanelModel(client: client, projectID: projectID, sessionID: sessionID)); self.sideChat = sideChat; self.revealExcerpt = revealExcerpt; self.transcript = transcript; self.transcriptPage = transcriptPage; self.manageWorkflows = manageWorkflows; self.readOnly = readOnly; self.close = close
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                tabStrip
                if !["provenance", "sidechat"].contains(tab) { Button { Task { await model.refresh(tab) } } label: { WispIcon(name: "refresh") }.buttonStyle(.plain).help("刷新") }
                Button(action: close) { WispIcon(name: "close", size: 16) }.buttonStyle(.plain).help("关闭面板").accessibilityLabel("关闭面板")
            }
            if tab != "sidechat" {
            TextField(tab == "provenance" ? "搜索工具、输入或输出" : tab == "notebook" ? "搜索代码或输出" : "筛选名称", text: $query)
            if model.loading { ProgressView().controlSize(.small) }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            }
            if tab == "files" {
                HStack {
                    Button("上级") { Task { await model.refresh("files", directory: model.parent) } }.disabled(model.path == ".")
                    Text(model.path).font(.caption).lineLimit(1).truncationMode(.head).help(model.path)
                }
            }
            if tab == "sidechat", let sideChat {
                NativeSideChatView(model: sideChat)
            } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if tab == "artifacts" {
                        ForEach(model.artifacts.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { artifact in
                            Button { Task { await model.readArtifact(artifact.id) } } label: {
                                row(title: artifact.name, subtitle: artifact.kind + " · " + (artifact.logical_path ?? artifact.path), icon: "doc")
                            }.buttonStyle(.plain)
                        }
                        if model.artifacts.isEmpty && !model.loading { Text("这个会话暂无产物").foregroundStyle(.secondary).padding() }
                    } else if tab == "notebook" {
                        NativeNotebookView(model: model, cells: NativeNotebookCell.collect(transcript), query: query).id(transcriptPage)
                    } else if tab == "highlights" {
                        NativeHighlightsView(model: model, query: query, reveal: revealExcerpt)
                    } else if tab == "provenance" {
                        NativeProvenanceView(rows: NativeProvenanceRow.collect(transcript), query: query).id(transcriptPage)
                    } else if tab == "agents" {
                        NativeAgentPanelView(model: model, query: query, readOnly: readOnly, manageWorkflows: manageWorkflows)
                    } else if tab == "hosts" {
                        NativePanelContextsView(model: model, query: query) { context, runtimes in activity = .init(context: context, runtimes: runtimes) }
                    } else {
                        ForEach(model.files.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { file in
                            Button {
                                let path = model.child(file)
                                Task { if file.is_dir { await model.refresh("files", directory: path) } else { await model.readFile(path) } }
                            } label: { row(title: file.name, subtitle: file.is_dir ? "文件夹" : ByteCountFormatter.string(fromByteCount: Int64(clamping: file.size), countStyle: .file), icon: file.is_dir ? "folder" : "doc") }.buttonStyle(.plain)
                        }
                        if model.files.isEmpty && !model.loading { Text("目录为空").foregroundStyle(.secondary).padding() }
                    }
                }
            }
            }
        }.padding(12).frame(maxHeight: .infinity).background(WispDesign.color("bg-sunken", scheme))
            .onAppear { var value = layout; value.reopen(); store(value) }
            .task(id: tab) {
                if !availableTabs.contains(tab) { tab = "artifacts" }
                await model.refresh(tab)
                while tab == "agents" && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if !Task.isCancelled { await model.refresh("agents", quiet: true) }
                }
            }
            .sheet(isPresented: Binding(get: { model.preview != nil }, set: { if !$0 { model.dismissPreview() } })) {
                if let content = model.preview { NativePanelFilePreview(content: content, close: model.dismissPreview) }
            }
            .sheet(item: $model.agentResult, onDismiss: model.dismissPreview) { result in
                NativeAgentResultView(result: result, close: model.dismissPreview)
            }
            .sheet(item: $activity) { selection in
                NativeContextActivityView(client: model.client, projectID: model.projectID, sessionID: model.sessionID, selection: selection) { activity = nil }
            }
            .onDisappear { model.close() }
    }
    private var layout: NativePanelTabs { NativePanelTabs(saved: savedTabs, selected: tab, available: availableTabs) }
    private func store(_ value: NativePanelTabs) { savedTabs = value.saved; tab = value.selected }
    private func title(_ id: String) -> String {
        if id == "notebook" { return "笔记本 (\(NativeNotebookCell.collect(transcript).count))" }
        if id == "highlights" { return "划线 (\(model.highlights.count))" }
        if id == "provenance" { return "溯源 (\(NativeProvenanceRow.collect(transcript).count))" }
        return ["artifacts": "产物", "agents": "代理", "files": "文件", "hosts": "执行环境", "sidechat": "侧聊"][id] ?? id
    }
    private func removeTab(_ id: String) {
        var value = layout; value.remove(id); store(value)
        if value.open.isEmpty { close() }
    }
    private func moveTab(_ id: String, to target: String) {
        var value = layout; value.move(id, to: target); store(value)
    }
    private var tabStrip: some View {
        HStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(layout.open, id: \.self) { id in
                            HStack(spacing: 4) {
                                Button(title(id)) { var value = layout; value.show(id); store(value) }
                                    .font(.system(size: 12, weight: tab == id ? .semibold : .regular))
                                    .accessibilityAddTraits(tab == id ? .isSelected : [])
                                Button { removeTab(id) } label: { WispIcon(name: "close", size: 12) }
                                    .help("关闭" + title(id)).accessibilityLabel("关闭" + title(id))
                            }.buttonStyle(.plain).padding(.horizontal, 8).padding(.vertical, 7)
                                .background(tab == id ? WispDesign.color("bg-elev", scheme) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .id(id)
                                .onDrag { draggedTab = id; return NSItemProvider(item: id as NSString, typeIdentifier: "science.wisp.native-panel-tab") }
                                .onDrop(of: ["science.wisp.native-panel-tab"], isTargeted: nil) { _ in
                                    guard let source = draggedTab else { return false }
                                    draggedTab = nil; moveTab(source, to: id); return true
                                }
                                .contextMenu {
                                    if let index = layout.open.firstIndex(of: id) {
                                        Button("向左移动") { moveTab(id, to: layout.open[index - 1]) }.disabled(index == 0)
                                        Button("向右移动") { moveTab(id, to: layout.open[index + 1]) }.disabled(index == layout.open.count - 1)
                                    }
                                    Button("关闭标签") { removeTab(id) }
                                }
                        }
                    }
                }.onChange(of: tab) { id in proxy.scrollTo(id) }
                    .onAppear { proxy.scrollTo(tab) }
            }
            Menu {
                ForEach(availableTabs, id: \.self) { id in
                    Button { var value = layout; value.show(id); store(value) } label: {
                        if layout.open.contains(id) { Label(title(id), systemImage: "checkmark") } else { Text(title(id)) }
                    }
                }
            } label: { WispIcon(name: "plus", size: 14) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("添加面板").accessibilityLabel("添加面板")
        }
    }
    private func row(title: String, subtitle: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            WispIcon(name: icon, size: 16)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(WispDesign.font(size: 13, weight: .semibold)).lineLimit(2)
                Text(subtitle).font(WispDesign.font(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(WispDesign.color("bg-elev", scheme), in: RoundedRectangle(cornerRadius: 8))
    }
}
struct NativePanelFilePreview: View {
    let content: NativePanelFileContent
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text((content.path as NSString).lastPathComponent).font(.headline); Spacer(); Button("关闭预览", action: close) }
            if content.truncated { Text("仅展示文件开头；完整文件大小 \(content.total_bytes ?? 0) bytes。").font(.caption).foregroundStyle(.orange) }
            if let text = content.text {
                ScrollView([.vertical, .horizontal]) { Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading) }
            } else { NativeQuickLookPreview(url: URL(fileURLWithPath: content.path)) }
        }.padding(16).frame(minWidth: 560, idealWidth: 850, minHeight: 420, idealHeight: 650)
            .background(NativeSettingsEscape(close: close))
    }
}

struct NativePanelContextsView: View {
    @ObservedObject var model: NativePanelModel
    var query = ""
    var showActivity: (String, Bool) -> Void = { _, _ in }
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder var body: some View {
        if let snapshot = model.contexts {
            ForEach(snapshot.attached.filter { query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }) { context in
                VStack(alignment: .leading, spacing: 8) {
                    Text(context.label.isEmpty ? context.id : context.label).font(.headline)
                    Text(context.kind + " · " + (context.last_probe_status ?? "尚未探测")).font(.caption).foregroundStyle(.secondary)
                    if let error = context.last_probe_error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                    HStack {
                        Button("探测") { Task { await model.probeContext(context.id) } }
                        if context.kind != "local" { Button("从会话移除") { Task { await model.setContext(context.id, enabled: false) } }.disabled(snapshot.read_only) }
                    }.disabled(model.contextBusy)
                    HStack {
                        Button("运行时") { showActivity(context.id, true) }
                        Button("任务列表") { showActivity(context.id, false) }
                    }
                    DisclosureGroup("机器信息") {
                        NativeSettingsSummary(value: SettingsValue.string(context.capabilities_json).decodedJSON)
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(WispDesign.color("bg-elev", scheme), in: RoundedRectangle(cornerRadius: 8))
            }
            if !snapshot.available.isEmpty {
                Menu("关联执行环境") {
                    ForEach(snapshot.available) { context in
                        Button(context.label.isEmpty ? context.id : context.label) { Task { await model.setContext(context.id, enabled: true) } }
                    }
                }.disabled(snapshot.read_only || model.contextBusy)
            }
            if snapshot.read_only { Text("归档或只读会话不能修改关联环境").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
