import Foundation

public struct NativeAgentWorkflow: Codable, Identifiable, Sendable {
    public let id: String
    public let frame_id: String?
    public let root_workflow_id: String
    public let parent_attempt_id: String?
    public let depth: Int
    public let name: String
    public let goal: String
    public let mode: String
    public let status: String
    public let max_parallel: Int
    public let requires_confirmation: Bool
    public let version: Int64
    public let updated_at: Int64
}
public struct NativeAgentTask: Codable, Identifiable, Sendable {
    public let id: String
    public let stored_step_id: String
    public let instruction: String
    public let depends_on: [String]
    public let executor: SettingsValue
    public let budget: SettingsValue
    public let tools: [String]
    public let approval_reasons: [String]
    public let result: SettingsValue?
}
public struct NativeAgentPlan: Codable, Sendable {
    public let schema_version: Int
    public let approval_policy: String
    public let editable_proposal: SettingsValue
    public let tasks: [NativeAgentTask]
    public let approval_reasons: [SettingsValue]
}
public struct NativeAgentSnapshot: Codable, Identifiable, Sendable {
    public var id: String { workflow.id }
    public let workflow: NativeAgentWorkflow
    public let delegation_enabled: Bool
    public let approval_policy: String
    public let dynamic: NativeAgentPlan
}
public struct NativeAgentResult: Codable, Identifiable, Sendable {
    public var id: String { workflow_id + ":" + step_id + ":" + String(attempt) }
    public let workflow_id: String
    public let step_id: String
    public let attempt: Int64
    public let status: String
    public let response: SettingsValue
}

public struct NativeAgentResultPresentation: Sendable {
    public let sections: [(String, SettingsValue)]
    public init(_ response: SettingsValue) {
        let envelope = response.object["output"] != nil
        let output = envelope ? response["output"] : response
        func items(_ value: SettingsValue) -> [SettingsValue] { if case .array(let rows) = value { return rows }; return value == .null ? [] : [value] }
        func identity(_ value: SettingsValue) -> String? { ["name", "path", "id"].map { value[$0].string }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
        var artifacts = items(output["artifacts"])
        var identities = Set(artifacts.compactMap(identity))
        if envelope {
            for artifact in items(response["artifacts"]) {
                if let id = identity(artifact) { if identities.insert(id).inserted { artifacts.append(artifact) } }
                else { artifacts.append(artifact) }
            }
        }
        let evidence = envelope && !items(response["evidence"]).isEmpty ? response["evidence"] : output["evidence"]
        var rows: [(String, SettingsValue)] = []
        for (label, value) in [("摘要", output["summary"]), ("变更说明", output["diff_summary"]), ("文件变更", output["files_changed"]), ("产物", .array(artifacts)), ("证据", evidence), ("测试", output["tests"]), ("风险", output["risks"])] {
            if value != .null && value != .array([]) && value != .string("") { rows.append((label, value)) }
        }
        let omitted = Set(["task_id", "summary", "diff_summary", "files_changed", "artifacts", "evidence", "tests", "risks", "error"])
        if case .object(let fields) = output {
            for key in fields.keys.sorted() where !omitted.contains(key) { rows.append((key.replacingOccurrences(of: "_", with: " "), fields[key]!)) }
        } else if output != .null { rows.append(("结果", output)) }
        let error = response["error"].string.isEmpty ? output["error"] : response["error"]
        if error != .null && error != .string("") { rows.append(("错误", error)) }
        sections = rows
    }
}
