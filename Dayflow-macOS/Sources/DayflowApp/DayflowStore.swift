import Foundation
import Observation

enum CalendarViewMode: String, CaseIterable, Identifiable {
    case day, week, month
    var id: String { rawValue }
    var label: String {
        switch self {
        case .day:   return "Day"
        case .week:  return "Week"
        case .month: return "Month"
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

@MainActor
@Observable
final class DayflowStore {
    var viewMode: CalendarViewMode = .day
    var selectedDate: Date = Calendar.current.startOfDay(for: Date())

    var dayBody: String = ""
    private var dayBodyLoadedFor: String = ""

    /// Markdown bodies keyed by `yyyy-MM-dd`, covering the month-grid range
    /// (which always subsumes the 7-day week range) for the current
    /// selected date. Both week and month views read from here.
    var bodies: [String: String] = [:]

    var reviewBody: String = ""
    var reviewIsLoading: Bool = false
    var reviewError: String?

    private let db = DayflowDB.shared

    init() {
        refresh()
    }

    // MARK: - menubar

    var menuBarText: String {
        let counts = DayflowDB.parseCheckboxes(dayBody)
        if counts.open == 0 && counts.done == 0 { return L("menubar.idle") }
        if counts.open == 0 { return L("menubar.all_done") }
        return L("menubar.n_open", counts.open)
    }

    // MARK: - navigation

    func goToToday() {
        selectedDate = Calendar.current.startOfDay(for: Date())
        refresh(force: true)
    }

    func step(by direction: Int) {
        let cal = Calendar.current
        let unit: Calendar.Component = {
            switch viewMode {
            case .day:   return .day
            case .week:  return .weekOfYear
            case .month: return .month
            }
        }()
        if let next = cal.date(byAdding: unit, value: direction, to: selectedDate) {
            selectedDate = cal.startOfDay(for: next)
            refresh(force: true)
        }
    }

    func setMode(_ mode: CalendarViewMode) {
        viewMode = mode
        refresh(force: true)
    }

    func selectDate(_ date: Date) {
        selectedDate = Calendar.current.startOfDay(for: date)
        refresh(force: true)
    }

    // MARK: - refresh

    func refresh(force: Bool = false) {
        let dayKey = DayflowDB.ymd(selectedDate)

        if force || dayKey != dayBodyLoadedFor {
            dayBody = db.getDayNote(date: selectedDate)
            dayBodyLoadedFor = dayKey
        }

        let (monthStart, monthEnd) = monthGridRange(selectedDate)
        bodies = db.loadDayNoteRange(start: monthStart, end: monthEnd)

        loadReview()
    }

    func startOfWeek(_ date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return cal.date(from: comps) ?? date
    }

    func monthGridRange(_ date: Date) -> (Date, Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        let comps = cal.dateComponents([.year, .month], from: date)
        let firstOfMonth = cal.date(from: comps) ?? date
        let gridStart = startOfWeek(firstOfMonth)
        if let nextMonth = cal.date(byAdding: .month, value: 1, to: firstOfMonth),
           let lastOfMonth = cal.date(byAdding: .day, value: -1, to: nextMonth) {
            let weekday = cal.component(.weekday, from: lastOfMonth)
            let pad = (8 - weekday) % 7
            let gridEnd = cal.date(byAdding: .day, value: pad, to: lastOfMonth) ?? lastOfMonth
            return (gridStart, gridEnd)
        }
        return (gridStart, gridStart)
    }

    // MARK: - day body editing

    /// Called from the editor on every change (post 200ms JS-side debounce).
    /// Persists immediately — `saveDayNote` is a single INSERT.
    func updateDayBody(_ newValue: String) {
        dayBody = newValue
        db.saveDayNote(date: selectedDate, body: newValue)
        bodies[DayflowDB.ymd(selectedDate)] = newValue
    }

    /// Fast path for external edits (Quick Throw, Week checkbox toggles
    /// for days other than the current one, etc). Updates the in-memory
    /// cache without re-running the month-range SQL query — which a full
    /// `refresh(force:)` would do on every call.
    func applyExternalEdit(date: Date, body: String) {
        let key = DayflowDB.ymd(date)
        if bodies[key] != nil {
            bodies[key] = body
        }
        if Calendar.current.isDate(date, inSameDayAs: selectedDate) {
            dayBody = body
            dayBodyLoadedFor = key
        }
    }

    /// Toggle the Nth *preview-visible* task checkbox for a given day without
    /// leaving the current view. `previewIndex` is the order of the task
    /// within the week-column preview (which may be clipped to 8 lines and
    /// skips any line the parser rejects).
    ///
    /// We walk the body with the same parser the preview uses and map
    /// preview index → source line index, then rewrite that single line's
    /// `[ ]`/`[x]` marker. The rest of the body is left byte-identical.
    func toggleWeekTask(day: Date, previewIndex: Int) {
        let key = DayflowDB.ymd(day)
        let body = bodies[key] ?? db.getDayNote(date: day)
        guard !body.isEmpty else { return }

        // Split preserving line positions so we can splice one line back in.
        var lines = body.components(separatedBy: "\n")
        var previewCount = 0
        var targetLineIdx: Int?

        for (idx, rawLine) in lines.enumerated() {
            if previewCount > 8 { break }
            guard let parsed = MarkdownLine.parse(rawLine) else { continue }
            if case .task = parsed {
                if previewCount == previewIndex {
                    targetLineIdx = idx
                    break
                }
                previewCount += 1
            } else {
                previewCount += 1
            }
        }

        guard let lineIdx = targetLineIdx else { return }
        let toggled = toggleTaskMarker(in: lines[lineIdx])
        guard toggled != lines[lineIdx] else { return }
        lines[lineIdx] = toggled

        let newBody = lines.joined(separator: "\n")
        db.saveDayNote(date: day, body: newBody)
        bodies[key] = newBody

        // If we just toggled today's own note, mirror into `dayBody` so the
        // Day view will show the flipped state next time it becomes active.
        if Calendar.current.isDate(day, inSameDayAs: selectedDate) {
            dayBody = newBody
        }
    }

    /// Flip the `[ ]` ↔ `[x]` marker in a single markdown task line,
    /// preserving indentation, bullet char, and all whitespace.
    private func toggleTaskMarker(in line: String) -> String {
        var chars = Array(line)
        var i = 0
        // skip leading whitespace
        while i < chars.count && (chars[i] == " " || chars[i] == "\t") { i += 1 }
        guard i < chars.count, chars[i] == "-" || chars[i] == "*" || chars[i] == "+" else { return line }
        i += 1
        while i < chars.count && (chars[i] == " " || chars[i] == "\t") { i += 1 }
        guard i + 2 < chars.count, chars[i] == "[" else { return line }
        let markIdx = i + 1
        guard chars[i + 2] == "]" else { return line }
        switch chars[markIdx] {
        case " ":
            chars[markIdx] = "x"
        case "x", "X", "✓":
            chars[markIdx] = " "
        default:
            return line
        }
        return String(chars)
    }

    // MARK: - metric helpers

    func dayCounts(_ date: Date) -> (open: Int, done: Int) {
        DayflowDB.parseCheckboxes(dayBody(for: date))
    }

    func dayBody(for date: Date) -> String {
        bodies[DayflowDB.ymd(date)] ?? ""
    }

    /// Week-wide aggregate counts (open + done across 7 days) for the week
    /// containing `selectedDate`.
    func weekTotals() -> (open: Int, done: Int, trackedDays: Int) {
        let cal = Calendar.current
        let start = startOfWeek(selectedDate)
        var open = 0
        var done = 0
        var tracked = 0
        for offset in 0..<7 {
            guard let day = cal.date(byAdding: .day, value: offset, to: start) else { continue }
            let counts = dayCounts(day)
            if counts.open + counts.done > 0 { tracked += 1 }
            open += counts.open
            done += counts.done
        }
        return (open, done, tracked)
    }

    // MARK: - review

    private func loadReview() {
        reviewBody = db.getReview(date: selectedDate) ?? ""
        reviewError = nil
    }

    func generateReview() {
        let target = selectedDate
        let body = db.getDayNote(date: target)
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let empty = L("llm.review.empty_day")
            reviewBody = empty
            db.saveReview(date: target, body: empty)
            return
        }

        reviewIsLoading = true
        reviewError = nil
        let payload: [String: Any] = [
            "date": DayflowDB.ymd(target),
            "markdown": body,
        ]

        _Concurrency.Task {
            do {
                let result = try await LLMClient.shared.dailyReview(payload: payload)
                await MainActor.run {
                    self.reviewBody = result
                    self.db.saveReview(date: target, body: result)
                    self.reviewIsLoading = false
                }
            } catch {
                await MainActor.run {
                    self.reviewError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    self.reviewIsLoading = false
                }
            }
        }
    }

    // MARK: - month stats

    struct MonthStats {
        var totalTasks: Int
        var doneTasks: Int
        var openTasks: Int
        var completionRate: Double
        var busiestWeekday: String?
        var longestStreak: Int
        var doneByDay: [String: Int]
        var openByDay: [String: Int]
        /// First non-heading line of the day with the most done items.
        var standoutLine: String?
        var standoutDate: String?
    }

    func currentMonthStats() -> MonthStats {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: selectedDate)
        guard let monthStart = cal.date(from: comps),
              let nextMonth = cal.date(byAdding: .month, value: 1, to: monthStart),
              let monthEnd = cal.date(byAdding: .day, value: -1, to: nextMonth) else {
            return MonthStats(totalTasks: 0, doneTasks: 0, openTasks: 0, completionRate: 0,
                              busiestWeekday: nil, longestStreak: 0, doneByDay: [:], openByDay: [:],
                              standoutLine: nil, standoutDate: nil)
        }

        var doneByDay: [String: Int] = [:]
        var openByDay: [String: Int] = [:]
        var totalDone = 0
        var totalOpen = 0

        var cursor = monthStart
        while cursor <= monthEnd {
            let key = DayflowDB.ymd(cursor)
            let body = bodies[key] ?? ""
            let counts = DayflowDB.parseCheckboxes(body)
            doneByDay[key] = counts.done
            openByDay[key] = counts.open
            totalDone += counts.done
            totalOpen += counts.open
            cursor = cal.date(byAdding: .day, value: 1, to: cursor) ?? cursor
        }

        let weekdays = ["일", "월", "화", "수", "목", "금", "토"]
        var weekdayCounts: [Int: Int] = [:]
        for (key, count) in doneByDay where count > 0 {
            if let d = DF.ymd.date(from: key) {
                let wd = cal.component(.weekday, from: d)
                weekdayCounts[wd, default: 0] += count
            }
        }
        let busiestKey = weekdayCounts.max { $0.value < $1.value }?.key
        let busiest = busiestKey.flatMap { weekdays[safe: $0 - 1] }

        var streak = 0
        var maxStreak = 0
        cursor = monthStart
        while cursor <= monthEnd {
            let key = DayflowDB.ymd(cursor)
            if (doneByDay[key] ?? 0) > 0 {
                streak += 1
                maxStreak = max(maxStreak, streak)
            } else {
                streak = 0
            }
            cursor = cal.date(byAdding: .day, value: 1, to: cursor) ?? cursor
        }

        // Standout day: most done items this month. Tie-breaker: most recent.
        var standoutKey: String?
        var standoutCount = 0
        for (key, count) in doneByDay {
            if count > standoutCount || (count == standoutCount && (key > (standoutKey ?? ""))) {
                standoutKey = key
                standoutCount = count
            }
        }
        var standoutLine: String?
        if let key = standoutKey, standoutCount > 0 {
            standoutLine = firstMeaningfulLine(bodies[key] ?? "")
        }

        let total = totalDone + totalOpen
        return MonthStats(
            totalTasks: total,
            doneTasks: totalDone,
            openTasks: totalOpen,
            completionRate: total == 0 ? 0 : Double(totalDone) / Double(total),
            busiestWeekday: busiest,
            longestStreak: maxStreak,
            doneByDay: doneByDay,
            openByDay: openByDay,
            standoutLine: standoutLine,
            standoutDate: standoutKey
        )
    }

    /// Return the first line of real content — headings are skipped because
    /// they identify a section, not the work the user actually did.
    private func firstMeaningfulLine(_ body: String) -> String? {
        for raw in body.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            guard let line = MarkdownLine.parse(String(raw)) else { continue }
            switch line {
            case .heading: continue
            case .task(_, let text), .bullet(let text), .plain(let text):
                if !text.isEmpty { return text }
            }
        }
        return nil
    }
}
