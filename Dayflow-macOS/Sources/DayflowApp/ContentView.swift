import SwiftUI
import AppKit

// Native AppKit resize handle. SwiftUI DragGesture next to a WKWebView sibling
// is unreliable on macOS — hover fires but mouseDown/drag events can get lost.
// Using an NSView with explicit mouseDown/mouseDragged + cursor rect is rock
// solid.
struct HorizontalResizeHandle: NSViewRepresentable {
    var onDrag: (CGFloat) -> Void
    var onEnd: () -> Void

    final class HandleView: NSView {
        var onDrag: ((CGFloat) -> Void)?
        var onEnd: (() -> Void)?
        private var lastX: CGFloat = 0
        private var trackingArea: NSTrackingArea?

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let t = trackingArea { removeTrackingArea(t) }
            let t = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .cursorUpdate, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(t)
            trackingArea = t
        }
        override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
        override func mouseEntered(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
        override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.separatorColor.withAlphaComponent(0.5).setFill()
            let line = NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height)
            line.fill()
        }

        override func mouseDown(with event: NSEvent) {
            lastX = event.locationInWindow.x
        }
        override func mouseDragged(with event: NSEvent) {
            let x = event.locationInWindow.x
            onDrag?(x - lastX)
            lastX = x
        }
        override func mouseUp(with event: NSEvent) { onEnd?() }
    }

    func makeNSView(context: Context) -> HandleView {
        let v = HandleView()
        v.onDrag = onDrag
        v.onEnd = onEnd
        return v
    }
    func updateNSView(_ nsView: HandleView, context: Context) {
        nsView.onDrag = onDrag
        nsView.onEnd = onEnd
    }
}

// MARK: - Days badge (nav bar, right side) ------------------------------------

private struct DaysBadgeView: View {
    let startDateEpoch: Double

    @State private var isHovering = false

    private static let sinceFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    var body: some View {
        let days = max(0, Calendar.current.dateComponents(
            [.day],
            from: Date(timeIntervalSince1970: startDateEpoch),
            to: Date()
        ).day ?? 0)
        let isMilestone = ContentView.milestones.contains(days)
        let label = isHovering
            ? "\(days) days with Dayflow"
            : "Dayflow since \(Self.sinceFormatter.string(from: Date(timeIntervalSince1970: startDateEpoch)))"

        Text(label)
            .font(.system(size: 11, weight: isMilestone ? .semibold : .medium, design: .rounded))
            .foregroundStyle(isMilestone ? AnyShapeStyle(Color.dfAccent) : AnyShapeStyle(.tertiary))
            .contentTransition(.opacity)
            .animation(DS.Motion.settle, value: isHovering)
            .onHover { isHovering = $0 }
    }
}

@MainActor
struct ContentView: View {
    @Environment(DayflowStore.self) private var store

    // Month rail appointment form. Doubles as the add form and the
    // edit form — `editingAppointmentId` being non-nil flips the
    // submit button label and routes to `updateAppointment`.
    @State private var aptTimeInput: String = ""
    @State private var aptEndTimeInput: String = ""
    @State private var aptTitleInput: String = ""
    @State private var aptDateInput: Date = Date()
    @State private var aptCategoryInput: AppointmentCategory = .event
    @State private var editingAppointmentId: Int64? = nil
    @FocusState private var aptTitleFocused: Bool

