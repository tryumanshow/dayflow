import SwiftUI

struct ContentView: View {
    @Environment(DayflowStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            content
        }
        .background(Color.dfCanvas)
        .frame(minWidth: 1120, minHeight: 720)
    }

    // MARK: - navigation bar -------------------------------------------------

    private var navigationBar: some View {
        let counts = DayflowDB.parseCheckboxes(store.dayBody)
        return HStack(alignment: .firstTextBaseline, spacing: DS.Space.lg) {
            HStack(spacing: 8) {
                Image(systemName: "rays")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.dfAccent)
                Text("dayflow")
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

            HStack(spacing: 14) {
                summaryChip(symbol: "circle", count: counts.open, color: .dfTodo)
                summaryChip(symbol: "checkmark.circle.fill", count: counts.done, color: .dfDone)
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

    private func summaryChip(symbol: String, count: Int, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
            Text("\(count)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(color.opacity(0.10))
        )
        .overlay(
            Capsule().stroke(color.opacity(0.20), lineWidth: 0.7)
        )
    }

    private var headerLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        switch store.viewMode {
        case .day:
            f.dateFormat = "yyyy년 M월 d일 (E)"
            return f.string(from: store.selectedDate)
        case .week:
            let start = store.startOfWeek(store.selectedDate)
            let end = Calendar.current.date(byAdding: .day, value: 6, to: start) ?? start
            f.dateFormat = "M월 d일"
            return "\(f.string(from: start)) – \(f.string(from: end))"
        case .month:
            f.dateFormat = "yyyy년 M월"
            return f.string(from: store.selectedDate)
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

    // MARK: - day view (asymmetric: 70/30) -----------------------------------

    private var dayView: some View {
        @Bindable var store = store
        return HStack(alignment: .top, spacing: 0) {
            // LEFT — markdown editor, large area
            VStack(alignment: .leading, spacing: DS.Space.md) {
                HStack(alignment: .lastTextBaseline) {
                    Text(longDateLabel(store.selectedDate))
                        .font(DS.FontStyle.display)
                        .tracking(-0.5)
                    Spacer()
                    Text("`- [ ]`  ·  Tab 들여쓰기  ·  체크박스 클릭으로 토글")
                        .font(DS.FontStyle.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, DS.Space.xl)
                .padding(.top, DS.Space.xl)
                .padding(.bottom, DS.Space.sm)

                MarkdownWebEditor(markdown: $store.dayBody, onChange: { newValue in
                    store.updateDayBody(newValue)
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, DS.Space.lg)
                .padding(.bottom, DS.Space.lg)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // hairline divider, not a card border
            Rectangle().fill(Color.dfHairline).frame(width: 0.7)

            // RIGHT — narrow rail (review only) — 30% width
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    daySummaryRail
                    reviewRail
                }
                .padding(DS.Space.xl)
            }
            .frame(width: 360)
            .background(Color.dfSurface.opacity(0.4))
        }
    }

    private var daySummaryRail: some View {
        let counts = DayflowDB.parseCheckboxes(store.dayBody)
        let total = counts.open + counts.done
        let ratio = total == 0 ? 0.0 : Double(counts.done) / Double(total)
        return VStack(alignment: .leading, spacing: DS.Space.md) {
            SectionLabel(text: "오늘 진행")
            HStack(alignment: .bottom, spacing: DS.Space.md) {
                Text("\(Int(ratio * 100))")
                    .font(DS.FontStyle.metric)
                    .foregroundStyle(Color.dfDone)
                Text("%")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
                Spacer()
                if total > 0 {
                    CompletionRing(ratio: ratio, lineWidth: 4, size: 36,
                                   color: ratio == 1 ? .dfDone : .dfAccent)
                }
            }
            HStack(spacing: DS.Space.md) {
                statTile(value: "\(counts.open)", label: "open", color: .dfTodo)
                statTile(value: "\(counts.done)", label: "done", color: .dfDone)
            }
        }
    }

    private func statTile(value: String, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(DS.FontStyle.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.sm)
                .stroke(color.opacity(0.15), lineWidth: 0.7)
        )
    }

    private var reviewRail: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack {
                SectionLabel(text: "AI 회고")
                Spacer()
                if store.reviewIsLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        store.generateReview()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10, weight: .bold))
                            Text(store.reviewBody.isEmpty ? "Generate" : "Regenerate")
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
                Text("하루를 마무리하면서 LLM 에게 회고를 부탁해.")
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
        @Bindable var store = store
        let cal = Calendar.current
        let weekStart = store.startOfWeek(store.selectedDate)
        let days: [Date] = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) }
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .lastTextBaseline) {
                    Text(longDateLabel(store.selectedDate))
                        .font(DS.FontStyle.display)
                        .tracking(-0.5)
                    Spacer()
                }
                .padding(.horizontal, DS.Space.xl)
                .padding(.top, DS.Space.xl)
                .padding(.bottom, DS.Space.lg)

                // 7-day strip — narrow horizontal slice, no card chrome
                HStack(spacing: 0) {
                    ForEach(Array(days.enumerated()), id: \.element) { idx, day in
                        if idx > 0 {
                            Rectangle().fill(Color.dfHairline).frame(width: 0.7)
                        }
                        weekDayChip(for: day)
                    }
                }
                .padding(.horizontal, DS.Space.lg)
                .padding(.bottom, DS.Space.lg)

                Rectangle().fill(Color.dfHairline).frame(height: 0.7)

                // selected day editor
                MarkdownWebEditor(markdown: $store.dayBody, onChange: { newValue in
                    store.updateDayBody(newValue)
                })
                .padding(DS.Space.lg)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func weekDayChip(for day: Date) -> some View {
        let cal = Calendar.current
        let isToday = cal.isDateInToday(day)
        let isSelected = cal.isDate(day, inSameDayAs: store.selectedDate)
        let counts = store.dayCounts(day)
        let total = counts.open + counts.done
        let ratio = total == 0 ? 0.0 : Double(counts.done) / Double(total)

        return Button {
            store.selectDate(day)
        } label: {
            VStack(spacing: 8) {
                Text(weekdayLabel(day).uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(isToday ? Color.dfAccent : .secondary)
                Text(dayLabel(day))
                    .font(.system(size: 26, weight: .semibold).monospacedDigit())
                    .foregroundColor(isToday ? Color.dfAccent : .primary)
                if total > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.06))
                            Capsule().fill(Color.dfDone).frame(width: geo.size.width * ratio)
                        }
                    }
                    .frame(height: 3)
                    .padding(.horizontal, 10)
                    Text("\(counts.done)/\(total)")
                        .font(DS.FontStyle.micro)
                        .foregroundStyle(.tertiary)
                } else {
                    Capsule().fill(Color.white.opacity(0.04)).frame(height: 3).padding(.horizontal, 10)
                    Text("·")
                        .font(DS.FontStyle.micro)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(
                isSelected ? Color.dfAccent.opacity(0.10) : Color.clear
            )
            .overlay(
                Rectangle()
                    .fill(isSelected ? Color.dfAccent : Color.clear)
                    .frame(height: 2),
                alignment: .top
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(DS.Motion.quick, value: isSelected)
    }

    // MARK: - month view (asymmetric: heatmap left, narrow stats rail right) -

    private var monthView: some View {
        @Bindable var store = store
        let stats = store.currentMonthStats()
        let (gridStart, gridEnd) = store.monthGridRange(store.selectedDate)
        let cal = Calendar.current
        var days: [Date] = []
        var cursor = gridStart
        while cursor <= gridEnd {
            days.append(cursor)
            cursor = cal.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(86400)
        }
        let weekdayHeaders = ["월", "화", "수", "목", "금", "토", "일"]

        return HStack(alignment: .top, spacing: 0) {
            // LEFT — heatmap dominant
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                HStack(alignment: .lastTextBaseline) {
                    Text(monthLabel(store.selectedDate))
                        .font(DS.FontStyle.display)
                        .tracking(-0.5)
                    Spacer()
                }
                .padding(.horizontal, DS.Space.xl)
                .padding(.top, DS.Space.xl)

                // weekday header — divide-y style, no card
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

            // RIGHT — narrow rail
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    monthMetricsRail(stats)
                    selectedDayPreviewRail
                    monthPlanRail
                }
                .padding(DS.Space.xl)
            }
            .frame(width: 360)
            .background(Color.dfSurface.opacity(0.4))
        }
    }

    private func monthMetricsRail(_ stats: DayflowStore.MonthStats) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            SectionLabel(text: monthLabel(store.selectedDate))
            HStack(alignment: .bottom, spacing: DS.Space.sm) {
                Text("\(Int(stats.completionRate * 100))")
                    .font(DS.FontStyle.metric)
                    .foregroundStyle(Color.dfDone)
                Text("%")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
                Spacer()
                CompletionRing(ratio: stats.completionRate, lineWidth: 4, size: 40,
                               color: stats.completionRate == 1 ? .dfDone : .dfAccent)
            }
            // 2x2 minimal grid — no nested cards, just hairlines
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    metricCell(value: "\(stats.doneTasks)", label: "완료")
                    Rectangle().fill(Color.dfHairline).frame(width: 0.7)
                    metricCell(value: "\(stats.openTasks)", label: "남음")
                }
                Rectangle().fill(Color.dfHairline).frame(height: 0.7)
                HStack(spacing: 0) {
                    metricCell(value: "\(stats.longestStreak)", label: "최장 연속")
                    Rectangle().fill(Color.dfHairline).frame(width: 0.7)
                    metricCell(value: stats.busiestWeekday ?? "·", label: "가장 바쁜 요일")
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm)
                    .stroke(Color.dfHairline, lineWidth: 0.7)
            )
        }
    }

    private func metricCell(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
            Text(label)
                .font(DS.FontStyle.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
    }

    private var selectedDayPreviewRail: some View {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일 (E)"
        let dateLabel = f.string(from: store.selectedDate)
        let body = store.monthBodies[DayflowDB.ymd(store.selectedDate)]
            ?? store.weekBodies[DayflowDB.ymd(store.selectedDate)]
            ?? ""
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack {
                SectionLabel(text: dateLabel)
                Spacer()
                Button {
                    store.setMode(.day)
                } label: {
                    HStack(spacing: 4) {
                        Text("열기").font(.system(size: 11, weight: .semibold))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(Color.dfAccent)
                }
                .buttonStyle(.plain)
            }
            if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("이 날 적어둔 게 없어")
                    .font(DS.FontStyle.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            } else {
                Text(body)
                    .font(DS.FontStyle.body)
                    .lineLimit(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var monthPlanRail: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack {
                SectionLabel(text: "Monthly Plan")
                Spacer()
                Button {
                    store.saveMonthPlan()
                } label: {
                    Text("Save")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.dfAccent)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("s", modifiers: [.command])
            }
            TextEditor(text: $store.monthPlanBody)
                .font(DS.FontStyle.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.sm)
                        .stroke(Color.dfHairline, lineWidth: 0.7)
                )
                .frame(minHeight: 200)
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
        let ratio = total == 0 ? 0.0 : Double(done) / Double(total)

        return Button {
            store.selectDate(day)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(cal.component(.day, from: day))")
                        .font(.system(size: 12, weight: isToday ? .bold : .medium).monospacedDigit())
                        .foregroundColor(inMonth ? (isToday ? Color.dfAccent : Color.primary) : Color.secondary.opacity(0.4))
                    Spacer()
                    if total > 0 {
                        Text("\(done)/\(total)")
                            .font(DS.FontStyle.micro)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
                if total > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.06))
                            Capsule().fill(ratio == 1 ? Color.dfDone : Color.dfAccent)
                                .frame(width: geo.size.width * ratio)
                        }
                    }
                    .frame(height: 3)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(heatColor(inMonth: inMonth, total: total, ratio: ratio, isSelected: isSelected))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .stroke(isToday ? Color.dfAccent : (isSelected ? Color.dfAccent.opacity(0.6) : Color.dfHairline),
                            lineWidth: isToday ? 1.4 : (isSelected ? 1.0 : 0.7))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(DS.Motion.snap, value: isSelected)
    }

    private func heatColor(inMonth: Bool, total: Int, ratio: Double, isSelected: Bool) -> Color {
        if !inMonth { return Color.white.opacity(0.015) }
        if total == 0 { return Color.white.opacity(0.03) }
        let intensity = min(1.0, Double(total) / 6.0)
        if ratio >= 0.999 {
            return Color.dfDone.opacity(0.10 + intensity * 0.30)
        } else if ratio >= 0.5 {
            return Color.dfDone.opacity(0.06 + intensity * 0.18)
        } else if ratio > 0 {
            return Color.dfAccent.opacity(0.06 + intensity * 0.18)
        } else {
            return Color.white.opacity(0.04 + intensity * 0.06)
        }
    }

    // MARK: - helpers --------------------------------------------------------

    private func longDateLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일 EEEE"
        return f.string(from: d)
    }

    private func weekdayLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "E"
        return f.string(from: d)
    }

    private func dayLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d"
        return f.string(from: d)
    }

    private func monthLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy년 M월"
        return f.string(from: d)
    }
}
