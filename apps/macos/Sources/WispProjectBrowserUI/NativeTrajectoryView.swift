import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WispProjectBrowser

struct NativeTrajectoryView: View {
    @StateObject private var model: NativeTrajectoryModel
    let close: () -> Void
    @State private var query = ""
    @State private var axis = "耗时"
    @State private var selected: CellSelection?
    @State private var exportError: String?
    @State private var exporting = false
    init(client: any NativeConversationQuerying, projectID: String, sessionID: String, close: @escaping () -> Void) {
        _model = StateObject(wrappedValue: NativeTrajectoryModel(client: client, projectID: projectID, sessionID: sessionID))
        self.close = close
    }
    private struct CellSelection { let turn: Int64; let offset: Int; let cell: NativeTrajectoryCell }
    private var rows: [CellSelection] {
        (model.snapshot?.turns ?? []).flatMap { turn in
            turn.cells.enumerated().compactMap { offset, cell in
                cell.matches(query) ? CellSelection(turn: turn.index, offset: offset, cell: cell) : nil
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("运行轨迹").font(.title2.bold())
                Text(model.snapshot?.model ?? "").foregroundStyle(.secondary)
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Button("刷新") { Task { await model.refresh() } }.disabled(model.loading)
                Button(exporting ? "正在导出…" : "导出 HTML") { Task { await export() } }.disabled(exporting || model.snapshot == nil)
                Button("关闭", action: close)
            }
            HStack {
                Picker("时间轴", selection: $axis) { ForEach(["耗时", "轮次", "调用"], id: \.self) { Text($0) } }.pickerStyle(.segmented).frame(width: 240)
                TextField("搜索步骤、输入或输出", text: $query)
            }
            if let error = exportError ?? model.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if let snapshot = model.snapshot {
                HStack {
                    Text("\(snapshot.stats.turns) 轮 · \(snapshot.stats.steps) 步")
                    Text("模型 \(snapshot.stats.llm_ms) ms · 工具 \(snapshot.stats.tool_ms) ms")
                    Text("输入 \(snapshot.stats.input_tokens) · 输出 \(snapshot.stats.output_tokens) · 缓存 \(snapshot.stats.cached_input_tokens)")
                }.font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            Button { selected = row } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text("第 \(row.turn) 轮 · \(row.cell.kind)").font(.caption).foregroundStyle(.secondary)
                                        Spacer()
                                        if let duration = row.cell.duration_ms { Text("\(duration) ms").font(.caption) }
                                        if row.cell.is_error { Text("失败").foregroundStyle(.orange) }
                                    }
                                    Text(row.cell.summary).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                                    GeometryReader { geometry in
                                        Capsule().fill(row.cell.is_error ? Color.orange : Color.accentColor.opacity(0.55))
                                            .frame(width: max(3, geometry.size.width * fraction(row)))
                                    }.frame(height: 5)
                                }.padding(10).background(Color.primary.opacity(selected?.turn == row.turn && selected?.offset == row.offset ? 0.1 : 0.035), in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                        if rows.isEmpty { Text(model.loading ? "正在读取轨迹…" : "没有匹配的轨迹记录").foregroundStyle(.secondary).padding(30) }
                    }
                }
                if let selected {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text("步骤详情").font(.headline); Spacer(); Button("关闭详情") { self.selected = nil } }
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(selected.cell.summary).font(.headline)
                                if let timestamp = selected.cell.ts { Text(Date(timeIntervalSince1970: Double(timestamp) / 1000), style: .time) }
                                if let input = selected.cell.detail_input { Text("输入").font(.headline); Text(input).font(.system(.caption, design: .monospaced)) }
                                if let output = selected.cell.detail_output { Text("输出").font(.headline); Text(output).font(.system(.caption, design: .monospaced)) }
                                if let usage = selected.cell.usage {
                                    Text("模型：\(usage.model ?? "—")\n输入：\(usage.input_tokens)\n输出：\(usage.output_tokens)\n推理：\(usage.reasoning_tokens)\n缓存：\(usage.cached_input_tokens)")
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }
                    }.frame(width: 300)
                }
            }
        }.padding(20).frame(minWidth: 640, idealWidth: 980, minHeight: 420, idealHeight: 650)
            .background(NativeSettingsEscape { if selected != nil { selected = nil } else { close() } })
            .task {
                while !Task.isCancelled {
                    await model.refresh()
                    do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                }
            }
            .onDisappear { model.close() }
    }
    private func fraction(_ row: CellSelection) -> Double {
        if axis == "耗时" {
            let maximum = rows.compactMap { $0.cell.duration_ms }.max() ?? 0
            return maximum > 0 ? Double(row.cell.duration_ms ?? 0) / Double(maximum) : 0
        }
        if axis == "轮次" { return Double(row.turn) / Double(max(1, rows.map(\.turn).max() ?? 1)) }
        return Double(row.offset + 1) / Double(max(1, (model.snapshot?.turns.first { $0.index == row.turn }?.cells.count ?? 1)))
    }
    private func export() async {
        exporting = true; exportError = nil
        defer { exporting = false }
        do {
            let html = try await model.exportHTML()
            let panel = NSSavePanel(); panel.allowedContentTypes = [.html]; panel.nameFieldStringValue = "trajectory.html"
            let response = await panel.begin()
            guard response == .OK, let url = panel.url else { return }
            try html.write(to: url, atomically: true, encoding: .utf8)
        } catch { exportError = error.localizedDescription }
    }
}
