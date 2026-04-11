import SwiftUI

struct ContentView: View {
    @Environment(DayflowStore.self) private var store
    @State private var newNoteBody: String = ""
    @FocusState private var rowFocus: Int?

    var body: some View {
        VStack(spacing: 0) {
            navigationBar.background(.bar)
            Divider()
            content.background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 1080, minHeight: 680)
        .onChange(of: store.focusedTaskId) { _, newValue in
            rowFocus = newValue
        }
    }

    // MARK: - navigation bar -------------------------------------------------

    private var navigationBar: some View {
        HStack(spacing: DS.Space.md) {
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
                summaryChip(label: "open", count: store.dayTasks.filter { !$0.status.isDone }.count, color: .dfTodo)
                summaryChip(label: "done", count: store.dayTasks.filter { $0.status.isDone }.count, color: .dfDone)
            }

            Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
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

    // MARK: - day view (outline editor) --------------------------------------

    private var dayView: some View {
        HStack(alignment: .top, spacing: DS.Space.lg) {
            outlineCard
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                reviewCard
            }
            .frame(width: 360)
        }
        .padding(DS.Space.lg)
    }

    private var outlineCard: some View {
        @Bindable var store = store
        let rows = store.orderedDayRows
        return DSCard(padding: DS.Space.md) {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                HStack {
                    Text("오늘의 할 일")
                        .font(DS.FontStyle.title)
                    Spacer()
                    Text("Tab 들여쓰기 · Shift+Tab 내어쓰기 · Enter 새 줄 · Cmd+Enter 체크")
                        .font(DS.FontStyle.caption)
                        .foregroundStyle(.tertiary)
                }
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if rows.isEmpty {
                            EmptyState(icon: "☀️", title: "여유로운 하루", subtitle: "+ 버튼이나 Enter 로 첫 줄을 적어봐")
                                .frame(minHeight: 240)
                        } else {
                            ForEach(rows, id: \.task.id) { row in
                                outlineRow(task: row.task, depth: row.depth)
                            }
                        }
                        // bottom + button to start a new top-level row
                        Button {
                            if let id = store.newRow() {
                                rowFocus = id
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(.tertiary)
                                Text("새 줄 추가")
                                    .font(DS.FontStyle.body)
                                    .foregroundStyle(.tertiary)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                    .padding(.vertical, DS.Space.sm)
                }
                .frame(minHeight: 360)
            }
        }
    }

    @ViewBuilder
    private func outlineRow(task: Task, depth: Int) -> some View {
        @Bindable var store = store
        let binding = Binding<String>(
            get: { store.draftTitles[task.id] ?? task.title },
            set: { store.draftTitles[task.id] = $0 }
        )
        let done = task.status.isDone

        HStack(spacing: 8) {
            // depth indent + guide
            if depth > 0 {
                ForEach(0..<depth, id: \.self) { _ in
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 1)
                        .padding(.leading, 9)
                        .padding(.trailing, 12)
                }
            }

            // checkbox
            Button { store.toggleDone(task.id) } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.status(task.status), lineWidth: 1.5)
                        .frame(width: 16, height: 16)
                    if done {
                        RoundedRectangle(cornerRadius: 4).fill(Color.dfDone).frame(width: 16, height: 16)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // editable title
            TextField("", text: binding, prompt: Text("할 일 …").foregroundColor(.secondary))
                .textFieldStyle(.plain)
                .font(DS.FontStyle.body)
                .strikethrough(done)
                .foregroundStyle(done ? Color.secondary : .primary)
                .focused($rowFocus, equals: task.id)
                .onSubmit {
                    store.commitTitle(task.id)
                    if let id = store.newRow(asChildOf: task.parentId) {
                        rowFocus = id
                    }
                }
                .onChange(of: rowFocus) { oldValue, newValue in
                    if oldValue == task.id && newValue != task.id {
                        store.commitTitle(task.id)
                    }
                }
                .onKeyPress(.tab) {
                    store.commitTitle(task.id)
                    store.indent(task.id)
                    DispatchQueue.main.async { rowFocus = task.id }
                    return .handled
                }
                .onKeyPress(keys: [.tab], phases: .down) { press in
                    if press.modifiers.contains(.shift) {
                        store.commitTitle(task.id)
                        store.outdent(task.id)
                        DispatchQueue.main.async { rowFocus = task.id }
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.delete) {
                    let title = store.draftTitles[task.id] ?? task.title
                    if title.isEmpty {
                        store.backspaceEmpty(task.id)
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.command) {
                        store.toggleDone(task.id)
                        return .handled
                    }
                    return .ignored
                }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(rowFocus == task.id ? Color.dfAccent.opacity(0.07) : Color.clear)
        )
        .animation(DS.Motion.smooth, value: done)
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
                    .frame(maxHeight: 360)
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
            // top day strip
            DSCard(padding: DS.Space.md) {
                HStack(spacing: DS.Space.sm) {
                    ForEach(days, id: \.self) { day in
                        weekDayChip(for: day)
                    }
                }
            }
            // selected day outline
            VStack(spacing: 0) {
                outlineCard
            }
            .frame(maxHeight: .infinity)
        }
        .padding(DS.Space.lg)
    }

    private func weekDayChip(for day: Date) -> some View {
        let cal = Calendar.current
        let isToday = cal.isDateInToday(day)
        let isSelected = cal.isDate(day, inSameDayAs: store.selectedDate)
        let dayTasks = store.weekTasks.filter { tasksFallOn(task: $0, date: day) }
        let total = dayTasks.count
        let done = dayTasks.filter { $0.status.isDone }.count
        let ratio = total == 0 ? 0.0 : Double(done) / Double(total)

        return Button {
            store.selectedDate = cal.startOfDay(for: day)
            store.refresh()
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
                    Text("\(done)/\(total)")
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

    // MARK: - month view (heatmap + stats + selected day) -------------------

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
            // LEFT: stats summary + heatmap
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

            // RIGHT: selected day list + monthly plan stack
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
        let total = stats.totalByDay[key] ?? 0
        let done = stats.doneByDay[key] ?? 0
        let ratio = total == 0 ? 0.0 : Double(done) / Double(total)

        return Button {
            store.selectedDate = cal.startOfDay(for: day)
            store.refresh()
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
        // intensity by total volume + green by completion
        let intensity = min(1.0, Double(total) / 6.0)   // 6+ tasks → max intensity
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
        let tasks = store.dayTasks
        return DSCard {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                HStack {
                    Text(dateLabel)
                        .font(DS.FontStyle.title)
                    Spacer()
                    Button("열기") {
                        store.setMode(.day)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                if tasks.isEmpty {
                    Text("이 날 적어둔 게 없어")
                        .font(DS.FontStyle.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(tasks.prefix(8)) { t in
                            HStack(spacing: 6) {
                                Image(systemName: t.status.isDone ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(t.status.isDone ? Color.dfDone : Color.dfTodo)
                                    .font(.system(size: 11))
                                Text(t.title.isEmpty ? "(빈 줄)" : t.title)
                                    .font(DS.FontStyle.body)
                                    .strikethrough(t.status.isDone)
                                    .foregroundStyle(t.status.isDone ? Color.secondary : .primary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                        if tasks.count > 8 {
                            Text("+\(tasks.count - 8) more")
                                .font(DS.FontStyle.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
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

    private func tasksFallOn(task: Task, date: Date) -> Bool {
        let target = DayflowDB.ymd(date)
        if let due = task.dueDate {
            return due == target
        }
        return String(task.inboxAt.prefix(10)) == target
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
}