    // Day view and Month plan editor sizes live-update independently
    // via AppStorage. Shared keys/defaults in `AppStorageKeys`.
    @AppStorage(AppStorageKeys.dayEditorFontSize) private var dayEditorFontSize: Double = AppStorageKeys.dayEditorFontSizeDefault
    @AppStorage(AppStorageKeys.monthPlanEditorFontSize) private var monthPlanEditorFontSize: Double = AppStorageKeys.monthPlanEditorFontSizeDefault
    @AppStorage(AppStorageKeys.holidaysMode) private var holidaysMode: HolidayDisplayMode = .off
    @AppStorage(AppStorageKeys.startDate) private var startDateEpoch: Double = 0
    @State private var sideRailWidth: CGFloat = 340
    @State private var sideRailDragStart: CGFloat? = nil

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            content
                .animation(DS.Motion.settle, value: store.viewMode)
                .transition(.opacity)
        }
        .background(Color.dfCanvas)
        .frame(minWidth: 600, minHeight: 500)
    }

    // MARK: - navigation bar -------------------------------------------------

    private var navigationBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.lg) {
            HStack(spacing: 8) {
                DayflowLogo(size: 18)
                Text("Dayflow")
                    .font(.system(size: 17, weight: .bold))
                    .tracking(-0.3)
            }

            Divider().frame(height: 16)

            HStack(spacing: 2) {
                ForEach(CalendarViewMode.allCases) { mode in
                    Button {
                        store.setMode(mode)
                    } label: {
                        Text(L("nav.\(mode.rawValue)"))
                            .font(.system(size: 12, weight: store.viewMode == mode ? .semibold : .regular))
                            .foregroundStyle(store.viewMode == mode ? Color.primary : Color.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: DS.Radius.sm)
                                    .fill(store.viewMode == mode ? Color.white.opacity(0.08) : .clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider().frame(height: 16)

            HStack(spacing: 6) {
                navIconButton("chevron.left") { store.step(by: -1) }
                Button {
                    store.goToToday()
                } label: {
                    Text(L("nav.today"))
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(Color.white.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                navIconButton("chevron.right") { store.step(by: 1) }
            }

            Text(headerLabel)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)

            Spacer()

            if startDateEpoch > 0 {
                daysBadge
            }

            navIconButton("arrow.clockwise") { store.refresh(force: true) }
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.md)
        .background(Color.dfCanvas)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dfHairline).frame(height: 0.7)
        }
    }

    fileprivate static let milestones: Set<Int> = [7, 30, 50, 100, 200, 365, 500, 730, 1000]

    private var daysBadge: some View {
        DaysBadgeView(startDateEpoch: startDateEpoch)
    }

    private func navIconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.sm)
                        .fill(Color.white.opacity(0.04))
                )
        }
        .buttonStyle(.plain)
    }

    private var headerLabel: String {
        switch store.viewMode {
        case .day:
            let base = DF.fullDate.string(from: store.selectedDate)
            guard let name = HolidayStore.holidayName(on: store.selectedDate, mode: holidaysMode) else { return base }
            return "\(base) · \(name)"
        case .week:
            let start = store.startOfWeek(store.selectedDate)
            let end = Calendar.current.date(byAdding: .day, value: 6, to: start) ?? start
            return "\(DF.shortMonthDay.string(from: start)) – \(DF.shortMonthDay.string(from: end))"
        case .month:
            return DF.monthTitle.string(from: store.selectedDate)
        }
    }

    // MARK: - content router --------------------------------------------------

    @ViewBuilder
    private var content: some View {
        switch store.viewMode {
        case .day:   dayView
        case .week:  weekView
        case .month: monthView
        }
    }

    // MARK: - day view (asymmetric: editor left, small rail right) ----------

    private var dayView: some View {
        @Bindable var store = store
        return HStack(alignment: .top, spacing: 0) {
            MarkdownWebEditor(
                markdown: $store.dayBody,
                markdownJSON: $store.dayBodyJSON,
                fontSize: dayEditorFontSize,
                onChange: { newMD, newJSON in
                    store.updateDayBody(newMD, bodyJSON: newJSON)
                }
            )
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, DS.Space.lg)
            .padding(.top, DS.Space.breathe)
            .padding(.bottom, DS.Space.lg)
            .layoutPriority(1)

            // Draggable divider between editor and side rail (AppKit-backed).
            HorizontalResizeHandle(
                onDrag: { dx in
                    sideRailWidth = max(220, min(500, sideRailWidth - dx))
                },
                onEnd: { }
            )
            .frame(minWidth: 10, maxWidth: 10, maxHeight: .infinity)

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.breathe) {
                        daySummaryRail
                        appointmentsRail
                        reviewRail
                    }
                    .padding(.horizontal, DS.Space.xl)
                    .padding(.top, DS.Space.breathe)
                    .padding(.bottom, DS.Space.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                appCredit
            }
            .frame(minWidth: 220, maxWidth: sideRailWidth)
            .frame(maxHeight: .infinity)
            .background(Color.dfQuiet)
        }
    }

    /// Tiny attribution line shown at the bottom of the side rails. Kept in
    /// `micro` mono font with tertiary opacity so it sits quietly and never
    /// competes with rail content.
    private var appCredit: some View {
        HStack(spacing: 0) {
            Text("Dayflow · by ")
                .foregroundStyle(.tertiary)
            Text("tryumanshow")
                .foregroundStyle(.secondary)
        }
        .font(DS.FontStyle.micro)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.md)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.dfHairline).frame(height: 0.7)
        }
    }

    private var daySummaryRail: some View {
        let counts = DayflowDB.parseCheckboxes(store.dayBody)
        let total = counts.open + counts.done
        let ratio = total == 0 ? 0.0 : Double(counts.done) / Double(total)
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            SectionLabel(text: L("day.today_progress"))
            HStack(alignment: .bottom, spacing: 4) {
                Text("\(Int(ratio * 100))")
                    .font(DS.FontStyle.metric)
                    .foregroundStyle(Color.dfAccent)
                Text("%")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
            }
            if total > 0 {
                Text(L("day.done_open_format", counts.done, counts.open))
                    .font(DS.FontStyle.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(L("day.empty"))
                    .font(DS.FontStyle.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Day rail is read-only for appointments — creation and deletion
    /// both live in the Month view so there's a single place to shape
    /// the month's schedule.
    @ViewBuilder
    private var appointmentsRail: some View {
        let items = store.appointments(for: store.selectedDate)
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: L("appointments.header"))
                Spacer()
                Button {
                    store.setMode(.month)
                } label: {
                    Text(L("appointments.manage_in_month"))
                        .font(DS.FontStyle.caption)
                        .foregroundStyle(Color.dfAccent)
                }
                .buttonStyle(.plain)
            }
            if items.isEmpty {
                Text(L("appointments.empty"))
                    .font(DS.FontStyle.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 2)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items) { apt in
                        HStack(spacing: 8) {
                            Text(DF.hourMinute.string(from: apt.startAt))
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Color.dfAccent)
                                .fixedSize()
                            if let pill = Self.durationPill(from: apt.startAt, to: apt.endAt) {
                                Text(pill)
                                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .fixedSize()
                            }
                            Text(apt.title)
                                .font(DS.FontStyle.body)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(apt.category.color.opacity(0.22))
                                )
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private var reviewRail: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack {
                SectionLabel(text: L("day.ai_review"))
                Spacer()
                if store.reviewIsLoading {
                    ProgressView().controlSize(.small)
                } else if store.reviewBody.isEmpty {
                    Button {
                        store.generateReview()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10, weight: .bold))
                            Text(L("day.generate"))
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(Color.dfAccent.opacity(0.14))
                        )
                        .foregroundStyle(Color.dfAccent)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let err = store.reviewError {
                Text(err)
                    .font(DS.FontStyle.caption)
                    .foregroundStyle(.red)
            }
            if store.reviewBody.isEmpty {
                Text(L("day.review_placeholder"))
                    .font(DS.FontStyle.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, DS.Space.sm)
            } else {
                Text(store.reviewBody)
                    .font(DS.FontStyle.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - week view ------------------------------------------------------

    private var weekView: some View {
        let cal = Calendar.current
        let weekStart = store.startOfWeek(store.selectedDate)
        let days: [Date] = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) }
        let totals = store.weekTotals()

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.element) { idx, day in
                    if idx > 0 {
                        Rectangle().fill(Color.dfHairlineSoft).frame(width: 0.7)
                    }
                    weekColumn(for: day)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, DS.Space.xl)
            .padding(.top, DS.Space.breathe)

            Rectangle().fill(Color.dfHairline).frame(height: 0.7)

            HStack(spacing: DS.Space.lg) {
                Spacer()
                weekFooterStat(value: "\(totals.done)", label: L("week.footer.done"))
                weekFooterStat(value: "\(totals.open)", label: L("week.footer.open"))
                weekFooterStat(value: "\(totals.trackedDays)",
                               label: L(totals.trackedDays == 1 ? "week.footer.day_tracked" : "week.footer.days_tracked"))
                Spacer()
            }
            .padding(.vertical, DS.Space.md)
            .overlay(alignment: .trailing) {
                HStack(spacing: 0) {
                    Text("Dayflow · by ")
                        .foregroundStyle(.tertiary)
                    Text("tryumanshow")
                        .foregroundStyle(.secondary)
                }
                .font(DS.FontStyle.micro)
                .padding(.trailing, DS.Space.xl)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func weekColumn(for day: Date) -> some View {
        let cal = Calendar.current
        let isToday = cal.isDateInToday(day)
        let isSelected = cal.isDate(day, inSameDayAs: store.selectedDate)
        let counts = store.dayCounts(day)
        let total = counts.open + counts.done
        let ratio = total == 0 ? 0.0 : Double(counts.done) / Double(total)
        let groups = store.weekGroups(for: day)

        return VStack(alignment: .leading, spacing: DS.Space.md) {
            // Top accent bar when selected. Tap area belongs to the header.
            Rectangle()
                .fill(isSelected ? Color.dfAccent : Color.clear)
                .frame(height: 2)
                .padding(.horizontal, DS.Space.xs)

            VStack(alignment: .leading, spacing: 6) {
                Text(DF.weekday.string(from: day).uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(isToday ? Color.dfAccent : .secondary)
                Text(DF.dayNumber.string(from: day))
                    .font(.system(size: 24, weight: .semibold).monospacedDigit())
                    .foregroundColor(isToday ? Color.dfAccent : .primary)
                if let holidayName = HolidayStore.holidayName(on: day, mode: holidaysMode) {
                    Text(holidayName)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.dfHoliday)
                        .lineLimit(1)
                }
                if total > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.06))
                            Capsule().fill(Color.dfAccent).frame(width: geo.size.width * ratio)
                        }
                    }
                    .frame(height: 3)
                } else {
                    // Keep vertical rhythm identical on empty days — no placeholder glyph.
                    Color.clear.frame(height: 3)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                store.selectDate(day)
                store.setMode(.day)
            }

            let dayAppointments = store.appointments(for: day)
            if !dayAppointments.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(dayAppointments) { apt in
                        HStack(spacing: 4) {
                            Text(DF.hourMinute.string(from: apt.startAt))
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Color.dfAccent)
                            if let pill = Self.durationPill(from: apt.startAt, to: apt.endAt) {
                                Text(pill)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            Text(apt.title)
                                .font(DS.FontStyle.caption)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(apt.category.color.opacity(0.22))
                                )
                        }
                    }
                }
            }

            if !groups.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(groups) { group in
                        weekGroupView(group, day: day)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isSelected ? Color.dfAccent.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            store.selectDate(day)
            store.setMode(.day)
        }
        .onTapGesture(count: 1) {
            store.selectDate(day)
        }
        .animation(DS.Motion.quick, value: isSelected)
    }

    /// One group in a week column: optional heading + its tasks
    /// (both open and done, in source order). Each task has a tappable
    /// checkbox that flips in place without leaving the Week view.
    /// Sub-tasks get a padding-left offset per indent level so the Day
    /// view's nesting carries over.
    private func weekGroupView(_ group: DayflowStore.WeekGroup, day: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let heading = group.heading {
                Text(heading)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.3)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            ForEach(group.tasks) { task in
                if task.isTask {
                    Button {
                        store.toggleWeekTask(day: day, sourceLineIndex: task.sourceLineIndex)
                    } label: {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: task.checked ? "checkmark.square.fill" : "square")
                                .font(.system(size: 10))
                                .foregroundStyle(task.checked ? Color.dfAccent : .secondary)
                            Text(task.text)
                                .font(DS.FontStyle.caption)
                                .foregroundStyle(task.checked ? .tertiary : .secondary)
                                .strikethrough(task.checked)
                                .lineLimit(1)
                        }
                        .padding(.leading, CGFloat(min(task.depth, 3)) * 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(task.text)
                            .font(DS.FontStyle.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.leading, CGFloat(min(task.depth, 3)) * 10)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        store.selectDate(day)
                        store.setMode(.day)
                    }
                }
            }
        }
    }

    private func weekFooterStat(value: String, label: String) -> some View {
        HStack(spacing: 6) {
            Text(value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
            Text(label)
                .font(DS.FontStyle.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - month view (heatmap left, minimal rail right) -----------------

    private var monthView: some View {
        let stats = store.currentMonthStats()
        let (gridStart, gridEnd) = store.monthGridRange(store.selectedDate)
        let cal = Calendar.current
        var days: [Date] = []
        var cursor = gridStart
        while cursor <= gridEnd {
            days.append(cursor)
            cursor = cal.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(86400)
        }
        let weekdayHeaders = localizedWeekdayHeaders()

        // Chunk the 42-day grid into 6 rows of 7. Manual HStack-per-row
        // layout lets each cell stretch to fill its row's share of the
        // available vertical space — LazyVGrid wouldn't distribute the
        // leftover height on its own.
        let rows: [[Date]] = stride(from: 0, to: days.count, by: 7).map {
            Array(days[$0..<min($0 + 7, days.count)])
        }

        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                HStack(spacing: 4) {
                    ForEach(weekdayHeaders, id: \.self) { wd in
                        Text(wd)
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, DS.Space.xl)
                .padding(.top, DS.Space.breathe)

                VStack(spacing: 4) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 4) {
                            ForEach(row, id: \.self) { day in
                                heatCell(for: day, stats: stats)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(.horizontal, DS.Space.xl)
                .padding(.bottom, DS.Space.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle().fill(Color.dfHairline).frame(width: 0.7)

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.breathe) {
                        monthMetricsRail(stats)
                        monthAppointmentsRail
                        monthPlanRail
                    }
                    .padding(.horizontal, DS.Space.xl)
                    .padding(.top, DS.Space.breathe)
                    .padding(.bottom, DS.Space.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                appCredit
            }
            .frame(width: 460)
            .frame(maxHeight: .infinity)
            .background(Color.dfQuiet)
        }
    }

    private func monthMetricsRail(_ stats: DayflowStore.MonthStats) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            SectionLabel(text: DF.monthTitle.string(from: store.selectedDate))
            HStack(alignment: .bottom, spacing: 4) {
                Text("\(Int(stats.completionRate * 100))")
                    .font(DS.FontStyle.metric)
                    .foregroundStyle(Color.dfAccent)
                Text("%")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
            }
            Text(monthCaption(stats))
                .font(DS.FontStyle.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func monthCaption(_ stats: DayflowStore.MonthStats) -> String {
        var parts: [String] = []
        parts.append(L("month.caption.n_of_m", stats.doneTasks, stats.totalTasks))
        if stats.longestStreak > 0 {
            parts.append(L("month.caption.streak_days", stats.longestStreak))
        }
        if let weekday = stats.busiestWeekday {
            parts.append(L("month.caption.busiest", weekday))
        }
        return parts.joined(separator: " · ")
    }

    /// Weekday header row for the month grid. Sunday-first, honors
    /// the app's language override via `DayflowL10n.activeLocale`.
    private func localizedWeekdayHeaders() -> [String] {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = DayflowL10n.activeLocale
        return cal.shortWeekdaySymbols
    }

    /// Month view is the single source of truth for scheduling.
    private var monthAppointmentsRail: some View {
        let items = store.currentMonthAppointments()
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: L("appointments.month_header"))
                Spacer()
                Text(L("appointments.month_hint"))
                    .font(DS.FontStyle.caption)
                    .foregroundStyle(.tertiary)
            }
            if items.isEmpty {
                Text(L("appointments.empty"))
                    .font(DS.FontStyle.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 2)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(items) { apt in
                            appointmentMonthRow(apt)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }

            HStack(spacing: 6) {
                DatePicker("", selection: $aptDateInput, displayedComponents: [.date])
                    .datePickerStyle(.compact)
                    .labelsHidden()
                timeField($aptTimeInput, placeholder: L("appointments.time_placeholder"))
                Text("–")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                timeField($aptEndTimeInput, placeholder: L("appointments.end_time_placeholder"))
                Spacer()
            }
            HStack(spacing: 6) {
                Picker("", selection: $aptCategoryInput) {
                    ForEach(AppointmentCategory.allCases) { cat in
                        Text(cat.label).tag(cat)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                TextField(L("appointments.title_placeholder"), text: $aptTitleInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.04))
                    )
                    .focused($aptTitleFocused)
                    .onSubmit { submitMonthAppointment() }
                Button {
                    submitMonthAppointment()
                } label: {
                    Text(L(editingAppointmentId == nil ? "appointments.add" : "appointments.update"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.dfAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.dfAccent.opacity(0.14)))
                }
                .buttonStyle(.plain)
                if editingAppointmentId != nil {
                    Button {
                        cancelAppointmentEdit()
                    } label: {
                        Text(L("appointments.cancel"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// One row in the month appointments list. Click the date/time/
    /// title area to navigate to Day; pencil loads into the edit
    /// form; × deletes. Selected (being-edited) row wears the accent
    /// background so the user sees which row the form is bound to.
    @ViewBuilder
    private func appointmentMonthRow(_ apt: Appointment) -> some View {
        let isEditing = (editingAppointmentId == apt.id)
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(DF.shortMonthDay.string(from: apt.startAt))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Text(DF.hourMinute.string(from: apt.startAt))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.dfAccent)
                    .fixedSize()
                if let pill = Self.durationPill(from: apt.startAt, to: apt.endAt) {
                    Text(pill)
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
                let liveCategory = isEditing ? aptCategoryInput : apt.category
                Text(apt.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(liveCategory.color.opacity(0.22))
                    )
                Spacer(minLength: 0)
            }
            Button {
                startAppointmentEdit(apt)
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isEditing ? AnyShapeStyle(Color.dfAccent) : AnyShapeStyle(.tertiary))
                    .frame(width: 18, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                if isEditing { cancelAppointmentEdit() }
                store.deleteAppointment(apt)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isEditing ? Color.dfAccent.opacity(0.12) : .clear)
        )
    }

    /// Compact mono-digit `HH:MM` text field backed by the mask
    /// sanitizer — shared between the start and end time inputs in
    /// the Month rail appointment form. The `if masked != new`
    /// guard short-circuits the second `onChange` pass so the
    /// re-assignment doesn't loop.
    private func timeField(_ binding: Binding<String>, placeholder: String) -> some View {
        TextField(placeholder, text: binding)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .frame(width: 52)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.04))
            )
            .onChange(of: binding.wrappedValue) { _, new in
                let masked = Self.maskHHMM(new)
                if masked != new { binding.wrappedValue = masked }
            }
            .onSubmit { submitMonthAppointment() }
    }

    /// Validation of hours/minutes > 23/59 is left to
    /// `DayflowStore.combine`; this helper only enforces shape.
    static func maskHHMM(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber).prefix(4)
        if digits.count <= 2 { return String(digits) }
        let h = digits.prefix(2)
        let m = digits.dropFirst(2)
        return "\(h):\(m)"
    }

    /// Rendered alongside start time instead of a second time chip
    /// so rows stay single-line. Returns nil when no end, or end
    /// not strictly after start.
    static func durationPill(from start: Date, to end: Date?) -> String? {
        guard let end, end > start else { return nil }
        let minutes = Int(end.timeIntervalSince(start) / 60)
        let h = minutes / 60
        let m = minutes % 60
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }

    private func startAppointmentEdit(_ apt: Appointment) {
        editingAppointmentId = apt.id
        aptDateInput = apt.startAt
        aptTimeInput = DF.hourMinute.string(from: apt.startAt)
        aptEndTimeInput = apt.endAt.map { DF.hourMinute.string(from: $0) } ?? ""
        aptTitleInput = apt.title
        aptCategoryInput = apt.category
        aptTitleFocused = true
    }

    private func cancelAppointmentEdit() {
        editingAppointmentId = nil
        aptTimeInput = ""
        aptEndTimeInput = ""
        aptTitleInput = ""
        aptCategoryInput = .event
        aptTitleFocused = false
    }

    private func submitMonthAppointment() {
        let ok: Bool
        if let id = editingAppointmentId {
            ok = store.updateAppointment(id, on: aptDateInput, hhmm: aptTimeInput, endHHmm: aptEndTimeInput, title: aptTitleInput, category: aptCategoryInput)
        } else {
            ok = store.addAppointment(on: aptDateInput, hhmm: aptTimeInput, endHHmm: aptEndTimeInput, title: aptTitleInput, category: aptCategoryInput)
        }
        if ok {
            editingAppointmentId = nil
            aptTimeInput = ""
            aptEndTimeInput = ""
            aptTitleInput = ""
            aptCategoryInput = .event
            aptTitleFocused = false
        }
    }

    @State private var selectedSectionId: Int64? = nil
    @State private var editingSectionTitleId: Int64? = nil
    @State private var sectionTitleDraft: String = ""

    /// Resolve the active section id — falls back to the first section
    /// when the stored selection is stale or nil.
    private var activeSectionId: Int64? {
        if let id = selectedSectionId,
           store.monthPlanSections.contains(where: { $0.id == id }) {
            return id
        }
        return store.monthPlanSections.first?.id
    }

    private var monthPlanRail: some View {
        @Bindable var store = store
        let activeId = activeSectionId
        let addSection = {
            store.addMonthPlanSection(title: L("month.plan.new_section"))
            if let last = store.monthPlanSections.last {
                selectedSectionId = last.id
            }
        }

        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: L("month.plan_header"))
                Spacer()
                Text(L("month.plan.hint"))
                    .font(DS.FontStyle.caption)
                    .foregroundStyle(.tertiary)
            }

            // Tab bar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.xs) {
                    ForEach(store.monthPlanSections) { section in
                        if editingSectionTitleId == section.id {
                            TextField("", text: $sectionTitleDraft, onCommit: {
                                let trimmed = sectionTitleDraft.trimmingCharacters(in: .whitespaces)
                                if !trimmed.isEmpty {
                                    store.renameMonthPlanSection(id: section.id, title: trimmed)
                                }
                                editingSectionTitleId = nil
                            })
                            .textFieldStyle(.plain)
                            .font(DS.FontStyle.caption.weight(.semibold))
                            .padding(.horizontal, DS.Space.sm)
                            .padding(.vertical, DS.Space.xs)
                            .frame(maxWidth: 120)
                            .background(
                                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                            )
                        } else {
                            monthPlanTab(section: section, isActive: section.id == activeId)
                        }
                    }

                    // "+" button
                    Button {
                        addSection()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, DS.Space.xs)
                            .padding(.vertical, DS.Space.xs)
                    }
                    .buttonStyle(.plain)
                    .help(L("month.plan.add_section"))
                }
            }

            // Editor for active section
            if let activeId {
                monthPlanEditor(sectionId: activeId)
            } else {
                Button {
                    addSection()
                } label: {
                    HStack {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(.tertiary)
                        Text(L("month.plan.empty"))
                            .font(DS.FontStyle.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, DS.Space.xl)
            }
        }
    }

    /// Separate view so the Binding captures `sectionId` by value
    /// instead of a mutable array index — prevents out-of-bounds
    /// crashes when the sections array is mutated mid-render.
    private func monthPlanEditor(sectionId: Int64) -> some View {
        @Bindable var store = store
        return MarkdownWebEditor(
            markdown: Binding(
                get: {
                    store.monthPlanSections.first(where: { $0.id == sectionId })?.bodyMd ?? ""
                },
                set: { newValue in
                    if let i = store.monthPlanSections.firstIndex(where: { $0.id == sectionId }) {
                        store.monthPlanSections[i].bodyMd = newValue
                    }
                }
            ),
            markdownJSON: Binding(
                get: {
                    store.monthPlanSections.first(where: { $0.id == sectionId })?.bodyJSON
                },
                set: { newValue in
                    if let i = store.monthPlanSections.firstIndex(where: { $0.id == sectionId }) {
                        store.monthPlanSections[i].bodyJSON = newValue
                    }
                }
            ),
            fontSize: monthPlanEditorFontSize,
            onChange: { md, json in
                store.updateMonthPlanSection(id: sectionId, body: md, bodyJSON: json)
            }
        )
        .id(sectionId)
        .frame(height: 440)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .stroke(Color.dfHairlineSoft, lineWidth: 0.7)
        )
    }

    private func monthPlanTab(section: MonthPlanSection, isActive: Bool) -> some View {
        Text(section.title)
            .font(DS.FontStyle.caption.weight(isActive ? .semibold : .regular))
            .foregroundStyle(isActive ? .primary : .secondary)
            .padding(.horizontal, DS.Space.sm)
            .padding(.vertical, DS.Space.xs)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(isActive ? Color.white.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                selectedSectionId = section.id
            }
            .contextMenu {
                Button(L("month.plan.rename_section")) {
                    sectionTitleDraft = section.title
                    editingSectionTitleId = section.id
                }
                if store.monthPlanSections.count > 1 {
                    Divider()
                    Button(L("month.plan.delete_section"), role: .destructive) {
                        store.deleteMonthPlanSection(id: section.id)
                        if selectedSectionId == section.id {
                            selectedSectionId = store.monthPlanSections.first?.id
                        }
                    }
                }
            }
    }

    private func heatCell(for day: Date, stats: DayflowStore.MonthStats) -> some View {
        let cal = Calendar.current
        let inMonth = cal.component(.month, from: day) == cal.component(.month, from: store.selectedDate)
        let isToday = cal.isDateInToday(day)
        let isSelected = cal.isDate(day, inSameDayAs: store.selectedDate)
        let key = DayflowDB.ymd(day)
        let done = stats.doneByDay[key] ?? 0
        let open = stats.openByDay[key] ?? 0
        let total = done + open
        let appointments = store.appointments(for: day)
        let holidayName = inMonth ? HolidayStore.holidayName(on: day, mode: holidaysMode) : nil

        return VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("\(cal.component(.day, from: day))")
                        .font(.system(size: 14, weight: isToday ? .bold : .medium).monospacedDigit())
                        .foregroundColor(inMonth
                                         ? (isToday ? Color.dfAccent : (holidayName != nil ? Color.dfHoliday : Color.primary))
                                         : Color.secondary.opacity(0.4))
                    if let holidayName {
                        Text(holidayName)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.dfHoliday)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                // Show up to 3 appointment chips under the day number.
                // On overflow, last row becomes a "+N" counter. Only
                // for in-month cells — leading/trailing padding cells
                // stay visually quiet.
                if inMonth && !appointments.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        let visible = appointments.prefix(3)
                        ForEach(Array(visible)) { apt in
                            // Heatmap cells are too tight (~160px) to
                            // fit start + duration + title reliably,
                            // so the pill is rendered only in the
                            // wider surfaces (right rail, Day/Week).
                            // Cell chip stays start-only.
                            HStack(spacing: 3) {
                                Text(DF.hourMinute.string(from: apt.startAt))
                                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(Color.dfAccent)
                                Text(apt.title)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.primary.opacity(0.85))
                                    .lineLimit(1)
                                    .padding(.horizontal, 3)
                                    .padding(.vertical, 1)
                                    .background(
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(apt.category.color.opacity(0.22))
                                    )
                            }
                        }
                        if appointments.count > 3 {
                            Text("+\(appointments.count - 3)")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .fill(heatColor(inMonth: inMonth, total: total))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .stroke(isSelected ? Color.dfAccent.opacity(0.7) : Color.dfHairlineSoft,
                            lineWidth: isSelected ? 0.9 : 0.7)
            )
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                store.selectDate(day)
                store.setMode(.day)
            }
            .onTapGesture(count: 1) {
                store.selectDate(day)
            }
            .animation(DS.Motion.snap, value: isSelected)
    }

    /// Single warm-accent fill with opacity tied to activity density.
    /// Intentionally *not* sensitive to ratio — the month view's purpose is
    /// to convey rhythm, not success/failure. Value judgments belong in the
    /// rail's metric, not smeared across 42 cells.
    private func heatColor(inMonth: Bool, total: Int) -> Color {
        if !inMonth { return Color.white.opacity(0.015) }
        if total == 0 { return Color.white.opacity(0.025) }
        let intensity = min(1.0, Double(total) / 6.0)
        return Color.dfAccent.opacity(0.06 + intensity * 0.26)
    }

}
