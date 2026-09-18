import Foundation

/// Existing ArtifactInfo, DirEntry and FileContent contracts from wisp-dto.
public struct NativePanelArtifact: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let kind: String
    public let path: String
    public let location: String?
    public let ts: Int64
    public let logical_path: String?
}
public struct NativePanelFile: Codable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let is_dir: Bool
    public let size: UInt64
    public let modified_unix_millis: UInt64?
}
public struct NativePanelFileContent: Codable, Sendable {
    public let path: String
    public let mime: String
    public let text: String?
    public let base64: String?
    public let truncated: Bool
    public let total_bytes: UInt64?
}
