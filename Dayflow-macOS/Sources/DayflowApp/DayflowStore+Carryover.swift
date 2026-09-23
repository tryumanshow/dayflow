import Foundation

/// An unfinished task found on an earlier day, offered for carry-over into
/// today.
///
/// The same task text can sit open on several past days (the user copied it
/// forward by hand, or carried it over before the feature existed). Those
/// collapse into ONE item carrying every source line, so accepting it writes a
/// single line into today and clears the stale checkbox off every past day at
/// once — rather than inserting N duplicates and leaving the older days lying
/// about pending work.
struct CarryoverItem: Identifiable, Equatable {
    struct Source: Equatable {
        let date: Date
        /// Index into `body.components(separatedBy: "\n")` of the source day.
        let lineIndex: Int
        /// The task line plus every line nested under it, verbatim. The whole
        /// block moves, so sub-bullets aren't left behind parentless — and it
        /// is re-verified line for line before anything is deleted.
        let lines: [String]
    }

    /// Normalized task text — also the dedupe key.
    let id: String
    /// Task text as written, minus the `- [ ] ` marker.
    let text: String
    /// Heading the task sat under on its most recent day, if any. Carrying
    /// puts it back under the same heading today.
    let section: CarryoverSection?
    /// Lines nested under the task on its most recent day, dedented so the
    /// task itself sits at column 0.
    let children: [String]
    let sources: [Source]

    var latestDate: Date {
        sources.map(\.date).max() ?? Date()
    }
}

/// A markdown heading a task lives under (`## Work` → level 2, "Work").
struct CarryoverSection: Equatable {
    let level: Int
    let title: String

    var markdown: String { String(repeating: "#", count: level) + " " + title }

    /// Headings match when their text matches, whatever the level or spacing.
    func matches(_ other: CarryoverSection) -> Bool {
        Self.key(title) == Self.key(other.title)
    }

