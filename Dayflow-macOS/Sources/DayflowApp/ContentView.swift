import SwiftUI

@MainActor
struct ContentView: View {
    @Environment(DayflowStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            content
                .animation(DS.Motion.settle, value: store.viewMode)
                .transition(.opacity)
        }
        .background(Color.dfCanvas)
        .frame(minWidth: 1120, minHeight: 720)
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
                        Text(mode.label)
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
                    Text("Today")
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

            navIconButton("arrow.clockwise") { store.refresh(force: true) }
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.md)
        .background(Color.dfCanvas)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.dfHairline).frame(height: 0.7)
        }
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
            return DF.fullDate.string(from: store.selectedDate)
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
            MarkdownWebEditor(markdown: $store.dayBody, markdownJSON: $store.dayBodyJSON, onChange: { newMD, newJSON in
                store.updateDayBody(newMD, bodyJSON: newJSON)
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, DS.Space.lg)
            .padding(.top, DS.Space.breathe)
            .padding(.bottom, DS.Space.lg)

            Rectangle().fill(Color.dfHairline).frame(width: 0.7)

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.breathe) {
                        daySummaryRail
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
            .frame(width: 320)
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
                weekFooterStat(value: "\(totals.trackedDays)", label: L("week.footer.days_tracked"))
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
        let body = store.dayBody(for: day)
        let preview = weekPreview(body)

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

            if !preview.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(preview.enumerated()), id: \.offset) { idx, line in
                        weekPreviewRow(line: line, day: day, index: idx)
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
        .onTapGesture {
            // Tapping empty area of the column still navigates to Day.
            store.selectDate(day)
            store.setMode(.day)
        }
        .animation(DS.Motion.quick, value: isSelected)
    }

    /// One preview row. Tasks get a tappable checkbox that toggles the item
    /// *in place* without leaving the Week view. Headings / bullets / plain
    /// text fall through to the column's own tap gesture (→ Day view).
    @ViewBuilder
    private func weekPreviewRow(line: MarkdownLine, day: Date, index: Int) -> some View {
        switch line {
        case .task(let checked, let text):
            HStack(alignment: .top, spacing: 6) {
                Button {
                    store.toggleWeekTask(day: day, previewIndex: index)
                } label: {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 10))
                        .foregroundStyle(checked ? Color.dfAccent : .secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text(text)
                    .font(DS.FontStyle.caption)
                    .foregroundStyle(checked ? .tertiary : .secondary)
                    .strikethrough(checked)
                    .lineLimit(1)
            }
        default:
            weekPreviewLine(line)
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

    private func weekPreview(_ body: String) -> [MarkdownLine] {
        guard !body.isEmpty else { return [] }
        var out: [MarkdownLine] = []
        for raw in body.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            if out.count >= 8 { break }
            if let parsed = MarkdownLine.parse(String(raw)) {
                out.append(parsed)
            }
        }
        return out
    }

    @ViewBuilder
    private func weekPreviewLine(_ line: MarkdownLine) -> some View {
        switch line {
        case .heading(_, let text):
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        case .bullet(let text):
            HStack(alignment: .top, spacing: 6) {
                Text("·")
                    .font(DS.FontStyle.caption)
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(DS.FontStyle.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        case .task(let checked, let text):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 10))
                    .foregroundStyle(checked ? Color.dfAccent : .secondary)
                Text(text)
                    .font(DS.FontStyle.caption)
                    .foregroundStyle(checked ? .tertiary : .secondary)
                    .strikethrough(checked)
                    .lineLimit(1)
            }
        case .plain(let text):
            Text(text)
                .font(DS.FontStyle.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
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

        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
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

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                    ForEach(days, id: \.self) { day in
                        heatCell(for: day, stats: stats)
                    }
                }
                .padding(.horizontal, DS.Space.xl)
                .padding(.bottom, DS.Space.lg)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle().fill(Color.dfHairline).frame(width: 0.7)

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.breathe) {
                        monthMetricsRail(stats)
                        monthStandoutRail(stats)
                        selectedDayPreviewRail
                    }
                    .padding(.horizontal, DS.Space.xl)
                    .padding(.top, DS.Space.breathe)
                    .padding(.bottom, DS.Space.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                appCredit
            }
            .frame(width: 320)
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

    /// Weekday header row for the month grid. Uses the current calendar's
    /// locale-aware short symbols but reorders to start on Monday to match
    /// the grid layout.
    private func localizedWeekdayHeaders() -> [String] {
        let cal = Calendar(identifier: .gregorian)
        let symbols = cal.shortWeekdaySymbols
        return Array(symbols[1...6]) + [symbols[0]]
    }

    @ViewBuilder
    private func monthStandoutRail(_ stats: DayflowStore.MonthStats) -> some View {
        if let line = stats.standoutLine, let dateKey = stats.standoutDate {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                SectionLabel(text: L("month.standout_header"))
                Text(line)
                    .font(DS.FontStyle.body)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                Text(humanDateLabel(from: dateKey))
                    .font(DS.FontStyle.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var selectedDayPreviewRail: some View {
        let dateLabel = DF.shortDate.string(from: store.selectedDate)
        let body = store.dayBody(for: store.selectedDate)
        let lines = weekPreview(body)
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack {
                SectionLabel(text: dateLabel)
                Spacer()
                Button {
                    store.setMode(.day)
                } label: {
                    HStack(spacing: 4) {
                        Text(L("month.selected_day.open")).font(.system(size: 11, weight: .semibold))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(Color.dfAccent)
                }
                .buttonStyle(.plain)
            }
            if lines.isEmpty {
                Text(L("month.selected_day.empty"))
                    .font(DS.FontStyle.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        weekPreviewLine(line)
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

        return Button {
            store.selectDate(day)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(cal.component(.day, from: day))")
                    .font(.system(size: 12, weight: isToday ? .bold : .medium).monospacedDigit())
                    .foregroundColor(inMonth
                                     ? (isToday ? Color.dfAccent : Color.primary)
                                     : Color.secondary.opacity(0.4))
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(heatColor(inMonth: inMonth, total: total))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .stroke(isSelected ? Color.dfAccent.opacity(0.7) : Color.dfHairlineSoft,
                            lineWidth: isSelected ? 0.9 : 0.7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    private func humanDateLabel(from ymd: String) -> String {
        guard let d = DF.ymd.date(from: ymd) else { return ymd }
        return DF.shortDate.string(from: d)
    }
}
