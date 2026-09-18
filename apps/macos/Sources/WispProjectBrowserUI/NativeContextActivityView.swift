import SwiftUI
import WispProjectBrowser

struct NativeContextActivitySelection: Identifiable {
    let context: String
    let runtimes: Bool
    var id: String { context + (runtimes ? ":runtimes" : ":runs") }
}
struct NativeContextActivityView: View {
    @StateObject private var model: NativeContextActivityModel
    let runtimes: Bool
    let close: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var runtimeConfirmation: NativeRuntimeInfo?
    @State private var runtimeAction = NativeRuntimeAction.stop
    @State private var console = false
    @State private var code = ""
    @State private var language = "python"
    @State private var cancelID: String?
    init(client: any NativeConversationQuerying, projectID: String, sessionID: String, selection: NativeContextActivitySelection, close: @escaping () -> Void) {
        _model = StateObject(wrappedValue: NativeContextActivityModel(client: client, projectID: projectID, sessionID: sessionID, contextID: selection.context))
        runtimes = selection.runtimes; self.close = close
    }
    init(model: NativeContextActivityModel, runtimes: Bool, consoleVisible: Bool = false, close: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model); self.runtimes = runtimes; _console = State(initialValue: consoleVisible); self.close = close
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(runtimes ? "运行时" : "任务列表").font(.title2.bold())
                Text(model.contextID).foregroundStyle(.secondary)
                Spacer()
                Button("刷新") { Task { await model.refresh() } }.disabled(model.loading || model.busy)
                Button("关闭", action: close)
            }
            if model.loading { ProgressView().controlSize(.small) }
            if let error = model.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if model.busy { HStack { ProgressView().controlSize(.small); Text("正在处理…") } }
            if runtimes {
                HStack {
                    Menu("启动运行时") {
                        Button("Python") { Task { await model.startRuntime(language: "python") } }
                        Button("R") { Task { await model.startRuntime(language: "r") } }
                    }.disabled(model.startingLanguage != nil || model.snapshot?.read_only != false)
                    Button(console ? "收起控制台" : "控制台") { console.toggle() }
                    if model.startingLanguage != nil { ProgressView().controlSize(.small) }
                }
                if console { consoleView }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.selectedRun != nil || model.selectedRuntime != nil {
                        Button("返回列表", action: model.dismissDetail)
                        if let run = model.detail { runDetail(run) }
                        else if let objects = model.objects {
                            Text("变量 · \(objects.totalCount)").font(.headline)
                            ForEach(objects.objects) { object in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(object.name + " · " + object.typeName).font(.headline)
                                    Text(object.summary).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                    if let bytes = object.sizeBytes { Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)).font(.caption).foregroundStyle(.secondary) }
                                }.padding(10)
                            }
                            if objects.objects.isEmpty { Text("当前没有可展示的变量").foregroundStyle(.secondary) }
                        } else if model.error == nil { ProgressView().controlSize(.small) }
                    } else if runtimes {
                        ForEach(model.runtimes) { runtime in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { Text(runtime.key.language).font(.headline); Text(runtime.status).foregroundStyle(.secondary); Spacer(); Button("查看变量") { Task { await model.inspect(runtime.id) } }.disabled(runtime.status != "ready") }
                                Text(runtime.key.projectId + " · " + (runtime.key.sessionId.isEmpty ? "共享运行时" : runtime.key.sessionId)).font(.caption).foregroundStyle(.secondary)
                                Text([runtime.interpreter, runtime.version].compactMap { $0 }.joined(separator: " · ")).textSelection(.enabled)
                                if let bytes = runtime.residentMemoryBytes { Text("内存 " + ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)).font(.caption) }
                                HStack {
                                    if runtime.status == "dead" {
                                        Button("移除记录") { Task { await model.controlRuntime(runtime, action: .dismiss) } }
                                    } else {
                                        Button("停止…") { runtimeAction = .stop; runtimeConfirmation = runtime }
                                    }
                                    Button("重启…") { runtimeAction = .restart; runtimeConfirmation = runtime }.disabled(model.snapshot?.read_only != false)
                                }.disabled(model.runtimeOperations.contains(runtime.id))
                                if let error = runtime.lastError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(WispDesign.color("bg-elev", scheme), in: RoundedRectangle(cornerRadius: 8))
                        }
                        if model.runtimes.isEmpty && !model.loading { Text("当前没有已启动的运行时").foregroundStyle(.secondary) }
                    } else {
                        ForEach(model.runs) { run in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { Text(run.title).font(.headline); Spacer(); Text(run.status).foregroundStyle(.secondary) }
                                Text(run.kind + " · " + date(run.created_at)).font(.caption)
                                HStack {
                                    Button("查看详情") { Task { await model.readRun(run.id) } }
                                    runActions(run)
                                }
                                if let error = run.last_poll_error { Text(error).foregroundStyle(.orange).font(.caption) }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(WispDesign.color("bg-elev", scheme), in: RoundedRectangle(cornerRadius: 8))
                        }
                        if model.runs.isEmpty && !model.loading { Text("此执行环境暂无任务").foregroundStyle(.secondary) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(20).frame(minWidth: 560, idealWidth: 800, minHeight: 400, idealHeight: 650)
            .background(WispDesign.color("bg-app", scheme))
            .task {
                if model.snapshot == nil { await model.refresh() }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if !Task.isCancelled { await model.refresh() }
                }
            }
            .onDisappear { model.close() }
            .background(NativeSettingsEscape(enabled: cancelID == nil && runtimeConfirmation == nil) {
                if model.selectedRun != nil || model.selectedRuntime != nil { model.dismissDetail() } else if console { console = false } else { close() }
            })
            .confirmationDialog(runtimeAction == .restart ? "重启将清空此运行时的变量和状态。" : "停止将结束此运行时并清空变量。", isPresented: Binding(get: { runtimeConfirmation != nil }, set: { if !$0 { runtimeConfirmation = nil } })) {
                if let runtime = runtimeConfirmation {
                    Button(runtimeAction == .restart ? "重启运行时" : "停止运行时", role: .destructive) {
                        let action = runtimeAction; runtimeConfirmation = nil
                        Task { await model.controlRuntime(runtime, action: action) }
                    }
                }
                Button("取消", role: .cancel) { runtimeConfirmation = nil }
            }
            .confirmationDialog("取消此任务？", isPresented: Binding(get: { cancelID != nil }, set: { if !$0 { cancelID = nil } })) {
                if let id = cancelID { Button("取消任务", role: .destructive) { cancelID = nil; Task { await model.mutateRun(id, harvest: false) } } }
                Button("继续运行", role: .cancel) { cancelID = nil }
            }
    }
    private var consoleView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("语言", selection: $language) { Text("Python").tag("python"); Text("R").tag("r") }.frame(width: 160)
                Text("当前项目 · 当前会话").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("运行代码") { let source = code; let selectedLanguage = language; Task { await model.execute(code: source, language: selectedLanguage) } }
                    .disabled(model.executing || model.snapshot?.read_only != false || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if model.executing { ProgressView().controlSize(.small) }
            }
            TextEditor(text: $code).font(.system(size: 12, design: .monospaced)).frame(height: 110).border(WispDesign.color("border", scheme))
            if let error = model.executionError { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if let result = model.execution {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(result.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(Array(result.plots.enumerated()), id: \.offset) { _, plot in
                            if let data = Data(base64Encoded: plot), let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit() }
                        }
                    }
                }.frame(maxHeight: 180)
            }
        }
    }
    @ViewBuilder private func runActions(_ run: NativeRun) -> some View {
        if run.cancellable { Button("取消任务…") { cancelID = run.id }.disabled(model.busy || model.snapshot?.read_only != false) }
        if run.harvestable { Button("重新收集产物") { Task { await model.mutateRun(run.id, harvest: true) } }.disabled(model.busy || model.snapshot?.read_only != false) }
    }
    private func runDetail(_ run: NativeRun) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(run.title).font(.headline)
            HStack { Text(run.status); if let code = run.exit_code { Text("退出码 \(code)") }; Spacer(); runActions(run) }
            Text("创建于 " + date(run.created_at)).font(.caption)
            if let path = run.remote_workdir { Text(path).font(.caption).textSelection(.enabled) }
            if let command = run.command { output("命令", command) }
            if let stdout = run.stdout_tail { output("标准输出", stdout) }
            if let stderr = run.stderr_tail, !stderr.isEmpty { output("错误输出", stderr) }
            if let error = run.last_poll_error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if let error = run.cleanup_error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
        }
    }
    private func output(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.headline); Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
    }
    private func date(_ seconds: Int64) -> String { Date(timeIntervalSince1970: Double(seconds)).formatted(date: .abbreviated, time: .shortened) }
}
