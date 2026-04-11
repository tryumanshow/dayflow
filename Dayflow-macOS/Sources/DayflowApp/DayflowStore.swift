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
    // navigation
    var viewMode: CalendarViewMode = .day
    var selectedDate: Date = Calendar.current.startOfDay(for: Date())

    // markdown body for the current day
    var dayBody: String = ""
    private var dayBodyLoadedFor: String = ""

    // bulk markdown bodies for week/month views
    var weekBodies: [String: String] = [:]
    var monthBodies: [String: String] = [:]

    // monthly plan editor
    var monthPlanBody: String = ""
    private var monthPlanLoadedFor: String = ""

    // daily review
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
        if counts.open == 0 && counts.done == 0 { return "🌱 dayflow" }
        if counts.open == 0 { return "✓ done" }
        return "📋 \(counts.open)"
    }

    // MARK: - navigation

    func goToToday() {
        commitDayBodyIfDirty()
        selectedDate = Calendar.current.startOfDay(for: Date())
        refresh(force: true)
    }

    func step(by direction: Int) {
        commitDayBodyIfDirty()
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
        commitDayBodyIfDirty()
        viewMode = mode
        refresh(force: true)
    }

    func selectDate(_ date: Date) {
        commitDayBodyIfDirty()
        selectedDate = Calendar.current.startOfDay(for: date)
        refresh(force: true)
    }

    // MARK: - refresh

    func refresh(force: Bool = false) {
        let cal = Calendar.current
        let dayKey = DayflowDB.ymd(selectedDate)

        // load day body if changed
        if force || dayKey != dayBodyLoadedFor {
            dayBody = db.getDayNote(date: selectedDate)
            dayBodyLoadedFor = dayKey
        }

        // bulk load week + month markdown bodies for metrics
        let weekStart = startOfWeek(selectedDate)
        let weekEnd = cal.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        weekBodies = db.loadDayNoteRange(start: weekStart, end: weekEnd)

        let (monthStart, monthEnd) = monthGridRange(selectedDate)
        monthBodies = db.loadDayNoteRange(start: monthStart, end: monthEnd)

        loadMonthPlanIfNeeded()
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

    /// Called from the editor on every change. Persists immediately —
    /// `saveDayNote` is one INSERT, fast enough to fire on each keystroke.
    func updateDayBody(_ newValue: String) {
        dayBody = newValue
        db.saveDayNote(date: selectedDate, body: newValue)
        // mirror to weekly/monthly cache so cells refresh in real time
        let key = DayflowDB.ymd(selectedDate)
        weekBodies[key] = newValue
        monthBodies[key] = newValue
    }

    private func commitDayBodyIfDirty() {
        // updateDayBody already persists eagerly; this is a no-op safety net
        // for navigation away from a day with unflushed changes.
        db.saveDayNote(date: selectedDate, body: dayBody)
    }

    // MARK: - metric helpers (for week/month views)

    func dayCounts(_ date: Date) -> (open: Int, done: Int) {
        let key = DayflowDB.ymd(date)
        let body = monthBodies[key] ?? weekBodies[key] ?? ""
        return DayflowDB.parseCheckboxes(body)
    }

    // MARK: - month plan

    private func loadMonthPlanIfNeeded() {
        let ym = DayflowDB.ym(selectedDate)
        if ym != monthPlanLoadedFor {
            monthPlanBody = db.getMonthPlan(yearMonth: ym)
            monthPlanLoadedFor = ym
        }
    }

    func saveMonthPlan() {
        let ym = DayflowDB.ym(selectedDate)
        db.saveMonthPlan(yearMonth: ym, body: monthPlanBody)
        monthPlanLoadedFor = ym
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
            let empty = "오늘은 적어둔 게 하나도 없어. 내일은 한 줄이라도 적어보자."
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
                let result = try await AnthropicClient.shared.dailyReview(payload: payload)
                await MainActor.run {
                    self.reviewBody = result
                    self.db.saveReview(date: target, body: result)
                    self.reviewIsLoading = false
                }
            } catch {
                await MainActor.run {
                    self.reviewError = "\(error)"
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
    }

    func currentMonthStats() -> MonthStats {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: selectedDate)
        guard let monthStart = cal.date(from: comps),
              let nextMonth = cal.date(byAdding: .month, value: 1, to: monthStart),
              let monthEnd = cal.date(byAdding: .day, value: -1, to: nextMonth) else {
            return MonthStats(totalTasks: 0, doneTasks: 0, openTasks: 0, completionRate: 0,
                              busiestWeekday: nil, longestStreak: 0, doneByDay: [:], openByDay: [:])
        }

        var doneByDay: [String: Int] = [:]
        var openByDay: [String: Int] = [:]
        var totalDone = 0
        var totalOpen = 0

        var cursor = monthStart
        while cursor <= monthEnd {
            let key = DayflowDB.ymd(cursor)
            let body = monthBodies[key] ?? ""
            let counts = DayflowDB.parseCheckboxes(body)
            doneByDay[key] = counts.done
            openByDay[key] = counts.open
            totalDone += counts.done
            totalOpen += counts.open
            cursor = cal.date(byAdding: .day, value: 1, to: cursor) ?? cursor
        }

        let weekdays = ["일", "월", "화", "수", "목", "금", "토"]
        var weekdayCounts: [Int: Int] = [:]
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        for (key, count) in doneByDay where count > 0 {
            if let d = f.date(from: key) {
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

        let total = totalDone + totalOpen
        return MonthStats(
            totalTasks: total,
            doneTasks: totalDone,
            openTasks: totalOpen,
            completionRate: total == 0 ? 0 : Double(totalDone) / Double(total),
            busiestWeekday: busiest,
            longestStreak: maxStreak,
            doneByDay: doneByDay,
            openByDay: openByDay
        )
    }
}
