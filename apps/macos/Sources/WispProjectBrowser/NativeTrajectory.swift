import Foundation

/// Mirrors the existing wisp-dto TrajectorySnapshotDto, shared with WebView.
public struct NativeTrajectory: Codable, Sendable {
    public let frame_id: String
    public let model: String?
    public let turns: [NativeTrajectoryTurn]
    public let stats: NativeTrajectoryStats
    public static func decode(_ value: SettingsValue, sessionID: String) throws -> Self {
        let result = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
        guard result.frame_id == sessionID else { throw ProjectBrowserError.invalidResponse }
        return result
    }
}
public struct NativeTrajectoryTurn: Codable, Identifiable, Sendable {
    public var id: Int64 { index }
    public let index: Int64
    public let started_at: Int64?
    public let cells: [NativeTrajectoryCell]
}
public struct NativeTrajectoryCell: Codable, Sendable {
    public let kind: String
    public let summary: String
    public let detail_input: String?
    public let detail_output: String?
    public let ok: Bool?
    public let is_error: Bool
    public let ts: Int64?
    public let duration_ms: Int64?
    public let usage: NativeTrajectoryUsage?
    public func matches(_ query: String) -> Bool {
        query.isEmpty || [summary, detail_input ?? "", detail_output ?? ""].contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
public struct NativeTrajectoryUsage: Codable, Sendable {
    public let round: Int64
    public let model: String?
    public let input_tokens: Int64
    public let output_tokens: Int64
    public let reasoning_tokens: Int64
    public let cached_input_tokens: Int64
}
public struct NativeTrajectoryStats: Codable, Sendable {
    public let turns: Int64
    public let steps: Int64
    public let llm_ms: Int64
    public let tool_ms: Int64
    public let input_tokens: Int64
    public let output_tokens: Int64
    public let cached_input_tokens: Int64
    public let cache_hit_pct: Double?
    public let tokens_per_sec: Double?
}
