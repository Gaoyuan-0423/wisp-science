import SwiftUI
import WispProjectBrowser

struct NativeWorkflowSettings: View {
    @ObservedObject var model: NativeSettingsModel
    @State private var conversionRequest = ""
    @State private var conversionModel = ""
    @State private var sourceSkills: Set<String> = []
    @State private var legacyTemplate = ""
    @State private var conversionResult: SettingsValue?
    var body: some View {
        VStack(spacing: 22) {
        NativeSettingsGroup(title: model.section.title) {
            Button("添加\(model.section.title)") { edit(.object(["id": .string(UUID().uuidString), "name": .string(""), "builtin": .bool(false)]), new: true) }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(row["name"].string).fontWeight(.semibold)
                        if row["builtin"].bool { Text(localized("内置")).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button(localized("编辑")) { edit(row) }
                        Button(localized("复制")) { var copy = row; copy["id"] = .string(UUID().uuidString); copy["name"] = .string(row["name"].string + " 副本"); copy["builtin"] = .bool(false); edit(copy, new: true) }
                    }
                    Text(row["description"].string).foregroundStyle(.secondary).textSelection(.enabled)
                    if model.section == .quickActions {
                        Toggle(localized("启用"), isOn: Binding(get: { row["enabled"].bool }, set: { enabled in
                            var copy = row; copy["enabled"] = .bool(enabled)
                            Task { _ = await model.run("save_quick_action", ["action": copy]) }
                        }))
                    }
                }.padding(.vertical, 10)
                Divider()
            }
            if rows.isEmpty && !model.loading { Text(localized("尚无配置，可添加或复制现有配置。")).foregroundStyle(.secondary) }
        }
        if model.section == .workflows { conversion }
        }
    }
    private var conversion: some View {
        NativeSettingsGroup(title: "从技能或旧模板转换") {
            TextField(localized("描述研究目标"), text: $conversionRequest).textFieldStyle(NativeSettingsTextFieldStyle())
            Picker(localized("转换模型"), selection: $conversionModel) {
                Text(localized("选择模型")).tag("")
                ForEach(Array((model.values["list_models"]?.array ?? []).enumerated()), id: \.offset) { _, row in Text(row["label"].string.isEmpty ? row["model"].string : row["label"].string).tag(row["id"].string) }
            }
            Picker(localized("旧模板（可选）"), selection: $legacyTemplate) { Text(localized("从技能选择")).tag(""); ForEach(Array(rows.enumerated()), id: \.offset) { _, row in Text(row["name"].string).tag(row["id"].string) } }
            if legacyTemplate.isEmpty {
                ForEach(Array((model.values["list_skills"]?.array ?? []).enumerated()), id: \.offset) { _, skill in
                    Toggle(skill["name"].string, isOn: Binding(get: { sourceSkills.contains(skill["name"].string) }, set: { enabled in if enabled { sourceSkills.insert(skill["name"].string) } else { sourceSkills.remove(skill["name"].string) } }))
                }
            }
            Button(localized("生成可审核草稿")) { Task {
                var request: [String: SettingsValue] = ["request": .string(conversionRequest), "model_id": .string(conversionModel)]
                if !legacyTemplate.isEmpty { request["legacy_template_id"] = .string(legacyTemplate) }
                else { request["source_skill_ids"] = .array(sourceSkills.sorted().map(SettingsValue.string)) }
                conversionResult = await model.run("plan_skill_portfolio", ["request": .object(request), "conversionId": .string(UUID().uuidString), "expectedProjectId": model.projectID.map(SettingsValue.string) ?? .null], refresh: false, success: "转换完成，请审核后保存")
            } }.disabled(conversionRequest.isEmpty || conversionModel.isEmpty || model.projectID == nil)
            if let result = conversionResult {
                Text(result["plan"]["rationale"].string).textSelection(.enabled)
                Button(localized("审核并保存模板")) { edit(.object(["id": .string(UUID().uuidString), "name": .string("新工作流"), "description": .string(conversionRequest), "builtin": .bool(false), "proposal": result["proposal"]]), new: true, sourceHash: result["plan"]["source_sha256"]) }
            }
        }
    }
    private var read: String {
        switch model.section { case .quickActions: return "list_quick_actions"; case .workflows: return "list_workflow_templates"; default: return "list_specialists" }
    }
    private var rows: [SettingsValue] { model.values[read]?.array ?? [] }
    private func edit(_ row: SettingsValue, new: Bool = false, sourceHash: SettingsValue = .null) {
        var draft = row
        var fields: [SettingsField] = [.init(key: "name", label: "名称"), .init(key: "description", label: "说明", kind: .multiline)]
        let command: String, parameter: String, remove: String, idKey: String
        switch model.section {
        case .quickActions:
            command = "save_quick_action"; parameter = "action"; remove = "remove_quick_action"; idKey = "actionId"
            if new { draft["context"] = .string("selection"); draft["enabled"] = .bool(true); draft["sort_order"] = .integer(Int64(rows.count)); draft["icon"] = .string("bolt") }
            fields += [.init(key: "workflow_template_id", label: "工作流模板", kind: .choice((model.values["list_workflow_templates"]?.array ?? []).map { ($0["id"].string, $0["name"].string) })), .init(key: "enabled", label: "启用", kind: .toggle), .init(key: "sort_order", label: "排序", kind: .integer)]
        case .workflows:
            command = "save_workflow_template"; parameter = "template"; remove = "remove_workflow_template"; idKey = "templateId"
            if new && draft["proposal"] == .null { draft["proposal"] = .object(["goal": .string(""), "context": .string(""), "approval_policy": .string("review_all"), "tasks": .array([])]) }
            fields += [.init(key: "proposal", label: "工作流定义", kind: .object([
                .init(key: "goal", label: "目标", kind: .multiline), .init(key: "context", label: "上下文", kind: .multiline),
                .init(key: "approval_policy", label: "审批策略", kind: .choice([("review_all", "逐项审核"), ("auto_safe", "自动执行安全操作")])),
                .init(key: "tasks", label: "任务节点", kind: .records([
                    .init(key: "id", label: "节点 ID"), .init(key: "instruction", label: "指令", kind: .multiline),
                    .init(key: "depends_on", label: "依赖节点", kind: .lines, hint: "每行一个节点 ID。保存时会检查循环依赖。"),
                    .init(key: "capabilities", label: "工具能力", kind: .lines), .init(key: "output_schema", label: "输出 JSON Schema", kind: .json),
                    .init(key: "specialist_id", label: "专家 ID"), .init(key: "model_id", label: "模型 ID"),
                    .init(key: "task_kind", label: "任务类型", kind: .choice([("agent", "智能体"), ("run_activity", "计算活动")])),
                    .init(key: "run_activity", label: "计算活动配置", kind: .json),
                    .init(key: "isolated", label: "独立上下文", kind: .toggle), .init(key: "timeout_secs", label: "超时秒数", kind: .integer),
                    .init(key: "executor", label: "执行器", kind: .object([.init(key: "kind", label: "类型", kind: .choice([("native", "原生智能体"), ("acp", "ACP")])), .init(key: "profile_id", label: "配置 ID")])),
                    .init(key: "budget", label: "预算", kind: .object([.init(key: "max_tokens", label: "Token 上限", kind: .integer), .init(key: "max_tool_calls", label: "工具调用上限", kind: .integer), .init(key: "max_cost_microunits", label: "费用上限（微单位）", kind: .integer)]))
                ]))
            ]))]
        default:
            command = "save_specialist_cmd"; parameter = "spec"; remove = "remove_specialist"; idKey = "id"
            fields += [.init(key: "instructions", label: "系统提示词", kind: .multiline),
                       .init(key: "model_id", label: "模型", kind: .choice([("", "跟随默认模型")] + (model.values["list_models"]?.array ?? []).map { ($0["id"].string, $0["label"].string.isEmpty ? $0["model"].string : $0["label"].string) })),
                       .init(key: "skills", label: "技能白名单", kind: .lines, hint: "未修改时继承项目设置；每行一个技能名称。"),
                       .init(key: "connectors", label: "连接器白名单", kind: .lines)]
        }
        if model.section == .specialists && row["id"].string == "reviewer" {
            fields.append(.init(key: "review_backend", label: "审核后端", kind: .object([
                .init(key: "kind", label: "类型", kind: .choice([("follow_session", "跟随会话"), ("http_model", "HTTP 模型"), ("acp_agent", "ACP 智能体")])), .init(key: "profile_id", label: "模型 / ACP 配置 ID")
            ])))
        }
        model.editor = SettingsEditor(title: model.section.title, draft: draft, fields: fields, command: command, parameter: parameter, extra: sourceHash == .null ? [:] : ["conversionSourceSha256": sourceHash], readOnly: model.section == .workflows && row["builtin"].bool, destructiveCommand: new || row["builtin"].bool ? nil : remove, destructiveArgs: [idKey: row["id"]])
    }
}
