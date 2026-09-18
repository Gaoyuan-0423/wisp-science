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
    @State private var cancelID: String?
    init(client: any NativeConversationQuerying, projectID: String, sessionID: String, selection: NativeContextActivitySelection, close: @escaping () -> Void) {
        _model = StateObject(wrappedValue: NativeContextActivityModel(client: client, projectID: projectID, sessionID: sessionID, contextID: selection.context))
        runtimes = selection.runtimes; self.close = close
    }
    init(model: NativeContextActivityModel, runtimes: Bool, close: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model); self.runtimes = runtimes; self.close = close
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
            .background(NativeSettingsEscape(enabled: cancelID == nil) {
                if model.selectedRun != nil || model.selectedRuntime != nil { model.dismissDetail() } else { close() }
            })
            .confirmationDialog("取消此任务？", isPresented: Binding(get: { cancelID != nil }, set: { if !$0 { cancelID = nil } })) {
                if let id = cancelID { Button("取消任务", role: .destructive) { cancelID = nil; Task { await model.mutateRun(id, harvest: false) } } }
                Button("继续运行", role: .cancel) { cancelID = nil }
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