    private static func key(_ s: String) -> String {
        s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

@MainActor
extension DayflowStore {
    /// How far back to look for unfinished tasks. A week keeps the prompt
    /// about *recent* slippage; anything older the user has effectively
    /// abandoned, and resurfacing it forever would train them to ignore the
    /// banner.
    nonisolated static let carryoverLookbackDays = 7

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Split a body the same way `carryOver` will, so line indices captured
    /// here address the same lines there.
    private static func lines(of body: String) -> [String] {
        body.components(separatedBy: "\n")
    }

    /// Unfinished tasks from the previous `carryoverLookbackDays` days that
    /// aren't already on `target`'s page. Newest source first.
    func pendingCarryovers(into target: Date, lookbackDays: Int = DayflowStore.carryoverLookbackDays) -> [CarryoverItem] {
        let cal = Calendar.current
        let targetDay = cal.startOfDay(for: target)
        guard let windowStart = cal.date(byAdding: .day, value: -lookbackDays, to: targetDay),
              let windowEnd = cal.date(byAdding: .day, value: -1, to: targetDay) else { return [] }

        // Whatever is already on the target page — carried by a previous run,
        // or typed by hand — must not be offered again.
        let existing = Set(
            Self.lines(of: db.getDayNote(date: targetDay)).compactMap { line -> String? in
                guard case let .task(_, text)? = MarkdownLine.parse(line) else { return nil }
                return Self.normalize(text)  // any status: don't re-offer a task already on today
            }
        )

        let bodies = db.loadDayNoteRange(start: windowStart, end: windowEnd)

        // Keep insertion order stable while grouping, so the result is
        // deterministic instead of dictionary-ordered.
        var order: [String] = []
        var grouped: [String: (text: String, section: CarryoverSection?, children: [String], sources: [CarryoverItem.Source])] = [:]

        for (key, body) in bodies.sorted(by: { $0.key < $1.key }) {
            guard let date = DF.ymd.date(from: key) else { continue }
            let lines = Self.lines(of: body)
            var section: CarryoverSection?
            // An open task nested inside another open task's block moves with
            // that block; offering it separately would move it twice.
            var coveredUntil = 0
            for (idx, line) in lines.enumerated() where idx >= coveredUntil {
                switch MarkdownLine.parse(line) {
                case let .heading(level, title)?:
                    section = CarryoverSection(level: level, title: title)
                // Only actively-open tasks carry over. Done is finished;
                // on-hold ("보류") is parked on purpose — neither should
                // resurface in the "unfinished from earlier days" banner.
                case let .task(status, text)? where status.isOpen:
                    let norm = Self.normalize(text)
                    guard !norm.isEmpty, !existing.contains(norm) else { continue }
                    let end = Self.blockEnd(lines, from: idx)
                    coveredUntil = end
                    let block = Array(lines[idx..<end])
                    let source = CarryoverItem.Source(date: date, lineIndex: idx, lines: block)
                    let children = Self.dedent(Array(block.dropFirst()), by: Self.indentWidth(line))
                    if grouped[norm] == nil {
                        order.append(norm)
                        grouped[norm] = (text: text, section: section, children: children, sources: [source])
                    } else {
                        // Days are walked oldest first: the latest day's
                        // section and sub-items win.
                        grouped[norm]?.section = section
                        grouped[norm]?.children = children
                        grouped[norm]?.sources.append(source)
                    }
                default:
                    break
                }
            }
        }

        return order.compactMap { norm -> CarryoverItem? in
            guard let g = grouped[norm] else { return nil }
            return CarryoverItem(id: norm, text: g.text, section: g.section, children: g.children, sources: g.sources)
        }
        .sorted { $0.latestDate > $1.latestDate }
    }

    // MARK: - line blocks

    /// Leading whitespace width, a tab counting as four columns (the editor's
    /// nesting unit).
    nonisolated static func indentWidth(_ line: String) -> Int {
        var width = 0
        for ch in line {
            if ch == " " { width += 1 } else if ch == "\t" { width += 4 } else { break }
        }
        return width
    }

    /// End (exclusive) of the block that starts at `start`: the line itself
    /// plus every following line indented deeper, blank lines inside the block
    /// included, trailing blank lines not.
    nonisolated static func blockEnd(_ lines: [String], from start: Int) -> Int {
        let base = indentWidth(lines[start])
        var end = start + 1
        var probe = start + 1
        while probe < lines.count {
            let line = lines[probe]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                probe += 1
                continue
            }
            guard indentWidth(line) > base else { break }
            probe += 1
            end = probe
        }
        return end
    }

    /// Strip up to `width` columns of leading whitespace from each line.
    nonisolated static func dedent(_ lines: [String], by width: Int) -> [String] {
        lines.map { line in
            var removed = 0
            var idx = line.startIndex
            while idx < line.endIndex, removed < width, line[idx] == " " || line[idx] == "\t" {
                removed += line[idx] == "\t" ? 4 : 1
                idx = line.index(after: idx)
            }
            return String(line[idx...])
        }
    }

    /// Place carried tasks into `body`, each under the heading it came from.
    ///
    /// - A heading already on the page takes the task at the end of its
    ///   section (before the next heading of the same or higher level).
    /// - A missing heading is appended, then the task under it.
    /// - A task that had no heading goes at the end of the page.
    /// - A blank page is first laid out with `seedSections`, the headings of
    ///   the most recent earlier day, so a new day starts with the same
    ///   structure even where nothing is left to carry.
    nonisolated static func placeCarried(_ items: [CarryoverItem], into body: String, seedSections: [CarryoverSection]) -> String {
        var lines = body.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }

        func headings() -> [(index: Int, section: CarryoverSection)] {
            lines.enumerated().compactMap { idx, line in
                guard indentWidth(line) == 0, case let .heading(level, title)? = MarkdownLine.parse(line) else { return nil }
                return (idx, CarryoverSection(level: level, title: title))
            }
        }

        if lines.isEmpty {
            for section in seedSections {
                if !lines.isEmpty { lines.append("") }
                lines.append(section.markdown)
            }
        }

        var unsectioned: [String] = []
        for item in items {
            let block = ["- [ ] \(item.text)"] + item.children
            guard let section = item.section else {
                unsectioned += block
                continue
            }
            let all = headings()
            if let pos = all.firstIndex(where: { $0.section.matches(section) }) {
                let heading = all[pos]
                var at = all[(pos + 1)...].first { $0.section.level <= heading.section.level }?.index ?? lines.count
                while at > heading.index + 1, lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
                lines.insert(contentsOf: block, at: at)
            } else {
                if !lines.isEmpty { lines.append("") }
                lines.append(section.markdown)
                lines += block
            }
        }
        lines += unsectioned
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// Move `items` onto `target`: each task — with everything nested under
    /// it — is placed under its heading today (see `placeCarried`), and the
    /// same block is removed from every source day.
    ///
    /// Removal re-reads each source day and re-verifies that the lines at the
    /// recorded index are still exactly the block that was offered before
    /// deleting it. The list the user is acting on was captured when the sheet
    /// opened; if the day shifted underneath us (an edit landed, the app was
    /// left open across midnight), a blind delete-by-index would take out the
    /// wrong lines. A stale source is skipped rather than guessed at.
    func carryOver(_ items: [CarryoverItem], into target: Date) {
        guard !items.isEmpty else { return }
        let cal = Calendar.current
        let targetDay = cal.startOfDay(for: target)

        var byDay: [String: (date: Date, blocks: [(index: Int, lines: [String])])] = [:]
        for item in items {
            for source in item.sources {
                // A source day must be strictly in the past; carrying a day
                // onto itself would delete the block we just wrote.
                guard !cal.isDate(source.date, inSameDayAs: targetDay) else { continue }
                let key = DayflowDB.ymd(source.date)
                var entry = byDay[key] ?? (date: source.date, blocks: [])
                entry.blocks.append((source.lineIndex, source.lines))
                byDay[key] = entry
            }
        }

        for (_, entry) in byDay {
            let body = db.getDayNote(date: entry.date)
            var lines = Self.lines(of: body)
            let before = lines.count
            // Bottom-up so earlier indices stay valid as blocks come out.
            for block in entry.blocks.sorted(by: { $0.index > $1.index }) {
                let range = block.index..<(block.index + block.lines.count)
                guard range.upperBound <= lines.count,
                      Array(lines[range]) == block.lines,
                      case let .task(status, _)? = MarkdownLine.parse(block.lines[0]),
                      status.isOpen else { continue }  // the day changed underneath — skip, don't guess
                lines.removeSubrange(range)
                // Don't leave a double blank line where the block was.
                let seam = range.lowerBound
                if seam > 0, seam < lines.count,
                   lines[seam - 1].trimmingCharacters(in: .whitespaces).isEmpty,
                   lines[seam].trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.remove(at: seam)
                }
            }
            guard lines.count != before else { continue }
            let newBody = lines.joined(separator: "\n")
            db.saveDayNote(date: entry.date, body: newBody, bodyJSON: nil)
            applyExternalEdit(date: entry.date, body: newBody)
        }

        // Oldest first, in page order, so tasks land in the order they were written.
        let ordered = items.sorted {
            ($0.latestDate, $0.sources.last?.lineIndex ?? 0) < ($1.latestDate, $1.sources.last?.lineIndex ?? 0)
        }
        let body = Self.placeCarried(ordered, into: db.getDayNote(date: targetDay), seedSections: seedSections(before: targetDay))
        db.saveDayNote(date: targetDay, body: body, bodyJSON: nil)
        applyExternalEdit(date: targetDay, body: body)
    }

