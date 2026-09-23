import Foundation

/// Pure string engine for the AI planner's note section. Kept free of DB
/// and UI so the replace-preserving-checked rules are unit-testable.
///
/// A plan section is a level-2 heading whose text starts with
/// `📋 Plan`, running until the next `#`/`##` heading or end of note.
/// The emoji marker — not the localized date label — is the detection
/// key, so a plan written while the app ran in Korean is still found
/// after switching to English.
enum PlanMarkdown {
    static let headingMarker = "📋 Plan"

    /// Render a fresh section body. `carried` are non-open items (done or
    /// on-hold) preserved from the section being replaced; they stay on top
    /// with their original marker so finished work never visually
    /// "un-finishes" and a parked task stays parked after a re-plan.
    static func render(tasks: [PlanTask], carried: [(status: TaskStatus, text: String)], generatedLabel: String) -> String {
        var lines: [String] = ["## \(headingMarker) (\(generatedLabel))"]
        for item in carried {
            let mark = item.status == .done ? "x" : "~"
            lines.append("- [\(mark)] \(item.text)")
        }
        for task in tasks {
            if let note = task.note, !note.isEmpty {
                lines.append("- [ ] \(task.title) — \(note)")
            } else {
                lines.append("- [ ] \(task.title)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Line range of an existing plan section, or nil when the note has
    /// none. The section ends right before the next level-1/2 heading.
    static func planSectionRange(inLines lines: [String]) -> Range<Int>? {
        var start: Int?
        for (idx, line) in lines.enumerated() {
            guard case let .heading(level, text)? = MarkdownLine.parse(line) else { continue }
            if start == nil {
                if level == 2, text.hasPrefix(headingMarker) { start = idx }
            } else if level <= 2 {
                return start! ..< idx
            }
        }
        guard let s = start else { return nil }
        return s ..< lines.count
    }

    /// Non-open tasks (done or on-hold) inside `range`, with their status —
    /// the items a re-plan must carry forward rather than discard.
    static func preservedItems(inLines lines: [String], range: Range<Int>) -> [(status: TaskStatus, text: String)] {
        lines[range].compactMap { line in
            guard case let .task(status, text)? = MarkdownLine.parse(line), !status.isOpen else { return nil }
            return (status, text)
        }
    }

    /// Insert `tasks` into `body`: replace an existing plan section
    /// (keeping its checked items) or append a new one at the end.
    static func apply(tasks: [PlanTask], to body: String, generatedLabel: String) -> String {
        let lines = body.components(separatedBy: "\n")

        if let range = planSectionRange(inLines: lines) {
            let carried = preservedItems(inLines: lines, range: range)
            let section = render(tasks: tasks, carried: carried, generatedLabel: generatedLabel)
            var out = Array(lines[..<range.lowerBound])
            out.append(contentsOf: section.components(separatedBy: "\n"))
            out.append(contentsOf: lines[range.upperBound...])
            return out.joined(separator: "\n")
        }

        let section = render(tasks: tasks, carried: [], generatedLabel: generatedLabel)
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return section }
        var head = body
        while head.hasSuffix("\n") { head.removeLast() }
        return head + "\n\n" + section
    }

    /// `apply`, performed on the editor's document so the rest of the note
    /// keeps its styles. Nil when `bodyJSON` can't be matched to `body`
    /// (missing, unparseable, or its checklist doesn't line up with the
    /// markdown's task lines) — the caller then saves markdown only.
    static func applyToJSON(tasks: [PlanTask], body: String, bodyJSON: String?, generatedLabel: String) -> String? {
        let lines = body.components(separatedBy: "\n")
        var blocks: [BlockNoteJSON.Block]
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks = []
        } else {
            guard let parsed = BlockNoteJSON.parse(bodyJSON),
                  BlockNoteJSON.checkItemPaths(parsed).count == BlockNoteJSON.taskLineCount(lines) else { return nil }
            blocks = parsed
        }

        let heading = BlockNoteJSON.headingBlock(level: 2, title: "\(headingMarker) (\(generatedLabel))")
        let newTasks = tasks.map { task in
            BlockNoteJSON.taskBlock(task.note.map { $0.isEmpty ? task.title : "\(task.title) — \($0)" } ?? task.title)
        }

        let start = blocks.firstIndex {
            BlockNoteJSON.headingLevel($0) == 2 && BlockNoteJSON.text($0).hasPrefix(headingMarker)
        }
        guard let start else {
            blocks.insert(contentsOf: [heading] + newTasks, at: BlockNoteJSON.contentEnd(blocks))
            return BlockNoteJSON.serialize(blocks)
        }
        let end = blocks.indices.dropFirst(start + 1).first { (BlockNoteJSON.headingLevel(blocks[$0]) ?? .max) <= 2 } ?? blocks.count
        // Same carry rule as the markdown path: every done / on-hold item in
        // the old section, nested ones included, flattened to the top.
        let section = Array(blocks[(start + 1)..<end])
        let kept: [BlockNoteJSON.Block] = BlockNoteJSON.checkItemPaths(section).compactMap { path in
            guard var item = BlockNoteJSON.block(at: path, in: section),
                  BlockNoteJSON.status(item) != .open else { return nil }
            item["children"] = [BlockNoteJSON.Block]()
            return item
        }
        blocks.replaceSubrange(start..<end, with: [heading] + kept + newTasks)
        return BlockNoteJSON.serialize(blocks)
    }
}
