import Foundation

/// A single editable line in the markdown editor — Notion-style "block".
///
/// Each block has a stable identity, an indent level (each step = 2 spaces),
/// a type that controls the rendered prefix, and the typed-by-the-user body
/// text *with the markdown prefix already stripped*. The full markdown
/// representation is reconstructed via `markdown` whenever we serialize.
enum BlockType: Equatable {
    case heading(level: Int)        // 1, 2, 3
    case checkbox(checked: Bool)
    case bullet
    case plain
}

struct MarkdownBlock: Identifiable, Equatable {
    let id: UUID
    var indent: Int                 // 0 = top level, +1 per 2 spaces
    var type: BlockType
    var body: String                // text after the prefix (no `- [ ]`, no `## `, etc)

    var markdown: String {
        let pad = String(repeating: "  ", count: max(0, indent))
        switch type {
        case .heading(let level):
            return pad + String(repeating: "#", count: level) + " " + body
        case .checkbox(let checked):
            return pad + "- [" + (checked ? "x" : " ") + "] " + body
        case .bullet:
            return pad + "- " + body
        case .plain:
            return pad + body
        }
    }
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        if text.isEmpty { return [] }
        let lines = text.components(separatedBy: "\n")
        return lines.map { parseLine($0) }
    }

    static func parseLine(_ line: String) -> MarkdownBlock {
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == " " { idx = line.index(after: idx) }
        let indentSpaces = line.distance(from: line.startIndex, to: idx)
        let indent = indentSpaces / 2
        let body = String(line[idx...])

        if body.hasPrefix("### ") {
            return MarkdownBlock(id: UUID(), indent: indent, type: .heading(level: 3),
                                 body: String(body.dropFirst(4)))
        }
        if body.hasPrefix("## ") {
            return MarkdownBlock(id: UUID(), indent: indent, type: .heading(level: 2),
                                 body: String(body.dropFirst(3)))
        }
        if body.hasPrefix("# ") {
            return MarkdownBlock(id: UUID(), indent: indent, type: .heading(level: 1),
                                 body: String(body.dropFirst(2)))
        }
        if body.hasPrefix("- [ ] ") {
            return MarkdownBlock(id: UUID(), indent: indent, type: .checkbox(checked: false),
                                 body: String(body.dropFirst(6)))
        }
        if body.hasPrefix("- [x] ") || body.hasPrefix("- [X] ") {
            return MarkdownBlock(id: UUID(), indent: indent, type: .checkbox(checked: true),
                                 body: String(body.dropFirst(6)))
        }
        if body == "- [ ]" {
            return MarkdownBlock(id: UUID(), indent: indent, type: .checkbox(checked: false), body: "")
        }
        if body == "- [x]" || body == "- [X]" {
            return MarkdownBlock(id: UUID(), indent: indent, type: .checkbox(checked: true), body: "")
        }
        if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") {
            return MarkdownBlock(id: UUID(), indent: indent, type: .bullet,
                                 body: String(body.dropFirst(2)))
        }
        if body == "-" || body == "*" || body == "+" {
            return MarkdownBlock(id: UUID(), indent: indent, type: .bullet, body: "")
        }
        return MarkdownBlock(id: UUID(), indent: indent, type: .plain, body: body)
    }

    static func serialize(_ blocks: [MarkdownBlock]) -> String {
        return blocks.map { $0.markdown }.joined(separator: "\n")
    }
}
