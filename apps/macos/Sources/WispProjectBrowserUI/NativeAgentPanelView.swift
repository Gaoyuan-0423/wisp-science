import SwiftUI
import WispProjectBrowser

struct NativeAgentPanelView: View {
    @ObservedObject var model: NativePanelModel
    var query = ""
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.agentResultLoading { ProgressView().controlSize(.small) }
            ForEach(model.agents.filter { query.isEmpty || $0.workflow.name.localizedCaseInsensitiveContains(query) || $0.workflow.goal.localizedCaseInsensitiveContains(query) }) { snapshot in
                VStack(alignment: .leading, spacing: 10) {
                    Text(snapshot.workflow.name).font(.headline)
                    Text(snapshot.workflow.status + " · " + snapshot.workflow.mode).font(.caption).foregroundStyle(.secondary)
                    Text(snapshot.workflow.goal).font(.callout).textSelection(.enabled)
                    if !snapshot.delegation_enabled { Text("此会话未启用代理委派").font(.caption).foregroundStyle(.orange) }
                    ForEach(snapshot.dynamic.tasks) { task in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(task.instruction).textSelection(.enabled)
                                if !task.depends_on.isEmpty { Text("依赖：" + task.depends_on.joined(separator: "、")).font(.caption) }
                                Text([task.executor["kind"].string, task.executor["model_id"].string].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                if !task.tools.isEmpty { Text("工具：" + task.tools.joined(separator: "、")).font(.caption) }
                                ForEach(task.approval_reasons, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                                if let result = task.result {
                                    Text(result["summary"].string).textSelection(.enabled)
                                    if !result["error"].string.isEmpty { Text(result["error"].string).foregroundStyle(.orange) }
                                    Text("输入 \(result["input_tokens"].integer) · 输出 \(result["output_tokens"].integer) · 工具 \(result["tool_calls"].integer)").font(.caption).foregroundStyle(.secondary)
                                    Button("查看完整结果") { Task { await model.readAgentResult(workflow: snapshot.id, step: task.stored_step_id) } }.disabled(!result["full_result_available"].bool || model.agentResultLoading)
                                }
                            }.padding(.vertical, 6)
                        } label: { HStack { Text(task.id); Spacer(); Text(task.result?["status"].string ?? "等待执行").font(.caption).foregroundStyle(.secondary) } }
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(WispDesign.color("bg-elev", scheme), in: RoundedRectangle(cornerRadius: 8))
            }
            if model.agents.isEmpty && !model.loading { Text("当前会话暂无代理工作流").foregroundStyle(.secondary).padding(.vertical) }
        }
    }
}
struct NativeAgentResultView: View {
    @Environment(\.colorScheme) private var scheme
    let result: NativeAgentResult
    let close: () -> Void
    private var json: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(result.response)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("代理结果 · \(result.step_id)").font(.headline); Spacer(); Text("尝试 \(result.attempt) · \(result.status)").foregroundStyle(.secondary); Button("关闭", action: close) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(NativeAgentResultPresentation(result.response).sections.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.0).font(.headline)
                            if section.0 == "产物" || section.0 == "证据" { NativeAgentResultItems(value: section.1, evidence: section.0 == "证据") }
                            else { NativeAgentResultValue(value: section.1) }
                        }
                    }
                    DisclosureGroup("原始结果") { Text(json).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(20).frame(minWidth: 560, idealWidth: 800, minHeight: 400, idealHeight: 650).background(WispDesign.color("bg-app", scheme)).background(NativeSettingsEscape(close: close))
    }
}

struct NativeAgentResultValue: View {
    let value: SettingsValue
    var body: some View {
        switch value {
        case .string(let text): NativeShareMarkdown(text: text).textSelection(.enabled)
        case .array(let rows): VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, item in AnyView(NativeAgentResultValue(value: item)).padding(.leading, 8) }
        }
        case .object(let fields): VStack(alignment: .leading, spacing: 8) {
            ForEach(fields.keys.sorted(), id: \.self) { key in
                VStack(alignment: .leading, spacing: 4) { Text(key.replacingOccurrences(of: "_", with: " ")).font(.caption).foregroundStyle(.secondary); AnyView(NativeAgentResultValue(value: fields[key]!)) }
            }
        }
        case .bool(let flag): Text(flag ? "是" : "否")
        case .null: Text("—").foregroundStyle(.secondary)
        default: Text(value.string).textSelection(.enabled)
        }
    }
}

struct NativeAgentResultItems: View {
    let value: SettingsValue
    let evidence: Bool
    @Environment(\.colorScheme) private var scheme
    private var rows: [SettingsValue] { if case .array(let rows) = value { return rows }; return [value] }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, item in
                if case .object(let fields) = item {
                    let path = item[evidence ? "reference" : "path"].string
                    let content = evidence ? (fields["summary"] ?? fields["evidence"] ?? .null) : (fields["content"] ?? fields["summary"] ?? .null)
                    let excluded = Set(evidence ? ["kind", "reference", "summary", "evidence"] : ["name", "kind", "path", "id", "content", "summary"])
                    let details = fields.filter { !excluded.contains($0.key) }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            if !evidence { Text(item["name"].string.isEmpty ? (path.isEmpty ? "产物" : path) : item["name"].string).font(.headline) }
                            if !item["kind"].string.isEmpty { Text(item["kind"].string).font(.caption).foregroundStyle(.secondary) }
                        }
                        if content != .null { NativeAgentResultValue(value: content) }
                        if !path.isEmpty { Text(path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary) }
                        if !details.isEmpty { NativeAgentResultValue(value: .object(details)) }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(WispDesign.color("bg-elev", scheme), in: RoundedRectangle(cornerRadius: 8))
                } else { NativeAgentResultValue(value: item) }
            }
        }
    }
}
