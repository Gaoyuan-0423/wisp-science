import Foundation
public struct NativeTerminalInfo: Codable, Identifiable, Sendable {
    public let id: String
    public let project_id: String
    public let context_id: String
    public let title: String
    public let kind: String
    public let display_cwd: String
    public let running: Bool
}
public struct NativeTerminalOutput: Codable, Sendable {
    public let terminal_id: String
    public let start: UInt64
    public let end: UInt64
    public let base64: String
    public let reset: Bool
    public let exit_code: UInt32?
    public func bytes(expectedID: String, cursor: UInt64?) throws -> Data {
        guard terminal_id == expectedID, end >= start,
              let bytes = Data(base64Encoded: base64), UInt64(bytes.count) == end - start,
              reset || cursor == start else { throw ProjectBrowserError.invalidResponse }
        return bytes
    }
}
