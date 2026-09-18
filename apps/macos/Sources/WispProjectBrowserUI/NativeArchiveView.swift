import AppKit
import QuickLookUI
import SwiftUI
import WispProjectBrowser

struct NativeArchiveView: View {
    @Environment(\.colorScheme) private var scheme
    @StateObject private var model: NativeArchiveModel
    let workspace: String
    let close: () -> Void
    let continued: (String) -> Void
    @State private var fileError: String?
    @State private var preview: URL?
    init(client: any NativeConversationQuerying, projectID: String, sessionID: String, workspace: String, close: @escaping () -> Void, continued: @escaping (String) -> Void) {
        _model = StateObject(wrappedValue: NativeArchiveModel(client: client, projectID: projectID, sessionID: sessionID))
        self.workspace = workspace; self.close = close; self.continued = continued
    }
    init(model: NativeArchiveModel, workspace: String, close: @escaping () -> Void, continued: @escaping (String) -> Void) {
        _model = StateObject(wrappedValue: model)
        self.workspace = workspace; self.close = close; self.continued = continued
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(model.frozen ? "已归档研究节点" : "确认研究归档").font(.title2.bold())
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("关闭", action: close).disabled(model.busy)
            }
            if let error = fileError ?? model.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if model.busy { Text("正在整理或保存研究材料…").foregroundStyle(.secondary) }
            if let archive = Binding($model.archive) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("节点标题").font(.headline)
                        TextField("节点标题", text: archive.title).disabled(model.frozen || model.busy)
                        Text("研究问题、结论、局限与选择依据").font(.headline)
                        TextEditor(text: archive.report).frame(minHeight: 180).disabled(model.frozen || model.busy)
                        Text("整理后的操作代码").font(.headline)
                        ForEach(archive.scripts.wrappedValue.indices, id: \.self) { index in
                            DisclosureGroup(archive.scripts.wrappedValue[index].filename) {
                                TextField("脚本文件名", text: archive.scripts[index].filename)
                                TextEditor(text: archive.scripts[index].content).font(.system(.caption, design: .monospaced)).frame(minHeight: 130)
                            }.disabled(model.frozen || model.busy)
                        }
                        Text("本地材料").font(.headline)
                        Text("保存副本会固定当前文件内容；原位引用保留现有路径。远程文件不在清理范围内。").font(.caption).foregroundStyle(.secondary)
                        ForEach(archive.files.wrappedValue.indices, id: \.self) { index in
                            NativeArchiveFileRow(file: archive.files[index], disabled: model.frozen || model.busy, reveal: reveal)
                        }
                        Text("将永久删除：\(model.deletedBytes) bytes").foregroundStyle(model.deletedBytes > 0 ? .orange : .secondary)
                        ForEach(archive.wrappedValue.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                    }.padding(4)
                }
            } else if !model.busy {
                Button("重新读取") { Task { await model.load() } }
                Spacer()
            }
            Divider()
            if model.frozen {
                HStack {
                    Button("查看原始记录", action: close)
                    Button("重试未完成清理") { Task { await model.retryCleanup() } }
                    Spacer()
                    Button("继续研究") { Task { if let id = await model.continueResearch() { continued(id) } } }.buttonStyle(WispButtonStyle(primary: true))
                }.disabled(model.busy)
            } else {
                Toggle("我已检查归档材料。确认后会话将只读，所选文件立即永久删除，无法撤销。", isOn: $model.accepted).disabled(model.busy || model.archive == nil)
                HStack {
                    Button("重新整理") { Task { await model.prepare() } }.disabled(model.busy)
                    Spacer()
                    Button("确认归档并清理") { Task { await model.confirm() } }.buttonStyle(WispButtonStyle(primary: true)).disabled(!model.canConfirm)
                }
            }
        }.padding(20).frame(minWidth: 620, idealWidth: 850, minHeight: 520, idealHeight: 750)
            .background(WispDesign.color("bg-app", scheme))
            .foregroundStyle(WispDesign.color("text", scheme))
            .tint(WispDesign.color("clay", scheme))
            .interactiveDismissDisabled(model.busy)
            .background(NativeSettingsEscape(enabled: !model.busy && preview == nil, close: close))
            .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
                if let preview {
                    VStack {
                        HStack { Text(preview.lastPathComponent); Spacer(); Button("关闭材料预览") { self.preview = nil } }.padding()
                        NativeQuickLookPreview(url: preview)
                    }.frame(minWidth: 520, minHeight: 420)
                        .background(NativeSettingsEscape { self.preview = nil })
                }
            }
            .task { if model.archive == nil { await model.load() } }
    }
    private func reveal(_ path: String) {
        let root = URL(fileURLWithPath: workspace).resolvingSymlinksInPath().standardizedFileURL
        let file = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: file.path) else {
            fileError = "归档材料不存在或已移出项目目录。"; return
        }
        preview = file
    }
}
private struct NativeArchiveFileRow: View {
    @Binding var file: NativeArchiveFile
    let disabled: Bool
    let reveal: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(file.path).font(.headline).textSelection(.enabled)
            Text("\(file.size_bytes) bytes · \(file.reason)").font(.caption).foregroundStyle(.secondary)
            Picker("文件处理", selection: $file.action) {
                Text("保留副本").tag("snapshot")
                Text("原位保留").tag("reference")
                Text("永久删除").tag("delete").disabled(!file.can_delete)
            }.disabled(disabled)
            if !file.cleanup_status.isEmpty { Text(file.cleanup_status).font(.caption) }
            if let path = file.snapshot_path { Button("查看归档材料") { reveal(path) } }
        }.padding(10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct NativeQuickLookPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> NSView {
        guard let view = QLPreviewView(frame: .zero, style: .normal) else { return NSView() }
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        (view as? QLPreviewView)?.previewItem = url as NSURL
    }
}
