import Foundation

public struct NativeArchiveScript: Codable, Equatable, Sendable {
    public var filename: String
    public var content: String
}
public struct NativeArchiveFile: Codable, Equatable, Sendable {
    public let path: String
    public let checksum: String
    public let size_bytes: UInt64
    public var action: String
    public let can_delete: Bool
    public let reason: String
    public let snapshot_path: String?
    public let cleanup_status: String
}
/// Existing wisp-dto ResearchArchive. Secrets and file deletion remain in the host.
public struct NativeResearchArchive: Codable, Equatable, Sendable {
    public let id: String
    public let project_id: String
    public let frame_id: String
    public let source_hash: String
    public var title: String
    public var report: String
    public var scripts: [NativeArchiveScript]
    public var files: [NativeArchiveFile]
    public let created_at: Int64
    public let frozen_at: Int64?
    public let warnings: [String]
    public static func decode(_ value: SettingsValue, project: String, session: String) throws -> Self {
        let result = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
        guard result.project_id == project, result.frame_id == session, !result.id.isEmpty else { throw ProjectBrowserError.invalidResponse }
        return result
    }
    public func confirmation() throws -> SettingsValue {
        var value = try JSONDecoder().decode(SettingsValue.self, from: JSONEncoder().encode(self))
        value = .object(["id": value["id"], "title": value["title"], "report": value["report"], "scripts": value["scripts"], "files": .array(files.map { .object(["path": .string($0.path), "action": .string($0.action)]) })])
        return value
    }
}
