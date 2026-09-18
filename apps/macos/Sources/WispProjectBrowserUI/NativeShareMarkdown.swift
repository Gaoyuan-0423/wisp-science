import SwiftUI

/// Native block layout used by both the share preview and PNG export.
struct NativeShareMarkdown: View {
    let text: String
    struct Block: Identifiable {
        let id: Int
        let kind: String
        let text: String
        var level = 0
        var marker = ""
        var rows: [[String]] = []
        var alignments: [String] = []
    }
    /// Split table cells without treating escaped pipes or inline-code pipes as separators.
    static func cells(_ line: String) -> [String] {
        let line = line.trimmingCharacters(in: .whitespaces)
        var cells: [String] = []; var cell = ""; var escaped = false; var ticks = 0
        let characters = Array(line); var index = 0
        while index < characters.count {
            let character = characters[index]
            if escaped { cell.append(character); escaped = false; index += 1; continue }
            if character == "\\" { cell.append(character); escaped = true; index += 1; continue }
            if character == "`" {
                var end = index
                while end < characters.count && characters[end] == "`" { end += 1 }
                let count = end - index
                if ticks == 0 { ticks = count } else if ticks == count { ticks = 0 }
                cell += String(repeating: "`", count: count); index = end; continue
            }
            if character == "|" && ticks == 0 { cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
            else { cell.append(character) }
            index += 1
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        if line.hasPrefix("|"), cells.first == "" { cells.removeFirst() }
        if line.hasSuffix("|"), cells.last == "" { cells.removeLast() }
        return cells
    }
    static func blocks(_ text: String) -> [Block] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result: [Block] = []; var paragraph: [String] = []; var code: [String]?; var fence = ""; var index = 0
        func append(_ kind: String, _ text: String, level: Int = 0, marker: String = "", rows: [[String]] = [], alignments: [String] = []) {
            result.append(Block(id: result.count, kind: kind, text: text, level: level, marker: marker, rows: rows, alignments: alignments))
        }
        func flush() { if !paragraph.isEmpty { append("paragraph", paragraph.joined(separator: "\n")); paragraph = [] } }
        while index < lines.count {
            let line = lines[index]; index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let current = code {
                let run = trimmed.prefix { String($0) == String(fence.prefix(1)) }
                if run.count >= fence.count && trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces).isEmpty {
                    append("code", current.joined(separator: "\n")); code = nil
                } else { code?.append(line) }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush(); fence = String(trimmed.prefix { $0 == trimmed.first! }); code = []; continue
            }
            if trimmed.isEmpty { flush(); continue }
            if index < lines.count, trimmed.contains("|") {
                let header = cells(trimmed); let divider = cells(lines[index])
                if header.count > 1 && header.count == divider.count && divider.allSatisfy({ cell in
                    let body = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                    return body.count >= 3 && body.allSatisfy { $0 == "-" }
                }) {
                    flush(); index += 1; var rows = [header]
                    while index < lines.count && lines[index].contains("|") && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                        let values = cells(lines[index]); index += 1
                        rows.append(Array((values + Array(repeating: "", count: header.count)).prefix(header.count)))
                    }
                    append("table", "", rows: rows, alignments: divider.map { $0.hasSuffix(":") ? ($0.hasPrefix(":") ? "center" : "right") : "left" }); continue
                }
            }
            let hashes = trimmed.prefix { $0 == "#" }
            if (1...6).contains(hashes.count), trimmed.dropFirst(hashes.count).first == " " {
                flush(); append("heading", String(trimmed.dropFirst(hashes.count + 1)), level: hashes.count); continue
            }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flush(); append("bullet", String(trimmed.dropFirst(2)), level: indent / 2, marker: "•"); continue
            }
            let digits = trimmed.prefix { $0.isNumber }
            let rest = trimmed.dropFirst(digits.count)
            if !digits.isEmpty && digits.count <= 9 && (rest.hasPrefix(". ") || rest.hasPrefix(") ")) {
                flush(); append("ordered", String(rest.dropFirst(2)), level: indent / 2, marker: String(digits) + "."); continue
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
                case "heading": Text(.init(block.text)).font(WispDesign.font(size: block.level == 1 ? 22 : block.level == 2 ? 19 : 16, weight: .semibold))
                case "code": Text(block.text).font(.system(size: 12, design: .monospaced)).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                case "bullet", "ordered": HStack(alignment: .top, spacing: 8) { Text(block.marker); Text(.init(block.text)) }.padding(.leading, CGFloat(min(block.level, 12) * 14))
                case "quote": HStack(spacing: 10) { Rectangle().fill(Color.accentColor).frame(width: 3); Text(.init(block.text)).foregroundStyle(.secondary) }.fixedSize(horizontal: false, vertical: true)
                case "table":
                    VStack(spacing: 0) {
                        ForEach(Array(block.rows.enumerated()), id: \.offset) { row, cells in
                            HStack(alignment: .top, spacing: 0) {
                                ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
                                    Text(.init(cell)).font(WispDesign.font(size: 12, weight: row == 0 ? .semibold : .regular))
                                        .multilineTextAlignment(block.alignments[column] == "right" ? .trailing : block.alignments[column] == "center" ? .center : .leading)
                                        .frame(maxWidth: .infinity, alignment: block.alignments[column] == "right" ? .trailing : block.alignments[column] == "center" ? .center : .leading).padding(6)
                                }
                            }.background(row == 0 ? Color.primary.opacity(0.07) : .clear)
                            Divider()
                        }
                    }.overlay(Rectangle().stroke(Color.primary.opacity(0.12)))
                default: Text(.init(block.text))
                }
            }
        }.font(WispDesign.font(size: 14)).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
}
