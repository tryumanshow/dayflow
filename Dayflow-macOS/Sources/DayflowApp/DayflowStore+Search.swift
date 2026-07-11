import Foundation

/// One row in the search overlay. `date` is where selecting the result
/// navigates to; `mode` is the view it opens in.
struct SearchResult: Identifiable {
    enum Kind {
        case dayNote
        case appointment
        case monthPlan
    }

    let id: String
    let kind: Kind
    let date: Date
    let mode: CalendarViewMode
    let title: String
    let snippet: String
}

@MainActor
extension DayflowStore {
    /// Compose day-note, appointment, and month-plan matches into one ranked
    /// list. Day notes and appointments (which have a concrete day) come
    /// first, most-recent first; month plans trail since they only resolve to
    /// a month. Empty/whitespace queries return nothing.
    func search(_ rawQuery: String) -> [SearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 1 else { return [] }

        var results: [SearchResult] = []

        for match in db.searchDayNotes(query) {
            results.append(SearchResult(
                id: "day-\(DayflowDB.ymd(match.date))",
                kind: .dayNote,
                date: match.date,
                mode: .day,
                title: DF.fullDate.string(from: match.date),
                snippet: Self.snippet(from: match.body, matching: query)
            ))
        }

        for apt in db.searchAppointments(query) {
            results.append(SearchResult(
                id: "apt-\(apt.id)",
                kind: .appointment,
                date: apt.startAt,
                mode: .day,
                title: apt.title,
                snippet: "\(DF.fullDate.string(from: apt.startAt)) · \(DF.hourMinute.string(from: apt.startAt))"
            ))
        }

        for plan in db.searchMonthPlanSections(query) {
            guard let monthDate = DF.monthKey.date(from: plan.monthKey) else { continue }
            results.append(SearchResult(
                id: "plan-\(plan.monthKey)-\(plan.title)",
                kind: .monthPlan,
                date: monthDate,
                mode: .month,
                title: "\(DF.monthTitle.string(from: monthDate)) · \(plan.title)",
                snippet: Self.snippet(from: plan.body, matching: query)
            ))
        }

        return results.sorted { $0.date > $1.date }
    }

    /// Jump to a result: select its date and switch to the view that shows it.
    func goTo(_ result: SearchResult) {
        selectedDate = Calendar.current.startOfDay(for: result.date)
        viewMode = result.mode
        refresh()
    }

    /// A one-line context window around the first case-insensitive match, with
    /// newlines flattened to spaces. Falls back to the body's head when the
    /// match sits in a field we don't scan for snippets (e.g. a title-only hit).
    nonisolated static func snippet(from body: String, matching query: String, window: Int = 64) -> String {
        let flattened = body.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let collapsed = flattened.split(separator: " ").joined(separator: " ")
        guard let range = collapsed.range(of: query, options: .caseInsensitive) else {
            return String(collapsed.prefix(window * 2))
        }
        let lead = collapsed.index(range.lowerBound, offsetBy: -window, limitedBy: collapsed.startIndex) ?? collapsed.startIndex
        let trail = collapsed.index(range.upperBound, offsetBy: window, limitedBy: collapsed.endIndex) ?? collapsed.endIndex
        var out = String(collapsed[lead..<trail])
        if lead != collapsed.startIndex { out = "…" + out }
        if trail != collapsed.endIndex { out += "…" }
        return out
    }
}
