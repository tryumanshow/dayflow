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
}
