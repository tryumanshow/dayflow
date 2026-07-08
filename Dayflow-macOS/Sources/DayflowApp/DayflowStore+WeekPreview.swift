import Foundation

@MainActor
extension DayflowStore {
    // MARK: - week preview

    /// Grouped task preview for a single day column in Week view.
    /// A "group" is a heading with its tasks in source order (both
    /// open and done). Tasks before any heading land in a synthetic
    /// group with `heading == nil`, rendered as a flat list.
    struct WeekGroup: Identifiable {
        let id: Int
        let heading: String?
        let tasks: [PreviewTask]
    }
    enum PreviewItemKind {
        case task(checked: Bool)
        case bullet
    }
    struct PreviewTask: Identifiable {
        let id: Int
        let text: String
        let kind: PreviewItemKind
        let sourceLineIndex: Int
        let depth: Int

        var checked: Bool {
            if case .task(let c) = kind { return c }
            return false
        }
        var isTask: Bool {
            if case .task = kind { return true }
            return false
        }
    }

    private static let weekPreviewMaxGroups = 6
    private static let weekPreviewMaxTasksPerGroup = 8

    func weekGroups(for date: Date) -> [WeekGroup] {
        let body = dayBody(for: date)
        guard !body.isEmpty else { return [] }

        // Indent depth is computed from the RAW line (before
        // `MarkdownLine.parse` trims whitespace) so subtasks show up
        // under their parents. Source order is preserved, including
        // done tasks — the user wants to see what's finished, not
        // just what's outstanding.
        var groups: [(heading: String?, tasks: [PreviewTask])] = [(nil, [])]
        let lines = body.components(separatedBy: "\n")
        var nextTaskID = 0
        for (idx, raw) in lines.enumerated() {
            let depth = Self.indentDepth(of: raw)
            guard let parsed = MarkdownLine.parse(raw) else { continue }
            switch parsed {
            case .heading(_, let text):
                groups.append((text, []))
            case .task(let checked, let text):
                var current = groups[groups.count - 1]
                if current.tasks.count < Self.weekPreviewMaxTasksPerGroup {
                    current.tasks.append(PreviewTask(
                        id: nextTaskID, text: text, kind: .task(checked: checked),
                        sourceLineIndex: idx, depth: depth))
                    nextTaskID += 1
                }
                groups[groups.count - 1] = current
            case .bullet(text: let text):
                var current = groups[groups.count - 1]
                if current.tasks.count < Self.weekPreviewMaxTasksPerGroup {
                    current.tasks.append(PreviewTask(
                        id: nextTaskID, text: text, kind: .bullet,
                        sourceLineIndex: idx, depth: depth))
                    nextTaskID += 1
                }
                groups[groups.count - 1] = current
            case .plain:
                continue
            }
        }

        let filtered = groups.filter { !$0.tasks.isEmpty }
        let capped = Array(filtered.prefix(Self.weekPreviewMaxGroups))
        return capped.enumerated().map { i, g in
            WeekGroup(id: i, heading: g.heading, tasks: g.tasks)
        }
    }

    /// `blocksToMarkdownLossy` emits this many spaces per nesting
    /// level (verified against live DB output — CommonMark list
    /// continuation). Used by `indentDepth` below.
    private static let indentUnitSpaces = 4

    /// Indent depth for a raw markdown line. Tabs are expanded to one
    /// indent unit each.
    private static func indentDepth(of raw: String) -> Int {
        let leading = raw.prefix(while: { $0 == " " || $0 == "\t" })
            .reduce(0) { $0 + ($1 == "\t" ? indentUnitSpaces : 1) }
        return leading / indentUnitSpaces
    }

    /// Toggle an open task found in the week preview by its source line
    /// index. The line index comes from `weekGroups(...)` / `OpenTask`;
    /// no parser re-walk, no preview index → source index mapping.
    func toggleWeekTask(day: Date, sourceLineIndex: Int) {
        let key = DayflowDB.ymd(day)
        let body = bodies[key] ?? db.getDayNote(date: day)
        guard !body.isEmpty else { return }
        var lines = body.components(separatedBy: "\n")
        guard lines.indices.contains(sourceLineIndex) else { return }
        let toggled = toggleTaskMarker(in: lines[sourceLineIndex])
        guard toggled != lines[sourceLineIndex] else { return }
        lines[sourceLineIndex] = toggled

        let newBody = lines.joined(separator: "\n")
        db.saveDayNote(date: day, body: newBody, bodyJSON: nil)
        bodies[key] = newBody

        if Calendar.current.isDate(day, inSameDayAs: selectedDate) {
            setDayBuffers(md: newBody, json: nil, cacheKey: key)
        }
    }
}
