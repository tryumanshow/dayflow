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

@MainActor
@Observable
final class DayflowStore {
    // navigation
    var viewMode: CalendarViewMode = .day
    var selectedDate: Date = Calendar.current.startOfDay(for: Date())

    // current page data
    var dayTasks: [Task] = []
    var weekTasks: [Task] = []          // 7-day window
    var monthTasks: [Task] = []         // calendar-month window (with leading/trailing rows)

    // selection within day view
    var selectedTaskId: Int?
    var notes: [Note] = []
    var history: [StateChange] = []

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
        // Poll the DB so external changes (Python repo, future hotkey) show up.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    // MARK: - menu bar text

    var menuBarText: String {
        let doing = dayTasks.first { $0.status == .doing }
        if let d = doing {
            let cap = String(d.title.prefix(28))
            return "▶ \(cap)"
        }
        let todoCount = dayTasks.filter { $0.status == .todo }.count
        if todoCount == 0 { return "🌱 dayflow" }
        return "📋 \(todoCount)"
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

        // day window — for menubar text and selection
        dayTasks = db.listForDate(selectedDate)

        // week window
        let weekStart = startOfWeek(selectedDate)
        let weekEnd = cal.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        weekTasks = db.listForRange(start: weekStart, end: weekEnd)

        // month window (with full grid: leading days from prev month + trailing from next)
        let (monthStart, monthEnd) = monthGridRange(selectedDate)
        monthTasks = db.listForRange(start: monthStart, end: monthEnd)

        // sync selection
        if let id = selectedTaskId, !dayTasks.contains(where: { $0.id == id }) {
            selectedTaskId = nil
        }
        if selectedTaskId == nil {
            selectedTaskId = dayTasks.first?.id
        }
        reloadDetail()
        loadMonthPlanIfNeeded()
        loadReview()
    }

    func startOfWeek(_ date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2 // Monday
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return cal.date(from: comps) ?? date
    }

    /// Returns the first day shown on the month grid (a Monday on or before the
    /// 1st of the month) and the last day (a Sunday on or after the last day).
    func monthGridRange(_ date: Date) -> (Date, Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        let comps = cal.dateComponents([.year, .month], from: date)
        let firstOfMonth = cal.date(from: comps) ?? date
        let gridStart = startOfWeek(firstOfMonth)

        // last day of the month
        if let nextMonth = cal.date(byAdding: .month, value: 1, to: firstOfMonth),
           let lastOfMonth = cal.date(byAdding: .day, value: -1, to: nextMonth) {
            // pad to Sunday after lastOfMonth
            let weekday = cal.component(.weekday, from: lastOfMonth) // 1=Sun..7=Sat
            // we want Sunday: weekday == 1
            let pad = (8 - weekday) % 7
            let gridEnd = cal.date(byAdding: .day, value: pad, to: lastOfMonth) ?? lastOfMonth
            return (gridStart, gridEnd)
        }
        return (gridStart, gridStart)
    }

    // MARK: - task ops

    func addTask(title: String, dueDate: Date) {
        guard let task = db.addTask(title: title, dueDate: dueDate) else { return }
        refresh()
        if Calendar.current.isDate(dueDate, inSameDayAs: selectedDate) {
            selectedTaskId = task.id
            reloadDetail()
        }
    }

    func cycleStatus(_ taskId: Int) {
        guard let t = dayTasks.first(where: { $0.id == taskId })
            ?? weekTasks.first(where: { $0.id == taskId })
            ?? monthTasks.first(where: { $0.id == taskId }) else { return }
        db.changeStatus(taskId: taskId, to: t.status.nextInCycle)
        refresh()
    }

    func setStatus(_ taskId: Int, to status: TaskStatus) {
        db.changeStatus(taskId: taskId, to: status)
        refresh()
    }

    func setDueDate(_ taskId: Int, to date: Date?) {
        db.setDueDate(taskId, to: date)
        refresh()
    }

    func deleteTask(_ taskId: Int) {
        db.deleteTask(taskId)
        if selectedTaskId == taskId { selectedTaskId = nil }
        refresh()
    }

    func select(_ taskId: Int) {
        selectedTaskId = taskId
        reloadDetail()
    }

    func addNote(_ body: String) {
        guard let id = selectedTaskId else { return }
        db.addNote(taskId: id, body: body)
        reloadDetail()
    }

    private func reloadDetail() {
        guard let id = selectedTaskId else {
            notes = []
            history = []
            return
        }
        notes = db.listNotes(taskId: id)
        history = db.listStateHistory(taskId: id)
    }

    var selectedTask: Task? {
        guard let id = selectedTaskId else { return nil }
        return dayTasks.first(where: { $0.id == id })
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
            let empty = "오늘은 던진 task 가 하나도 없어. 내일은 한 줄이라도 throw 해보자."
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
}
