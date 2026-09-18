import SwiftUI
import WispProjectBrowser

struct NativePanelView: View {
    @StateObject private var model: NativePanelModel
    @AppStorage("native.workspace.panel.tab") private var tab = "artifacts"
    @Environment(\.colorScheme) private var scheme
    @State private var query = ""
    @State private var activity: NativeContextActivitySelection?
    let close: () -> Void
    init(client: any NativeConversationQuerying, projectID: String, sessionID: String, close: @escaping () -> Void) {
        _model = StateObject(wrappedValue: NativePanelModel(client: client, projectID: projectID, sessionID: sessionID)); self.close = close
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("面板", selection: $tab) { Text("产物").tag("artifacts"); Text("文件").tag("files"); Text("执行环境").tag("hosts") }.labelsHidden()
                Button { Task { await model.refresh(tab) } } label: { WispIcon(name: "refresh") }.buttonStyle(.plain).help("刷新")
                Button("关闭", action: close)
            }
            TextField("筛选名称", text: $query)
            if model.loading { ProgressView().controlSize(.small) }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if tab == "files" {
                HStack {
                    Button("上级") { Task { await model.refresh("files", directory: model.parent) } }.disabled(model.path == ".")
                    Text(model.path).font(.caption).lineLimit(1).truncationMode(.head).help(model.path)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if tab == "artifacts" {
                        ForEach(model.artifacts.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { artifact in
                            Button { Task { await model.readArtifact(artifact.id) } } label: {
                                row(title: artifact.name, subtitle: artifact.kind + " · " + (artifact.logical_path ?? artifact.path), icon: "doc")
                            }.buttonStyle(.plain)
                        }
                        if model.artifacts.isEmpty && !model.loading { Text("这个会话暂无产物").foregroundStyle(.secondary).padding() }
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
        }.padding(12).frame(maxHeight: .infinity).background(WispDesign.color("bg-sunken", scheme))
            .task(id: tab) { if !["artifacts", "files", "hosts"].contains(tab) { tab = "artifacts" }; await model.refresh(tab) }
            .sheet(isPresented: Binding(get: { model.preview != nil }, set: { if !$0 { model.dismissPreview() } })) {
                if let content = model.preview { NativePanelFilePreview(content: content, close: model.dismissPreview) }
            }
            .sheet(item: $activity) { selection in
                NativeContextActivityView(client: model.client, projectID: model.projectID, sessionID: model.sessionID, selection: selection) { activity = nil }
            }
            .onDisappear { model.close() }
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
