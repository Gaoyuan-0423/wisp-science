import Foundation

/// Existing shared LibraryItem; the host returns text entries for the requested conversation only.
public struct NativeHighlight: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let title: String
    public let code: String
    public let source_project_id: String
    public let source_session_id: String
    public let created_at: Int64
    public func belongs(project: String, session: String) -> Bool {
        kind == "text" && source_project_id == project && source_session_id == session
    }
}

public enum NativeSavedExcerpt {
    /// Character offsets in rendered text; whitespace is ignored like WebView saved marks.
    public static func range(in text: String, excerpt: String) -> Range<Int>? {
        let needle = Array(excerpt).filter { !$0.isWhitespace }
        guard !needle.isEmpty else { return nil }
        let indexed = Array(text).enumerated().filter { !$0.element.isWhitespace }
        guard indexed.count >= needle.count else { return nil }
        for start in 0...(indexed.count - needle.count) {
            if zip(indexed[start..<(start + needle.count)], needle).allSatisfy({ $0.0.element == $0.1 }) {
                return indexed[start].offset..<(indexed[start + needle.count - 1].offset + 1)
            }
        }
        return nil
    }
}
