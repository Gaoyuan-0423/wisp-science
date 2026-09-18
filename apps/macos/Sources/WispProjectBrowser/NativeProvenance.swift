import Foundation

/// Projection of the displayed transcript, matching WebView's tool-only provenance list.
/// The index is scoped to one transcript page; hosts reset row UI state on page changes.
public struct NativeProvenanceRow: Equatable, Identifiable, Sendable {
    public let index: Int
    public let name: String
    public let input: String
    public let output: String
    public let ok: Bool?
    public var id: String { "\(index):\(name)" }
    public var initiallyExpanded: Bool { ok != true }
    public static func collect(_ items: [ConversationItem]) -> [Self] {
        items.enumerated().compactMap { index, item in
            guard item.role == "tool" else { return nil }
            return Self(index: index, name: item.tool_name ?? "", input: item.input ?? "", output: item.text, ok: item.ok)
        }
    }
    public func matches(_ query: String) -> Bool {
        query.isEmpty || [name, input, output].contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
