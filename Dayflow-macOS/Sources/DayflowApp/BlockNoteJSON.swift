import Foundation

/// Edits on the editor's lossless BlockNote document (`body_json`) that
/// mirror the markdown edits Swift makes outside the editor — toggling a task
/// from the Week view, carrying tasks between days, writing an AI plan.
///
/// The editor loads `body_json` whenever it is present, so a writer that
/// changes only `body_md` has to drop the JSON, and with it every style
/// markdown can't hold (text and background colour, underline). These helpers
/// apply the same change to the JSON instead.
///
/// Markdown lines map onto blocks through one invariant the editor already
/// relies on for the on-hold mark: `blocksToMarkdownLossy` writes checklist
/// items in depth-first document order, one task line each, so the Nth task
/// line is the Nth `checkListItem`. Every helper checks that invariant (task
/// counts agree, the addressed item's text matches) and returns nil when it
/// doesn't hold; callers then fall back to markdown-only.
enum BlockNoteJSON {
    typealias Block = [String: Any]
    typealias Path = [Int]

    static let onHoldBackground = "blue"

    // MARK: - (de)serialization

    static func parse(_ json: String?) -> [Block]? {
        guard let data = json?.data(using: .utf8), !data.isEmpty,
              let blocks = try? JSONSerialization.jsonObject(with: data) as? [Block] else { return nil }
        return blocks
    }

