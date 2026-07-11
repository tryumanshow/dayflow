import Foundation
import Observation

enum CalendarViewMode: String, CaseIterable, Identifiable {
    case day, week, month
    var id: String { rawValue }
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
    /// BlockNote document tree for the selected day, as JSON. Carries
    /// styles that raw markdown can't (text/background color, underline).
    /// Nil for days that were last written by a markdown-only path
    /// (QuickThrow, Week checkbox toggle) — the editor will rebuild blocks
    /// from `dayBody` in that case.
    var dayBodyJSON: String? = nil
    var dayBodyLoadedFor: String = ""

    /// Markdown bodies keyed by `yyyy-MM-dd`, covering the month-grid range
    /// (which always subsumes the 7-day week range) for the current
    /// selected date. Both week and month views read from here.
    var bodies: [String: String] = [:]

    var reviewBody: String = ""
    var reviewIsLoading: Bool = false
    var reviewError: String?

    /// Per-month TODO list split into user-defined sections (Career,
    /// Finance, etc.). Lives in `month_plan_sections` keyed by `yyyy-MM`.
    var monthPlanSections: [MonthPlanSection] = []
    var monthPlanLoadedFor: String = ""

    /// Appointments keyed by `yyyy-MM-dd`, covering the same
    /// month-grid range as `bodies`. Week / Month / Day rails all
    /// read from this cache instead of re-querying per render.
    var appointmentsByDay: [String: [Appointment]] = [:]

    /// Month-grid range last loaded into `bodies` /
    /// `appointmentsByDay`. Used to skip the SQL round-trip when
    /// the user navigates within the same month.
    var monthRangeLoadedFor: String = ""

    let db: DayflowDB

    /// The app always runs on `DayflowDB.shared`. The parameter exists so
    /// tests can drive a store against a throwaway DB — without it they'd
    /// read and (for carry-over, which deletes lines) *write* the real
    /// notes in `~/Library/Application Support`.
    init(db: DayflowDB = .shared) {
        self.db = db
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

    // Navigation calls let `refresh()` decide what to reload via
    // its per-section guards (day key, month-plan key, month-range
    // key). We only force a full reload on the explicit refresh
    // button in the nav bar.
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
        guard viewMode != mode else { return }
        viewMode = mode
        refresh()
    }

    func selectDate(_ date: Date) {
        selectedDate = Calendar.current.startOfDay(for: date)
        refresh()
    }

    // MARK: - refresh

    func refresh(force: Bool = false) {
        let dayKey = DayflowDB.ymd(selectedDate)

        if force || dayKey != dayBodyLoadedFor {
            let full = db.getDayNoteFull(date: selectedDate)
            setDayBuffers(md: full.body, json: full.bodyJSON, cacheKey: dayKey)
        }

        let monthKey = DayflowDB.monthKey(selectedDate)
        if force || monthKey != monthPlanLoadedFor {
            monthPlanSections = db.getMonthPlanSections(date: selectedDate)
            monthPlanLoadedFor = monthKey
        }

        // Month-grid range is shared by `bodies` (day notes) and
        // `appointmentsByDay` (appointments). Skip both reloads when
        // the user navigates within the same month — the in-memory
        // caches already cover every day on the grid.
        let (monthStart, monthEnd) = monthGridRange(selectedDate)
        let rangeKey = "\(DayflowDB.ymd(monthStart))..\(DayflowDB.ymd(monthEnd))"
        if force || rangeKey != monthRangeLoadedFor {
            bodies = db.loadDayNoteRange(start: monthStart, end: monthEnd)
            reloadAppointments()
            monthRangeLoadedFor = rangeKey
        }

        loadReview()
    }

    func reloadAppointments() {
        let (start, end) = monthGridRange(selectedDate)
        let items = db.getAppointments(start: start, end: end)
        var byDay: [String: [Appointment]] = [:]
        for apt in items {
            let key = DayflowDB.ymd(apt.startAt)
            byDay[key, default: []].append(apt)
        }
        // Equality guard so a reload that produced the same result
        // doesn't fire `@Observable` invalidations across every view
        // bound to `appointmentsByDay`.
        if byDay != appointmentsByDay {
            appointmentsByDay = byDay
        }
        // Every appointment mutation funnels through here, so this is the one
        // place the pending reminders have to be rebuilt. It's a no-op unless
        // the user opted in.
        if NotificationPreference.enabled {
            Task { await AppointmentNotifier.shared.rescheduleAll() }
        }
    }

    /// Single point of assignment for the three buffers that always move
    /// together: the in-memory markdown, the in-memory JSON sidecar, and
    /// the "which day is the editor showing" key. Callers that have JSON
    /// pass it; markdown-only paths (QuickThrow, Week toggle) pass nil to
    /// invalidate rich styles for that day.
    func setDayBuffers(md: String, json: String?, cacheKey: String) {
        dayBody = md
        dayBodyJSON = json
        dayBodyLoadedFor = cacheKey
    }

    /// Sunday-first Gregorian calendar reused by every layout helper
    /// that walks weeks/months, so we don't re-initialise a `Calendar`
    /// on every render tick.
    private static let gregorian: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 1
        return c
    }()

    func startOfWeek(_ date: Date) -> Date {
        let cal = Self.gregorian
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return cal.date(from: comps) ?? date
    }

    func monthGridRange(_ date: Date) -> (Date, Date) {
        let cal = Self.gregorian
        let comps = cal.dateComponents([.year, .month], from: date)
        let firstOfMonth = cal.date(from: comps) ?? date
        let gridStart = startOfWeek(firstOfMonth)
        if let nextMonth = cal.date(byAdding: .month, value: 1, to: firstOfMonth),
           let lastOfMonth = cal.date(byAdding: .day, value: -1, to: nextMonth) {
            // Weekday is 1..7 with Sun=1 in a Sunday-first calendar;
            // pad out to the following Saturday.
            let weekday = cal.component(.weekday, from: lastOfMonth)
            let pad = (7 - weekday) % 7
            let gridEnd = cal.date(byAdding: .day, value: pad, to: lastOfMonth) ?? lastOfMonth
            return (gridStart, gridEnd)
        }
        return (gridStart, gridStart)
    }

    // MARK: - day body editing

    /// Called from the editor on every change (post 200ms JS-side debounce).
    /// `bodyJSON` is the BlockNote-native tree carrying rich styles; `body`
    /// is the lossy markdown used by Week/Month parsers.
    func updateDayBody(_ newValue: String, bodyJSON: String? = nil) {
        let key = dayBodyLoadedFor  // already == ymd(selectedDate) on the edit hot path
        setDayBuffers(md: newValue, json: bodyJSON, cacheKey: key)
        db.saveDayNote(date: selectedDate, body: newValue, bodyJSON: bodyJSON)
        bodies[key] = newValue
    }

}
