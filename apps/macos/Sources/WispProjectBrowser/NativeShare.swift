import Foundation

public struct NativeShareRow: Codable, Equatable, Sendable {
    public var role: String
    public var text: String
}
public struct NativeShareDraftRow: Identifiable, Equatable {
    public let id: Int
    public var row: NativeShareRow
    public var selected: Bool
}
public enum NativeShare {
    public static func draft(_ rows: [NativeShareRow]) -> [NativeShareDraftRow] {
        rows.enumerated().compactMap { index, row in
            guard ["user", "assistant", "reasoning"].contains(row.role), !row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return NativeShareDraftRow(id: index, row: row, selected: row.role != "reasoning")
        }
    }
    public static func keywords(_ raw: String) -> [String] {
        Array(Set(raw.components(separatedBy: CharacterSet(charactersIn: ",，\n")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
            .sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
    }
    public static func redact(_ text: String, keywords: [String]) -> String {
        keywords.reduce(text) { result, word in result.replacingOccurrences(of: word, with: "xxx", options: .caseInsensitive) }
    }
    public static func width(_ raw: String) -> Int { min(2400, max(320, UInt(raw.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap(Int.init(exactly:)) ?? 840)) }
    public static func selected(_ draft: [NativeShareDraftRow], keywords: String) -> [NativeShareRow] {
        let words = self.keywords(keywords)
        return draft.filter(\.selected).map { NativeShareRow(role: $0.row.role, text: redact($0.row.text, keywords: words)) }
    }
}