    /// Headings of the most recent earlier day (within the look-back window)
    /// that has any — the structure a blank new day starts from.
    private func seedSections(before target: Date) -> [CarryoverSection] {
        let cal = Calendar.current
        guard let start = cal.date(byAdding: .day, value: -Self.carryoverLookbackDays, to: target),
              let end = cal.date(byAdding: .day, value: -1, to: target) else { return [] }
        for (_, body) in db.loadDayNoteRange(start: start, end: end).sorted(by: { $0.key > $1.key }) {
            let sections = Self.lines(of: body).compactMap { line -> CarryoverSection? in
                guard Self.indentWidth(line) == 0, case let .heading(level, title)? = MarkdownLine.parse(line) else { return nil }
                return CarryoverSection(level: level, title: title)
            }
            if !sections.isEmpty { return sections }
        }
        return []
    }

    // MARK: - banner dismissal

    /// The banner is a nudge, not a chore. Dismissing hides it for that day
    /// only — a genuinely new unfinished task tomorrow gets a fresh prompt.
    private static func dismissKey(_ date: Date) -> String {
        "dayflow.carryover.dismissed.\(DayflowDB.ymd(date))"
    }

    func carryoverBannerDismissed(for date: Date) -> Bool {
        UserDefaults.standard.bool(forKey: Self.dismissKey(date))
    }

    func dismissCarryoverBanner(for date: Date) {
        UserDefaults.standard.set(true, forKey: Self.dismissKey(date))
    }
}
