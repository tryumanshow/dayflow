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

    // current page data
    var dayTasks: [Task] = []
    var weekTasks: [Task] = []
    var monthTasks: [Task] = []

    // outline editor focus + draft (id 0 = the trailing blank row)
    var focusedTaskId: Int? = nil
    var draftTitles: [Int: String] = [:]

    // monthly plan editor
    var monthPlanBody: String = ""
    private var monthPlanLoadedFor: String = ""

    // daily review
    var reviewBody: String = ""
    var reviewIsLoading: Bool = false
    var reviewError: String?

    private let db = DayflowDB.shared
    private var refreshTimer: Timer?

    init() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    // MARK: - menubar

    var menuBarText: String {
        let openCount = dayTasks.filter { !$0.status.isDone }.count
        if openCount == 0 { return "🌱 dayflow" }
        return "📋 \(openCount)"
    }

    // MARK: - navigation

    func goToToday() {
        selectedDate = Calendar.current.startOfDay(for: Date())
        refresh()
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
            refresh()
        }
    }

    func setMode(_ mode: CalendarViewMode) {
        viewMode = mode
        refresh()
    }

    // MARK: - refresh

    func refresh() {
        let cal = Calendar.current

        dayTasks = db.listForDate(selectedDate)

        let weekStart = startOfWeek(selectedDate)
        let weekEnd = cal.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        weekTasks = db.listForRange(start: weekStart, end: weekEnd)

        let (monthStart, monthEnd) = monthGridRange(selectedDate)
        monthTasks = db.listForRange(start: monthStart, end: monthEnd)

        // sync any draft titles to live values for tasks that exist
        for t in dayTasks where draftTitles[t.id] == nil {
            draftTitles[t.id] = t.title
        }
        // drop drafts for tasks that no longer exist on this day
        for id in Array(draftTitles.keys) {
            if id != 0 && !dayTasks.contains(where: { $0.id == id }) {
                draftTitles.removeValue(forKey: id)
            }
        }

        loadMonthPlanIfNeeded()
        loadReview()
    }

    func startOfWeek(_ date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2 // Monday
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

    // MARK: - outline traversal

    /// Recursive flatten — sub-tasks immediately follow their parent at the
    /// next depth. Orphans (parent not in current day) appear at root.
    var orderedDayRows: [(task: Task, depth: Int)] {
        let tasks = dayTasks
        let presentIds = Set(tasks.map { $0.id })
        var out: [(Task, Int)] = []

        func walk(parent: Int?, depth: Int) {
            let children = tasks
                .filter { $0.parentId == parent }
                .sorted { $0.id < $1.id }
            for c in children {
                out.append((c, depth))
                walk(parent: c.id, depth: depth + 1)
            }
        }
        walk(parent: nil, depth: 0)
        // orphans whose parent is not in the day's set
        let orphans = tasks.filter { t in
            guard let pid = t.parentId else { return false }
            return !presentIds.contains(pid) && !out.contains(where: { $0.0.id == t.id })
        }
        for o in orphans {
            out.append((o, 0))
            walk(parent: o.id, depth: 1)
        }
        return out
    }

    private func depth(of task: Task) -> Int {
        var d = 0
        var current = task.parentId
        while let pid = current {
            d += 1
            current = dayTasks.first { $0.id == pid }?.parentId
        }
        return d
    }

    // MARK: - task ops (outline)

    /// Append a brand new top-level row in the current day.
    @discardableResult
    func newRow(after taskId: Int? = nil, asChildOf parentId: Int? = nil) -> Int? {
        guard let task = db.addTask(title: "", dueDate: selectedDate, parentId: parentId) else { return nil }
        refresh()
        draftTitles[task.id] = ""
        focusedTaskId = task.id
        return task.id
    }

    /// Indent: make the row a child of its previous sibling.
    func indent(_ taskId: Int) {
        let rows = orderedDayRows
        guard let idx = rows.firstIndex(where: { $0.task.id == taskId }), idx > 0 else { return }
        let me = rows[idx]
        // find the closest previous row at the same depth — that becomes the new parent
        var newParent: Task?
        for j in stride(from: idx - 1, through: 0, by: -1) {
            if rows[j].depth == me.depth {
                newParent = rows[j].task
                break
            }
            if rows[j].depth < me.depth { break }
        }
        guard let parent = newParent else { return }
        db.setParent(taskId, parentId: parent.id)
        refresh()
        focusedTaskId = taskId
    }

    /// Outdent: promote the row to its parent's level.
    func outdent(_ taskId: Int) {
        guard let me = dayTasks.first(where: { $0.id == taskId }), let pid = me.parentId else { return }
        let parent = dayTasks.first { $0.id == pid }
        db.setParent(taskId, parentId: parent?.parentId)
        refresh()
        focusedTaskId = taskId
    }

    func commitTitle(_ taskId: Int) {
        let title = draftTitles[taskId] ?? ""
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // empty rows are allowed visually but DB persists empty title
            db.updateTitle(taskId, title: "")
            return
        }
        db.updateTitle(taskId, title: trimmed)
    }

    /// Backspace on empty row → delete and move focus to previous row.
    func backspaceEmpty(_ taskId: Int) {
        let title = draftTitles[taskId] ?? ""
        guard title.isEmpty else { return }
        let rows = orderedDayRows
        guard let idx = rows.firstIndex(where: { $0.task.id == taskId }) else { return }
        let prev = idx > 0 ? rows[idx - 1].task.id : nil
        db.deleteTask(taskId)
        draftTitles.removeValue(forKey: taskId)
        refresh()
        focusedTaskId = prev
    }

    func toggleDone(_ taskId: Int) {
        db.toggleDone(taskId)
        refresh()
    }

    func deleteTask(_ taskId: Int) {
        db.deleteTask(taskId)
        draftTitles.removeValue(forKey: taskId)
        refresh()
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
        let snapshot = db.listForDate(target).map { task -> [String: Any] in
            let history = db.listStateHistory(taskId: task.id).map { h -> [String: Any] in
                return [
                    "from": h.fromStatus ?? "",
                    "to": h.toStatus,
                    "at": h.changedAt,
                ]
            }
            let notes = db.listNotes(taskId: task.id).map { $0.bodyMd }
            return [
                "id": task.id,
                "title": task.title,
                "status": task.status.rawValue,
                "transitions": history,
                "notes": notes,
            ]
        }
        if snapshot.isEmpty {
            let empty = "오늘은 적어둔 게 하나도 없어. 내일은 한 줄이라도 적어보자."
            reviewBody = empty
            db.saveReview(date: target, body: empty)
            return
        }

        reviewIsLoading = true
        reviewError = nil
        let payload: [String: Any] = [
            "date": DayflowDB.ymd(target),
            "tasks": snapshot,
        ]

        _Concurrency.Task {
            do {
                let body = try await AnthropicClient.shared.dailyReview(payload: payload)
                await MainActor.run {
                    self.reviewBody = body
                    self.db.saveReview(date: target, body: body)
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
        var doneByDay: [String: Int]   // YYYY-MM-DD → done count
        var totalByDay: [String: Int]  // YYYY-MM-DD → total count
    }

    func currentMonthStats() -> MonthStats {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: selectedDate)
        guard let monthStart = cal.date(from: comps),
              let nextMonth = cal.date(byAdding: .month, value: 1, to: monthStart),
              let monthEnd = cal.date(byAdding: .day, value: -1, to: nextMonth) else {
            return MonthStats(totalTasks: 0, doneTasks: 0, openTasks: 0, completionRate: 0,
                              busiestWeekday: nil, longestStreak: 0, doneByDay: [:], totalByDay: [:])
        }
        let tasks = db.listForRange(start: monthStart, end: monthEnd)
        let done = tasks.filter { $0.status == .done }
        let openCount = tasks.filter { $0.status == .todo }.count

        var doneByDay: [String: Int] = [:]
        var totalByDay: [String: Int] = [:]
        for t in tasks {
            let day = t.dueDate ?? String(t.inboxAt.prefix(10))
            totalByDay[day, default: 0] += 1
            if t.status == .done { doneByDay[day, default: 0] += 1 }
        }

        let weekdays = ["일", "월", "화", "수", "목", "금", "토"]
        var weekdayCounts: [Int: Int] = [:]
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        for t in done {
            let dayStr = t.dueDate ?? String(t.inboxAt.prefix(10))
            if let d = f.date(from: dayStr) {
                let wd = cal.component(.weekday, from: d)
                weekdayCounts[wd, default: 0] += 1
            }
        }
        let busiestKey = weekdayCounts.max { $0.value < $1.value }?.key
        let busiest = busiestKey.flatMap { weekdays[safe: $0 - 1] }

        var streak = 0
        var maxStreak = 0
        var cursor = monthStart
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

        return MonthStats(
            totalTasks: tasks.count,
            doneTasks: done.count,
            openTasks: openCount,
            completionRate: tasks.isEmpty ? 0 : Double(done.count) / Double(tasks.count),
            busiestWeekday: busiest,
            longestStreak: maxStreak,
            doneByDay: doneByDay,
            totalByDay: totalByDay
        )
    }

    func dayMetrics(_ date: Date) -> (total: Int, done: Int, ratio: Double) {
        let target = DayflowDB.ymd(date)
        let tasks = monthTasks.filter { t in
            if let due = t.dueDate { return due == target }
            return String(t.inboxAt.prefix(10)) == target
        }
        let done = tasks.filter { $0.status == .done }.count
        let total = tasks.count
        return (total, done, total == 0 ? 0 : Double(done) / Double(total))
    }
}
