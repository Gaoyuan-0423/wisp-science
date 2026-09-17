import SwiftUI

/// Block layout for native exports. Inline emphasis, links and code are handled
/// by SwiftUI; preserving lines and fences avoids collapsing long code blocks.
struct NativeShareMarkdown: View {
    let text: String
    struct Block: Identifiable {
        let id: Int
        let kind: String
        let text: String
    }
    static func blocks(_ text: String) -> [Block] {
        var result: [Block] = []; var paragraph: [String] = []; var code: [String]?; var fence = ""
        func append(_ kind: String, _ text: String) { result.append(Block(id: result.count, kind: kind, text: text)) }
        func flush() { if !paragraph.isEmpty { append("paragraph", paragraph.joined(separator: "\n")); paragraph = [] } }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let current = code {
                if trimmed.hasPrefix(fence) { append("code", current.joined(separator: "\n")); code = nil }
                else { code?.append(line) }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { flush(); fence = String(trimmed.prefix(3)); code = []; continue }
            if trimmed.isEmpty { flush(); continue }
            if trimmed.hasPrefix("#"), let space = trimmed.firstIndex(of: " "), trimmed[..<space].allSatisfy({ $0 == "#" }) {
                flush(); append("heading", String(trimmed[trimmed.index(after: space)...])); continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flush(); append("bullet", String(trimmed.dropFirst(2))); continue
            }
            if trimmed.hasPrefix("> ") { flush(); append("quote", String(trimmed.dropFirst(2))); continue }
            paragraph.append(line)
        }
        flush(); if let code { append("code", code.joined(separator: "\n")) }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Self.blocks(text)) { block in
                switch block.kind {
                case "heading": Text(.init(block.text)).font(WispDesign.font(size: 17, weight: .semibold))
                case "code": Text(block.text).font(.system(size: 12, design: .monospaced)).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                case "bullet": HStack(alignment: .top, spacing: 8) { Text("•"); Text(.init(block.text)) }
                case "quote": HStack(spacing: 10) { Rectangle().fill(Color.accentColor).frame(width: 3); Text(.init(block.text)).foregroundStyle(.secondary) }.fixedSize(horizontal: false, vertical: true)
                default: Text(.init(block.text))
                }
            }
        }.font(WispDesign.font(size: 14)).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
}
