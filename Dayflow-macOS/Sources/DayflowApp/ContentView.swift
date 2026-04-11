import SwiftUI

struct ContentView: View {
    @Environment(DayflowStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            navigationBar.background(.bar)
            Divider()
            content.background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 1080, minHeight: 680)
    }

    // MARK: - navigation bar -------------------------------------------------

    private var navigationBar: some View {
        let counts = DayflowDB.parseCheckboxes(store.dayBody)
        return HStack(spacing: DS.Space.md) {
            HStack(spacing: 6) {
                Circle().fill(LinearGradient(colors: [.dfAccent, .dfDone], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 14, height: 14)
                Text("dayflow").font(DS.FontStyle.display)
            }

            Picker("", selection: Binding(
                get: { store.viewMode },
                set: { store.setMode($0) }
            )) {
                ForEach(CalendarViewMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            HStack(spacing: 4) {
                Button { store.step(by: -1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                Button("Today") { store.goToToday() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button { store.step(by: 1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
            }

            Text(headerLabel)
                .font(DS.FontStyle.title)
                .foregroundStyle(.primary)

            Spacer()

            HStack(spacing: 14) {
                summaryChip(label: "open", count: counts.open, color: .dfTodo)
                summaryChip(label: "done", count: counts.done, color: .dfDone)
            }

            Button { store.refresh(force: true) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh")
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
    }

    private func summaryChip(label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(count)").font(.system(size: 13, weight: .semibold).monospacedDigit())
            Text(label).font(DS.FontStyle.caption).foregroundStyle(.secondary)
        }
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

    // MARK: - day view (markdown editor) -------------------------------------

    private var dayView: some View {
        @Bindable var store = store
        return HStack(alignment: .top, spacing: DS.Space.lg) {
            DSCard(padding: DS.Space.sm) {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    HStack {
                        Text("오늘의 노트").font(DS.FontStyle.title)
                        Spacer()
                        Text("`- [ ]` 체크박스 · `## 헤더` · Tab 들여쓰기 · 클릭으로 토글")
                            .font(DS.FontStyle.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Divider()
                    MarkdownEditor(text: $store.dayBody, onChange: { newValue in
                        store.updateDayBody(newValue)
                    })
                    .frame(minHeight: 480)
                }
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: DS.Space.lg) {
                reviewCard
            }
            .frame(width: 360)
        }
        .padding(DS.Space.lg)
    }

    private var reviewCard: some View {
        DSCard {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                HStack {
                    Label("일일 회고", systemImage: "sparkles")
                        .font(DS.FontStyle.title)
                    Spacer()
                    if store.reviewIsLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            store.generateReview()
                        } label: {
                            Text(store.reviewBody.isEmpty ? "Generate" : "Regenerate")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                if let err = store.reviewError {
                    Text(err)
                        .font(DS.FontStyle.caption)
                        .foregroundStyle(.red)
                }
                if store.reviewBody.isEmpty {
                    Text("LLM 에게 오늘 회고 부탁해 — 한 클릭")
                        .font(DS.FontStyle.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ScrollView {
                        Text(store.reviewBody)
                            .font(DS.FontStyle.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 380)
                }
            }
        }
    }

    // MARK: - week view ------------------------------------------------------

    private var weekView: some View {
        let cal = Calendar.current
        let weekStart = store.startOfWeek(store.selectedDate)
        let days: [Date] = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) }
        return VStack(spacing: DS.Space.lg) {
            DSCard(padding: DS.Space.md) {
                HStack(spacing: DS.Space.sm) {
                    ForEach(days, id: \.self) { day in
                        weekDayChip(for: day)
                    }
                }
            }
            dayView
                .padding(0)
        }
        .padding(DS.Space.lg)
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
            VStack(spacing: 6) {
                Text(weekdayLabel(day))
                    .font(DS.FontStyle.caption)
                    .foregroundStyle(isToday ? Color.dfAccent : .secondary)
                Text(dayLabel(day))
                    .font(.system(size: 22, weight: .semibold).monospacedDigit())
                    .foregroundColor(isToday ? Color.dfAccent : .primary)
                if total > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule().fill(Color.dfDone).frame(width: geo.size.width * ratio)
                        }
                    }
                    .frame(height: 4)
                    Text("\(counts.done)/\(total)")
                        .font(DS.FontStyle.micro)
                        .foregroundStyle(.tertiary)
                } else {
                    Capsule().fill(Color.primary.opacity(0.05)).frame(height: 4)
                    Text("—").font(DS.FontStyle.micro).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .fill(isSelected ? Color.dfAccent.opacity(0.14) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .stroke(isSelected ? Color.dfAccent : Color.clear, lineWidth: 1.2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - month view -----------------------------------------------------

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

        return HStack(alignment: .top, spacing: DS.Space.lg) {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                statsHeader(stats)
                DSCard(padding: DS.Space.md) {
                    VStack(spacing: 6) {
                        HStack(spacing: 4) {
                            ForEach(weekdayHeaders, id: \.self) { wd in
                                Text(wd)
                                    .font(DS.FontStyle.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(days, id: \.self) { day in
                                heatCell(for: day, stats: stats)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            VStack(alignment: .leading, spacing: DS.Space.lg) {
                selectedDayCard
                monthlyPlanCard
            }
            .frame(width: 360)
        }
        .padding(DS.Space.lg)
    }

    private func statsHeader(_ stats: DayflowStore.MonthStats) -> some View {
        DSCard(padding: DS.Space.lg) {
            HStack(spacing: DS.Space.xl) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        Text("\(Int(stats.completionRate * 100))")
                            .font(.system(size: 38, weight: .bold).monospacedDigit())
                            .foregroundStyle(Color.dfDone)
                        Text("%").font(.system(size: 16, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    Text("이 달 완료율")
                        .font(DS.FontStyle.caption)
                        .foregroundStyle(.secondary)
                }
                Divider().frame(height: 44)
                statBlock(value: "\(stats.doneTasks)", label: "done", color: .dfDone)
                statBlock(value: "\(stats.openTasks)", label: "open", color: .dfTodo)
                statBlock(value: "\(stats.longestStreak)일", label: "streak", color: .dfAccent)
                if let busy = stats.busiestWeekday {
                    statBlock(value: busy, label: "busiest", color: .purple)
                }
                Spacer()
            }
        }
    }

    private func statBlock(value: String, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(DS.FontStyle.caption)
                .foregroundStyle(.secondary)
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
            VStack(spacing: 2) {
                Text("\(cal.component(.day, from: day))")
                    .font(.system(size: 12, weight: isToday ? .bold : .regular).monospacedDigit())
                    .foregroundColor(inMonth ? (isToday ? Color.dfAccent : Color.primary) : Color.secondary.opacity(0.4))
                if total > 0 {
                    Text("\(done)/\(total)")
                        .font(DS.FontStyle.micro)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(heatColor(inMonth: inMonth, total: total, ratio: ratio, isSelected: isSelected))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isToday ? Color.dfAccent : (isSelected ? Color.dfAccent.opacity(0.7) : Color.clear),
                            lineWidth: isToday ? 1.4 : (isSelected ? 1.2 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func heatColor(inMonth: Bool, total: Int, ratio: Double, isSelected: Bool) -> Color {
        if !inMonth { return Color.primary.opacity(0.02) }
        if total == 0 { return Color.primary.opacity(0.04) }
        let intensity = min(1.0, Double(total) / 6.0)
        if ratio >= 0.999 {
            return Color.dfDone.opacity(0.18 + intensity * 0.40)
        } else if ratio >= 0.5 {
            return Color.dfDone.opacity(0.10 + intensity * 0.25)
        } else if ratio > 0 {
            return Color.dfAccent.opacity(0.08 + intensity * 0.22)
        } else {
            return Color.dfTodo.opacity(0.10 + intensity * 0.18)
        }
    }

    private var selectedDayCard: some View {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일 (E)"
        let dateLabel = f.string(from: store.selectedDate)
        let body = store.monthBodies[DayflowDB.ymd(store.selectedDate)]
            ?? store.weekBodies[DayflowDB.ymd(store.selectedDate)]
            ?? ""
        return DSCard {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                HStack {
                    Text(dateLabel).font(DS.FontStyle.title)
                    Spacer()
                    Button("열기") { store.setMode(.day) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("이 날 적어둔 게 없어")
                        .font(DS.FontStyle.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ScrollView {
                        Text(body)
                            .font(DS.FontStyle.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                }
            }
        }
    }

    private var monthlyPlanCard: some View {
        @Bindable var store = store
        return DSCard {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                HStack {
                    Label("Monthly Plan", systemImage: "list.bullet.rectangle")
                        .font(DS.FontStyle.title)
                    Spacer()
                    Button("Save") { store.saveMonthPlan() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .keyboardShortcut("s", modifiers: [.command])
                }
                Text("이 달의 큰 흐름")
                    .font(DS.FontStyle.caption)
                    .foregroundStyle(.tertiary)
                TextEditor(text: $store.monthPlanBody)
                    .font(DS.FontStyle.body)
                    .padding(8)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
                    .frame(minHeight: 220)
            }
        }
    }

    // MARK: - helpers --------------------------------------------------------

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
}
