import SwiftUI

struct ContentView: View {
    @Environment(DayflowStore.self) private var store
    @State private var newTaskTitle: String = ""
    @State private var newTaskDate: Date = Date()
    @State private var newSubtaskParent: Task? = nil
    @State private var newSubtaskTitle: String = ""
    @State private var newNoteBody: String = ""
    @FocusState private var inboxFocused: Bool
    @FocusState private var subtaskFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
                .background(.bar)
            Divider()
            content
                .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            throwBar
                .background(.bar)
        }
        .frame(minWidth: 1080, minHeight: 680)
        .onAppear { newTaskDate = store.selectedDate }
        .onChange(of: store.selectedDate) { _, newValue in newTaskDate = newValue }
    }

    // MARK: navigation bar -----------------------------------------------------

    private var navigationBar: some View {
        HStack(spacing: DS.Space.md) {
            HStack(spacing: 6) {
                Circle().fill(LinearGradient(colors: [.dfDoing, .dfTodo], startPoint: .topLeading, endPoint: .bottomTrailing))
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

            HStack(spacing: DS.Space.md) {
                summaryChip(label: "todo", count: store.dayTasks.filter { $0.status == .todo }.count, color: .dfTodo)
                summaryChip(label: "doing", count: store.dayTasks.filter { $0.status == .doing }.count, color: .dfDoing)
                summaryChip(label: "done", count: store.dayTasks.filter { $0.status == .done }.count, color: .dfDone)
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

    // MARK: content switch ----------------------------------------------------

    @ViewBuilder
    private var content: some View {
        switch store.viewMode {
        case .day:   dayView
        case .week:  weekView
        case .month: monthView
        }
    }

    // MARK: day view ----------------------------------------------------------

    private var dayView: some View {
        HStack(alignment: .top, spacing: DS.Space.lg) {
            // left: tasks
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Text("오늘의 할 일")
                    .font(DS.FontStyle.title)
                    .padding(.horizontal, DS.Space.sm)
                taskListCard
            }
            .frame(maxWidth: .infinity)

            // right: detail + review
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                detailCard
                reviewCard
            }
            .frame(width: 380)
        }
        .padding(DS.Space.lg)
    }

    private var taskListCard: some View {
        DSCard(padding: DS.Space.sm) {
            if store.dayTasks.isEmpty {
                EmptyState(
                    icon: "☀️",
                    title: "여유로운 하루",
                    subtitle: "아래에 할 일을 적어봐"
                )
                .frame(minHeight: 280)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(store.orderedDayTasks, id: \.task.id) { item in
                            TaskRowView(
                                task: item.task,
                                depth: item.depth,
                                isSelected: item.task.id == store.selectedTaskId,
                                onToggle: { store.cycleStatus(item.task.id) },
                                onSelect: { store.select(item.task.id) },
                                onAddSubtask: {
                                    newSubtaskParent = item.task
                                    newSubtaskTitle = ""
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                        subtaskFocused = true
                                    }
                                },
                                onDelete: { store.deleteTask(item.task.id) }
                            )
                            // inline subtask editor right under the parent it was triggered from
                            if let parent = newSubtaskParent, parent.id == item.task.id {
                                HStack(spacing: DS.Space.sm) {
                                    Spacer().frame(width: CGFloat(item.depth + 1) * 22 + 6)
                                    Image(systemName: "plus.circle")
                                        .foregroundStyle(.tertiary)
                                    TextField("sub-task…", text: $newSubtaskTitle)
                                        .textFieldStyle(.plain)
                                        .focused($subtaskFocused)
                                        .onSubmit { commitSubtask() }
                                    Button("Add") { commitSubtask() }
                                        .controlSize(.small)
                                    Button { newSubtaskParent = nil } label: { Image(systemName: "xmark") }
                                        .buttonStyle(.borderless)
                                        .controlSize(.small)
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, DS.Space.sm)
                                .transition(.opacity)
                            }
                        }
                    }
                    .padding(.vertical, DS.Space.sm)
                }
                .frame(minHeight: 320)
            }
        }
    }

    private func commitSubtask() {
        guard let parent = newSubtaskParent else { return }
        let v = newSubtaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else {
            newSubtaskParent = nil
            return
        }
        store.addSubtask(parent: parent, title: v)
        newSubtaskTitle = ""
        // keep editor open under same parent so multiple sub-tasks can be added in a row
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            subtaskFocused = true
        }
    }

    @ViewBuilder
    private var detailCard: some View {
        DSCard {
            if let task = store.selectedTask {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                        StatusPill(status: task.status)
                        Spacer()
                        if let due = task.dueDate {
                            Text("due \(due)").font(DS.FontStyle.micro).foregroundStyle(.secondary)
                        }
                    }
                    Text(task.title)
                        .font(DS.FontStyle.title)
                        .lineLimit(3)
                        .textSelection(.enabled)

                    HStack(spacing: DS.Space.sm) {
                        Button {
                            store.cycleStatus(task.id)
                        } label: {
                            Label("Cycle", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Menu("Set…") {
                            ForEach(TaskStatus.allCases) { s in
                                Button("\(s.glyph)  \(s.rawValue)") { store.setStatus(task.id, to: s) }
                            }
                        }
                        .controlSize(.small)

                        Button(role: .destructive) {
                            store.deleteTask(task.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }

                    Divider()

                    Text("Notes")
                        .font(DS.FontStyle.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    if store.notes.isEmpty {
                        Text("아직 메모 없음")
                            .font(DS.FontStyle.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(store.notes) { note in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(note.bodyMd)
                                        .font(DS.FontStyle.body)
                                        .textSelection(.enabled)
                                    Text(String(note.writtenAt.suffix(8)))
                                        .font(DS.FontStyle.micro)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
                            }
                        }
                    }

                    HStack(spacing: DS.Space.sm) {
                        TextField("메모 추가…", text: $newNoteBody, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...3)
                        Button("Add") {
                            let v = newNoteBody.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !v.isEmpty else { return }
                            store.addNote(v)
                            newNoteBody = ""
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .keyboardShortcut(.return, modifiers: [.command])
                    }

                    if !store.history.isEmpty {
                        Divider()
                        Text("History")
                            .font(DS.FontStyle.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(store.history.suffix(6)) { h in
                                HStack(spacing: 6) {
                                    Text(String(h.changedAt.suffix(8)))
                                        .font(DS.FontStyle.micro)
                                        .foregroundStyle(.tertiary)
                                    Text("\(h.fromStatus ?? "∅") → \(h.toStatus)")
                                        .font(DS.FontStyle.micro)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } else {
                EmptyState(icon: "👈", title: "task 를 골라봐", subtitle: "좌측에서 row 를 클릭하면 상세가 나와")
            }
        }
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
                    .frame(maxHeight: 220)
                }
            }
        }
    }

    // MARK: week view ---------------------------------------------------------

    private var weekView: some View {
        let cal = Calendar.current
        let weekStart = store.startOfWeek(store.selectedDate)
        let days: [Date] = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) }
        return ScrollView {
            HStack(alignment: .top, spacing: DS.Space.sm) {
                ForEach(days, id: \.self) { day in
                    weekColumn(for: day)
                }
            }
            .padding(DS.Space.lg)
        }
    }

    private func weekColumn(for day: Date) -> some View {
        let cal = Calendar.current
        let dayTasks = store.weekTasks.filter { tasksFallOn(task: $0, date: day) }
        let isToday = cal.isDateInToday(day)
        let isSelected = cal.isDate(day, inSameDayAs: store.selectedDate)
        let done = dayTasks.filter { $0.status == .done }.count
        let total = dayTasks.count
        return DSCard(padding: DS.Space.sm) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(weekdayLabel(day))
                        .font(DS.FontStyle.caption.weight(.semibold))
                        .foregroundStyle(isToday ? Color.dfDoing : .secondary)
                    Text(dayLabel(day))
                        .font(.system(size: 22, weight: .semibold).monospacedDigit())
                        .foregroundColor(isToday ? Color.dfDoing : .primary)
                    Spacer()
                    if total > 0 {
                        Text("\(done)/\(total)")
                            .font(DS.FontStyle.micro)
                            .foregroundStyle(.tertiary)
                    }
                }
                ForEach(dayTasks.prefix(6)) { task in
                    HStack(spacing: 6) {
                        Circle().fill(Color.status(task.status)).frame(width: 6, height: 6)
                        Text(task.title)
                            .font(DS.FontStyle.caption)
                            .lineLimit(1)
                            .strikethrough(task.status == .done)
                            .foregroundStyle(task.status == .done ? Color.secondary : .primary)
                        Spacer(minLength: 0)
                    }
                }
                if dayTasks.count > 6 {
                    Text("+\(dayTasks.count - 6) more").font(DS.FontStyle.caption).foregroundStyle(.tertiary)
                }
                if dayTasks.isEmpty {
                    Text("여유 있음").font(DS.FontStyle.caption).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                .stroke(isSelected ? Color.dfDoing : .clear, lineWidth: isSelected ? 1.5 : 0)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectedDate = cal.startOfDay(for: day)
            store.refresh()
        }
    }

    // MARK: month view --------------------------------------------------------

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
            // left — calendar grid + stats card on top
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                statsCard(stats)
                DSCard(padding: DS.Space.md) {
                    VStack(spacing: DS.Space.sm) {
                        HStack(spacing: 4) {
                            ForEach(weekdayHeaders, id: \.self) { wd in
                                Text(wd)
                                    .font(DS.FontStyle.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(days, id: \.self) { day in
                                monthCell(for: day)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            // right — monthly plan
            DSCard {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    HStack {
                        Label("Monthly Plan", systemImage: "list.bullet.rectangle")
                            .font(DS.FontStyle.title)
                        Spacer()
                        Text(monthLabel(store.selectedDate))
                            .font(DS.FontStyle.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("이 달에 하고 싶은 큰 흐름")
                        .font(DS.FontStyle.caption)
                        .foregroundStyle(.tertiary)
                    TextEditor(text: $store.monthPlanBody)
                        .font(DS.FontStyle.body)
                        .padding(8)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
                        .frame(minHeight: 320)
                    HStack {
                        Spacer()
                        Button("Save") { store.saveMonthPlan() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .keyboardShortcut("s", modifiers: [.command])
                    }
                }
            }
            .frame(width: 300, alignment: .top)
        }
        .padding(DS.Space.lg)
    }

    private func statsCard(_ stats: DayflowStore.MonthStats) -> some View {
        DSCard(padding: DS.Space.md) {
            HStack(spacing: DS.Space.lg) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text("\(Int(stats.completionRate * 100))")
                            .font(.system(size: 28, weight: .bold).monospacedDigit())
                            .foregroundStyle(Color.dfDone)
                        Text("%")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text("이 달 완료율")
                        .font(DS.FontStyle.caption)
                        .foregroundStyle(.secondary)
                }
                Divider().frame(height: 36)
                statBlock(value: "\(stats.doneTasks)", label: "done", color: .dfDone)
                statBlock(value: "\(stats.openTasks)", label: "open", color: .dfTodo)
                statBlock(value: focusedLabel(stats.focusedSeconds), label: "focused", color: .dfDoing)
                statBlock(value: "\(stats.longestStreak)일", label: "streak", color: .purple)
                if let busy = stats.busiestWeekday {
                    statBlock(value: busy, label: "busiest", color: .pink)
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

    private func focusedLabel(_ sec: Int) -> String {
        let h = sec / 3600
        let m = (sec % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private func monthCell(for day: Date) -> some View {
        let cal = Calendar.current
        let inMonth = cal.component(.month, from: day) == cal.component(.month, from: store.selectedDate)
        let isToday = cal.isDateInToday(day)
        let isSelected = cal.isDate(day, inSameDayAs: store.selectedDate)
        let metrics = store.dayMetrics(day)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("\(cal.component(.day, from: day))")
                    .font(.system(size: 12, weight: isToday ? .bold : .regular).monospacedDigit())
                    .foregroundColor(inMonth ? (isToday ? Color.dfDoing : Color.primary) : Color.secondary.opacity(0.4))
                Spacer()
                if metrics.total > 0 {
                    CompletionRing(
                        ratio: metrics.ratio,
                        lineWidth: 2,
                        size: 14,
                        color: metrics.ratio == 1 ? .dfDone : .dfDoing
                    )
                }
            }
            ForEach(store.monthTasks.filter { tasksFallOn(task: $0, date: day) }.prefix(2)) { t in
                Text(t.title)
                    .font(DS.FontStyle.micro)
                    .lineLimit(1)
                    .strikethrough(t.status == .done)
                    .foregroundStyle(t.status == .done ? Color.secondary : .primary)
            }
            if metrics.total > 2 {
                Text("+\(metrics.total - 2)")
                    .font(DS.FontStyle.micro)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(minHeight: 76, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .fill(cellBackground(inMonth: inMonth, isSelected: isSelected, ratio: metrics.ratio))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .stroke(isToday ? Color.dfDoing : Color.clear, lineWidth: 1)
        )
        .onTapGesture {
            store.selectedDate = cal.startOfDay(for: day)
            store.refresh()
        }
    }

    private func cellBackground(inMonth: Bool, isSelected: Bool, ratio: Double) -> Color {
        if isSelected { return Color.dfDoing.opacity(0.18) }
        if !inMonth   { return Color.primary.opacity(0.02) }
        if ratio == 0 { return Color.primary.opacity(0.04) }
        return Color.dfDone.opacity(0.06 + ratio * 0.18)
    }

    // MARK: throw bar ---------------------------------------------------------

    private var throwBar: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(Color.dfDoing)
                .font(.system(size: 16))
            TextField("새 task 적기 (Enter)", text: $newTaskTitle)
                .textFieldStyle(.plain)
                .font(DS.FontStyle.body)
                .focused($inboxFocused)
                .onSubmit(submitTask)
            DatePicker("", selection: $newTaskDate, displayedComponents: [.date])
                .labelsHidden()
                .datePickerStyle(.compact)
            Button("Add") { submitTask() }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm)
    }

    private func submitTask() {
        let value = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        store.addTask(title: value, dueDate: newTaskDate)
        newTaskTitle = ""
        inboxFocused = true
    }

    // MARK: helpers -----------------------------------------------------------

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

    private func monthLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy년 M월"
        return f.string(from: d)
    }
}

// MARK: - TaskRowView (single source of task display) --------------------------

struct TaskRowView: View {
    let task: Task
    let depth: Int
    let isSelected: Bool
    let onToggle: () -> Void
    let onSelect: () -> Void
    let onAddSubtask: () -> Void
    let onDelete: () -> Void

    @State private var hovered: Bool = false

    private var done: Bool { task.status == .done || task.status == .wont }

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            // depth indent
            if depth > 0 {
                Spacer().frame(width: CGFloat(depth) * 22)
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 1, height: 18)
            }

            // tap target — single click toggles status
            Button(action: onToggle) {
                ZStack {
                    Circle()
                        .stroke(Color.status(task.status), lineWidth: task.status == .doing ? 2.5 : 1.5)
                        .frame(width: 18, height: 18)
                    Group {
                        switch task.status {
                        case .done:
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color.dfDone)
                        case .doing:
                            Circle().fill(Color.dfDoing).frame(width: 8, height: 8)
                        case .wont:
                            Image(systemName: "minus")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.dfWont)
                        case .todo:
                            EmptyView()
                        }
                    }
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Click to cycle status")

            // title (click to select)
            Text(task.title)
                .font(DS.FontStyle.body)
                .strikethrough(done)
                .foregroundStyle(done ? Color.secondary : .primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { onSelect() }

            // hover affordances
            if hovered || isSelected {
                Button(action: onAddSubtask) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Add sub-task")

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Delete")
            }

            Text("#\(task.id)")
                .font(DS.FontStyle.micro)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .fill(isSelected ? Color.dfDoing.opacity(0.10) : (hovered ? Color.primary.opacity(0.04) : .clear))
        )
        .animation(DS.Motion.smooth, value: hovered)
        .animation(DS.Motion.quick, value: task.status)
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Cycle status") { onToggle() }
            Button("Add sub-task") { onAddSubtask() }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
    }
}
