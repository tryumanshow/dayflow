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
    }

    /// Normalized task text — also the dedupe key.
    let id: String
    /// Task text as written, minus the `- [ ] ` marker.
    let text: String
    let sources: [Source]

    var latestDate: Date {
        sources.map(\.date).max() ?? Date()
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
                return Self.normalize(text)
            }
        )

        let bodies = db.loadDayNoteRange(start: windowStart, end: windowEnd)

        // Keep insertion order stable while grouping, so the result is
        // deterministic instead of dictionary-ordered.
        var order: [String] = []
        var grouped: [String: (text: String, sources: [CarryoverItem.Source])] = [:]

        for (key, body) in bodies.sorted(by: { $0.key < $1.key }) {
            guard let date = DF.ymd.date(from: key) else { continue }
            for (idx, line) in Self.lines(of: body).enumerated() {
                guard case let .task(checked, text)? = MarkdownLine.parse(line), !checked else { continue }
                let norm = Self.normalize(text)
                guard !norm.isEmpty, !existing.contains(norm) else { continue }
                let source = CarryoverItem.Source(date: date, lineIndex: idx)
                if grouped[norm] == nil {
                    order.append(norm)
                    grouped[norm] = (text: text, sources: [source])
                } else {
                    grouped[norm]?.sources.append(source)
                }
            }
        }

        return order.compactMap { norm -> CarryoverItem? in
            guard let g = grouped[norm] else { return nil }
            return CarryoverItem(id: norm, text: g.text, sources: g.sources)
        }
        .sorted { $0.latestDate > $1.latestDate }
    }

    /// Move `items` onto `target`: append one `- [ ] text` per item, and strip
    /// the originating checkbox line from every source day.
    ///
    /// Removal re-reads each source day and re-verifies that the line at the
    /// recorded index is still the same unchecked task before deleting it. The
    /// list the user is acting on was captured when the sheet opened; if the
    /// day shifted underneath us (an edit landed, the app was left open across
    /// midnight), a blind delete-by-index would take out the wrong line. A
    /// stale source is skipped rather than guessed at.
    func carryOver(_ items: [CarryoverItem], into target: Date) {
        guard !items.isEmpty else { return }
        let cal = Calendar.current
        let targetDay = cal.startOfDay(for: target)

        var byDay: [String: (date: Date, indices: Set<Int>, expected: [Int: String])] = [:]
        for item in items {
            for source in item.sources {
                let key = DayflowDB.ymd(source.date)
                // A source day must be strictly in the past; carrying a day
                // onto itself would delete the line we just wrote.
                guard !cal.isDate(source.date, inSameDayAs: targetDay) else { continue }
                var entry = byDay[key] ?? (date: source.date, indices: [], expected: [:])
                entry.indices.insert(source.lineIndex)
                entry.expected[source.lineIndex] = Self.normalize(item.text)
                byDay[key] = entry
            }
        }

        for (_, entry) in byDay {
            let body = db.getDayNote(date: entry.date)
            let lines = Self.lines(of: body)
            var kept: [String] = []
            kept.reserveCapacity(lines.count)
            for (idx, line) in lines.enumerated() {
                if entry.indices.contains(idx),
                   case let .task(checked, text)? = MarkdownLine.parse(line),
                   !checked,
                   Self.normalize(text) == entry.expected[idx] {
                    continue  // the line we meant to move — drop it
                }
                kept.append(line)
            }
            guard kept.count != lines.count else { continue }
            let newBody = kept.joined(separator: "\n")
            db.saveDayNote(date: entry.date, body: newBody, bodyJSON: nil)
            applyExternalEdit(date: entry.date, body: newBody)
        }

        var body = db.getDayNote(date: targetDay)
        if !body.isEmpty && !body.hasSuffix("\n") { body.append("\n") }
        for item in items {
            body.append("- [ ] \(item.text)\n")
        }
        db.saveDayNote(date: targetDay, body: body, bodyJSON: nil)
        applyExternalEdit(date: targetDay, body: body)
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
