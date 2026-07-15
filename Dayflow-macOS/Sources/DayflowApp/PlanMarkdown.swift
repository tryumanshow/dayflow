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

    /// Render a fresh section body. `carriedDone` are checked items
    /// preserved from the section being replaced; they stay on top so
    /// finished work never visually "un-finishes" after a re-plan.
    static func render(tasks: [PlanTask], carriedDone: [String], generatedLabel: String) -> String {
        var lines: [String] = ["## \(headingMarker) (\(generatedLabel))"]
        for done in carriedDone {
            lines.append("- [x] \(done)")
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

    /// Texts of checked (`- [x]`) tasks inside `range`.
    static func checkedItems(inLines lines: [String], range: Range<Int>) -> [String] {
        lines[range].compactMap { line in
            guard case let .task(checked, text)? = MarkdownLine.parse(line), checked else { return nil }
            return text
        }
    }

    /// Insert `tasks` into `body`: replace an existing plan section
    /// (keeping its checked items) or append a new one at the end.
    static func apply(tasks: [PlanTask], to body: String, generatedLabel: String) -> String {
        let lines = body.components(separatedBy: "\n")

        if let range = planSectionRange(inLines: lines) {
            let done = checkedItems(inLines: lines, range: range)
            let section = render(tasks: tasks, carriedDone: done, generatedLabel: generatedLabel)
            var out = Array(lines[..<range.lowerBound])
            out.append(contentsOf: section.components(separatedBy: "\n"))
            out.append(contentsOf: lines[range.upperBound...])
            return out.joined(separator: "\n")
        }

        let section = render(tasks: tasks, carriedDone: [], generatedLabel: generatedLabel)
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return section }
        var head = body
        while head.hasSuffix("\n") { head.removeLast() }
        return head + "\n\n" + section
    }
}