    static func serialize(_ blocks: [Block]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: blocks, options: [.withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - reading

    static func type(_ block: Block) -> String { block["type"] as? String ?? "" }

    static func children(_ block: Block) -> [Block] { block["children"] as? [Block] ?? [] }

    static func props(_ block: Block) -> [String: Any] { block["props"] as? [String: Any] ?? [:] }

    /// Visible text of a block's inline content (links included).
    static func text(_ block: Block) -> String {
        func runs(_ content: Any?) -> String {
            guard let items = content as? [[String: Any]] else { return content as? String ?? "" }
            return items.map { item in
                (item["type"] as? String) == "link" ? runs(item["content"]) : (item["text"] as? String ?? "")
            }.joined()
        }
        return runs(block["content"])
    }

    /// Task status as the editor encodes it (see `setStatus`).
    static func status(_ block: Block) -> TaskStatus {
        if props(block)["checked"] as? Bool == true { return .done }
        let runs = block["content"] as? [[String: Any]] ?? []
        let onHold = runs.contains { ($0["styles"] as? [String: Any])?["backgroundColor"] as? String == onHoldBackground }
        return onHold ? .onHold : .open
    }

    /// Comparison key that survives markdown escaping and emphasis markers:
    /// letters and digits only, lowercased.
    static func matchKey(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Key for a markdown task's text: link targets (`](url)`) aren't visible
    /// text in the block, so they're dropped before comparing.
    static func markdownMatchKey(_ s: String) -> String {
        matchKey(s.replacingOccurrences(of: #"\]\([^)]*\)"#, with: "", options: .regularExpression))
    }

    /// Paths of every `checkListItem`, depth-first — the order their task
    /// lines appear in the markdown.
    static func checkItemPaths(_ blocks: [Block]) -> [Path] {
        var out: [Path] = []
        func walk(_ list: [Block], _ prefix: Path) {
            for (i, b) in list.enumerated() {
                if type(b) == "checkListItem" { out.append(prefix + [i]) }
                walk(children(b), prefix + [i])
            }
        }
        walk(blocks, [])
        return out
    }

    static func block(at path: Path, in blocks: [Block]) -> Block? {
        guard let first = path.first, blocks.indices.contains(first) else { return nil }
        return path.count == 1 ? blocks[first] : block(at: Array(path.dropFirst()), in: children(blocks[first]))
    }

    // MARK: - writing

    static func update(at path: Path, in blocks: inout [Block], _ change: (inout Block) -> Void) {
        guard let first = path.first, blocks.indices.contains(first) else { return }
        if path.count == 1 {
            change(&blocks[first])
        } else {
            var kids = children(blocks[first])
            update(at: Array(path.dropFirst()), in: &kids, change)
            blocks[first]["children"] = kids
        }
    }

    @discardableResult
    static func remove(at path: Path, in blocks: inout [Block]) -> Block? {
        guard let first = path.first, blocks.indices.contains(first) else { return nil }
        if path.count == 1 { return blocks.remove(at: first) }
        var kids = children(blocks[first])
        let removed = remove(at: Array(path.dropFirst()), in: &kids)
        blocks[first]["children"] = kids
        return removed
    }

    /// Set a checklist item's status the way the editor's status menu does:
    /// done/open is `checked`, on-hold is unchecked plus the reserved blue
    /// background on its text (cleared again when it leaves on-hold).
    static func setStatus(_ status: TaskStatus, on block: inout Block) {
        var p = props(block)
        p["checked"] = status == .done
        block["props"] = p
        guard var runs = block["content"] as? [[String: Any]] else { return }
        for i in runs.indices where (runs[i]["type"] as? String) == "text" {
            var styles = runs[i]["styles"] as? [String: Any] ?? [:]
            if status == .onHold { styles["backgroundColor"] = onHoldBackground } else { styles.removeValue(forKey: "backgroundColor") }
            runs[i]["styles"] = styles
        }
        block["content"] = runs
    }

    static func textBlock(_ type: String, _ text: String, props: [String: Any] = [:]) -> Block {
        ["type": type, "props": props, "content": [["type": "text", "text": text, "styles": [String: Any]()]], "children": [Block]()]
    }

    static func headingBlock(level: Int, title: String) -> Block {
        textBlock("heading", title, props: ["level": level])
    }

    static func taskBlock(_ text: String, status: TaskStatus = .open) -> Block {
        var b = textBlock("checkListItem", text, props: ["checked": false])
        setStatus(status, on: &b)
        return b
    }

    // MARK: - markdown ↔ block addressing

    /// Task-line ordinal of `lineIndex`: how many task lines precede it.
    static func taskOrdinal(ofLine lineIndex: Int, in lines: [String]) -> Int {
        lines[..<lineIndex].filter { line in
            if case .task? = MarkdownLine.parse(line) { return true }
            return false
        }.count
    }

    static func taskLineCount(_ lines: [String]) -> Int {
        taskOrdinal(ofLine: lines.count, in: lines)
    }

    /// Path of the checklist item behind markdown task line `lineIndex`, or
    /// nil when markdown and JSON don't line up.
    static func checkItemPath(forLine lineIndex: Int, lines: [String], blocks: [Block]) -> Path? {
        let paths = checkItemPaths(blocks)
        guard paths.count == taskLineCount(lines),
              case let .task(_, text)? = MarkdownLine.parse(lines[lineIndex]) else { return nil }
        let ordinal = taskOrdinal(ofLine: lineIndex, in: lines)
        guard paths.indices.contains(ordinal),
              let item = block(at: paths[ordinal], in: blocks),
              matchKey(self.text(item)) == markdownMatchKey(text) else { return nil }
        return paths[ordinal]
    }

    /// The document with an open task inserted first — the JSON side of
    /// prepending `- [ ] text` to the markdown. Nil when the existing JSON
    /// doesn't line up with `body`.
    static func prependTask(_ text: String, toBody body: String, bodyJSON: String?) -> String? {
        var blocks: [Block]
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks = []
        } else {
            guard let parsed = parse(bodyJSON),
                  checkItemPaths(parsed).count == taskLineCount(body.components(separatedBy: "\n")) else { return nil }
            blocks = parsed
        }
        blocks.insert(taskBlock(text), at: 0)
        return serialize(blocks)
    }

    // MARK: - sections (top-level headings)

    static func isBlankParagraph(_ block: Block) -> Bool {
        type(block) == "paragraph" && children(block).isEmpty
            && text(block).replacingOccurrences(of: "\u{200B}", with: "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func headingLevel(_ block: Block) -> Int? {
        guard type(block) == "heading" else { return nil }
        return props(block)["level"] as? Int ?? 1
    }

    /// Index just past the last non-blank top-level block — where "append at
    /// the end" goes, ahead of the editor's trailing empty paragraph.
    static func contentEnd(_ blocks: [Block], from start: Int = 0, to end: Int? = nil) -> Int {
        var at = end ?? blocks.count
        while at > start, isBlankParagraph(blocks[at - 1]) { at -= 1 }
        return at
    }

    /// Top-level index where content appended to the section headed at
    /// `headingIndex` belongs: before the next heading of the same or higher
    /// level, ahead of any blank paragraphs spacing the sections.
    static func sectionEnd(_ blocks: [Block], headingIndex: Int) -> Int {
        let level = headingLevel(blocks[headingIndex]) ?? 1
        let next = blocks.indices.dropFirst(headingIndex + 1).first { (headingLevel(blocks[$0]) ?? .max) <= level } ?? blocks.count
        return contentEnd(blocks, from: headingIndex + 1, to: next)
    }
}
