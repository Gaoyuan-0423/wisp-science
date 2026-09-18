import SwiftUI
import WispProjectBrowser

struct NativePanelView: View {
    @StateObject private var model: NativePanelModel
    @AppStorage("native.workspace.panel.tab") private var tab = "artifacts"
    @Environment(\.colorScheme) private var scheme
    @State private var query = ""
    let close: () -> Void
    init(client: any NativeConversationQuerying, projectID: String, sessionID: String, close: @escaping () -> Void) {
        _model = StateObject(wrappedValue: NativePanelModel(client: client, projectID: projectID, sessionID: sessionID)); self.close = close
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("面板", selection: $tab) { Text("产物").tag("artifacts"); Text("文件").tag("files") }.labelsHidden()
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
            .task(id: tab) { if !["artifacts", "files"].contains(tab) { tab = "artifacts" }; await model.refresh(tab) }
            .sheet(isPresented: Binding(get: { model.preview != nil }, set: { if !$0 { model.dismissPreview() } })) {
                if let content = model.preview { NativePanelFilePreview(content: content, close: model.dismissPreview) }
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
