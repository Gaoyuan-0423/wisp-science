import Foundation

/// A projection of displayed transcript code; never a second execution engine.
public struct NativeNotebookCell: Codable, Equatable, Identifiable, Sendable {
    public let index: Int
    public let language: String
    public let source: String
    public let output: String
    public let ok: Bool?
    public let origin: String
    public var id: Int { index }
    public var starKey: String { language + "\u{0}" + source }
    public var status: String { ok == true ? "ok" : ok == false ? "error" : origin == "assistant" ? "source" : "running" }
    public var outputInitiallyExpanded: Bool { ok == false }
    public static func collect(_ items: [ConversationItem]) -> [Self] {
        var cells: [Self] = []
        for item in items {
            if item.role == "assistant" {
                for (language, source) in fences(item.text) where !["csv", "tsv", "fasta", "fa"].contains(language) {
                    cells.append(Self(index: 0, language: language.isEmpty ? "text" : language, source: source, output: "", ok: nil, origin: "assistant"))
                }
            } else if item.role == "tool", let name = item.tool_name, ["python", "r", "shell"].contains(name), let input = item.input, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var source = input
                if name != "shell", input.hasPrefix("["), let range = input.range(of: "] ") { source = String(input[range.upperBound...]) }
                cells.append(Self(index: 0, language: name == "shell" ? "bash" : name, source: source, output: item.text, ok: item.ok, origin: name == "shell" ? "shell" : "repl"))
            }
        }
        let executed = Set(cells.filter { $0.origin != "assistant" }.map { $0.source.trimmingCharacters(in: .whitespacesAndNewlines) })
        return cells.filter { $0.origin != "assistant" || !executed.contains($0.source.trimmingCharacters(in: .whitespacesAndNewlines)) }.enumerated().map { index, cell in
            Self(index: index, language: cell.language, source: cell.source, output: cell.output, ok: cell.ok, origin: cell.origin)
        }
    }
    private static func fences(_ text: String) -> [(String, String)] {
        var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        if text.hasSuffix("\n") { lines.removeLast() }
        var result: [(String, String)] = []; var index = 0
        while index < lines.count {
            let fence = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard fence.hasPrefix("```") else { index += 1; continue }
            let raw = fence.drop(while: { $0 == "`" }).split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
            let language = String(String.UnicodeScalarView(raw.unicodeScalars.map { (65...90).contains($0.value) ? UnicodeScalar($0.value + 32)! : $0 }))
            var end = index + 1
            while end < lines.count && !lines[end].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") { end += 1 }
            let source = lines[(index + 1)..<end].joined(separator: "\n")
            if !source.isEmpty { result.append((language, source)) }
            index = end + 1
        }
        return result
    }
}
public struct NativeNotebookStar: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: String
    public let language: String?
    public let code: String
    public let source_project_id: String
    public let source_session_id: String
    public func belongs(project: String, session: String) -> Bool { kind == "code" && source_project_id == project && source_session_id == session }
    public func matches(_ cell: NativeNotebookCell) -> Bool { (language ?? "") == cell.language && code == cell.source }
}
