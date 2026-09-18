import Foundation

/// Runtime fields retain the backend's camelCase wire format.
public struct NativeRuntimeKey: Codable, Sendable {
    public let projectId: String
    public let contextId: String
    public let language: String
    public let scopeKey: String
    public let sessionId: String
}
public struct NativeRuntimeInfo: Codable, Identifiable, Sendable {
    public var id: String { runtimeId }
    public let runtimeId: String
    public let generation: UInt64
    public let key: NativeRuntimeKey
    public let status: String
    public let interpreter: String?
    public let version: String?
    public let processId: UInt32?
    public let startedAtMs: UInt64
    public let lastActivityAtMs: UInt64
    public let residentMemoryBytes: UInt64?
    public let lastError: String?
}
public struct NativeRuntimeObject: Codable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let typeName: String
    public let summary: String
    public let sizeBytes: UInt64?
}
public struct NativeRuntimeObjects: Codable, Sendable {
    public let objects: [NativeRuntimeObject]
    public let totalCount: Int
}
/// Shared RunSummary/RunRecord fields. Large detail fields are absent in lists.
public struct NativeRun: Codable, Identifiable, Sendable {
    public let id: String
    public let frame_id: String?
    public let context_id: String
    public let title: String
    public let kind: String
    public let status: String
    public let created_at: Int64
    public let started_at: Int64?
    public let ended_at: Int64?
    public let exit_code: Int64?
    public let remote_workdir: String?
    public let timeout_secs: Int64?
    public let last_polled_at: Int64?
    public let last_poll_error: String?
    public let progress_json: String
    public let harvested_at: Int64?
    public let cleaned_at: Int64?
    public let cleanup_error: String?
    public let output_fingerprint: String?
    public let command: String?
    public let stdout_tail: String?
    public let stderr_tail: String?
    public let env_snapshot_json: String?
    public var cancellable: Bool { ["submitted", "running", "cancelling"].contains(status) }
    public var harvestable: Bool { status == "succeeded" && harvested_at == nil }
}
public struct NativeContextActivity: Codable, Sendable {
    public let runtimes: [NativeRuntimeInfo]
    public let runs: [NativeRun]
    public let read_only: Bool
}

public struct NativeRuntimeExecution: Codable, Sendable {
    public let text: String
    public let plots: [String]
}
public enum NativeRuntimeAction: String, Sendable {
    case stop, restart, dismiss
}
