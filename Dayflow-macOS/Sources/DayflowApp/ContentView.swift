import SwiftUI

struct ContentView: View {
    @Environment(DayflowStore.self) private var store
    @State private var newTaskTitle: String = ""
    @State private var newTaskDate: Date = Date()
    @State private var newNoteBody: String = ""
    @State private var datePickerVisible: Bool = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            Divider()
            content
            Divider()
            throwBar
        }
        .frame(minWidth: 920, minHeight: 600)
        .onAppear {
            newTaskDate = store.selectedDate
        }
        .onChange(of: store.selectedDate) { _, newValue in
            newTaskDate = newValue
        }
    }

    // MARK: - navigation bar

    private var navigationBar: some View {
        HStack(spacing: 12) {
            Text("dayflow")
                .font(.title2.weight(.semibold))

            Picker("", selection: Binding(
                get: { store.viewMode },
                set: { store.setMode($0) }
            )) {
                ForEach(CalendarViewMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)

            Button { store.step(by: -1) } label: {
                Image(systemName: "chevron.left")
            }
            Button("Today") { store.goToToday() }
                .buttonStyle(.bordered)
            Button { store.step(by: 1) } label: {
                Image(systemName: "chevron.right")
            }

            Text(headerLabel)
                .font(.title3.weight(.medium))
                .foregroundStyle(.primary)

            Spacer()

            Text("\(store.dayTasks.filter { $0.status == .todo }.count) todo · \(store.dayTasks.filter { $0.status == .doing }.count) doing")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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

    // MARK: - content switcher

    @ViewBuilder
    private var content: some View {
        switch store.viewMode {
        case .day:   dayView
        case .week:  weekView
        case .month: monthView
        }
    }

    // MARK: - day view

    private var dayView: some View {
        HStack(spacing: 0) {
            // left: task list
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if store.dayTasks.isEmpty {
                            Text("이 날 할 일이 비어있어 — 아래에 적어봐")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.top, 24)
                                .frame(maxWidth: .infinity)
                        } else {
                            ForEach(store.dayTasks) { task in
                                TaskRowView(task: task,
                                            isSelected: task.id == store.selectedTaskId)
                                    .contentShape(Rectangle())
                                    .onTapGesture { store.select(task.id) }
                                    .contextMenu {
                                        Button("Cycle status") { store.cycleStatus(task.id) }
                                        Menu("Set due date") {
                                            Button("Today") { store.setDueDate(task.id, to: Date()) }
                                            Button("Tomorrow") {
                                                if let d = Calendar.current.date(byAdding: .day, value: 1, to: Date()) {
                                                    store.setDueDate(task.id, to: d)
                                                }
                                            }
                                            Button("Clear") { store.setDueDate(task.id, to: nil) }
                                        }
                                        Divider()
                                        Button("Delete", role: .destructive) { store.deleteTask(task.id) }
                                    }
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                }
            }
            .frame(width: 320)

            Divider()

            // right: detail (task) + review
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    selectedTaskPanel
                    Divider()
                    reviewPanel
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var selectedTaskPanel: some View {
        if let task = store.selectedTask {
            HStack(alignment: .firstTextBaseline) {
                Text("#\(task.id)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(task.title)
                    .font(.title3.weight(.medium))
                    .lineLimit(2)
                Spacer()
            }
            HStack(spacing: 8) {
                statusBadge(task.status)
                Button("Cycle") { store.cycleStatus(task.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Menu("Set…") {
                    ForEach(TaskStatus.allCases) { s in
                        Button("\(s.glyph) \(s.rawValue)") { store.setStatus(task.id, to: s) }
                    }
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                if let due = task.dueDate {
                    Text("due \(due)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Text("Notes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if store.notes.isEmpty {
                Text("(no notes — add one below)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.notes) { note in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.bodyMd)
                                .font(.callout)
                                .textSelection(.enabled)
                            Text(note.writtenAt)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            HStack {
                TextField("add note…", text: $newNoteBody, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                Button("Add") {
                    let v = newNoteBody.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !v.isEmpty else { return }
                    store.addNote(v)
                    newNoteBody = ""
                }
                .keyboardShortcut(.return, modifiers: [.command])
            }

            Text("History").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(store.history.suffix(8)) { h in
                    HStack {
                        Text(String(h.changedAt.suffix(8)))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                        Text("\(h.fromStatus ?? "∅") → \(h.toStatus)")
                            .font(.caption2.monospaced())
                    }
                }
            }
        } else {
            Text("(클릭해서 task 를 선택해)")
                .foregroundStyle(.secondary)
        }
    }

    private var reviewPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("일일 회고")
                    .font(.headline)
                Spacer()
                if store.reviewIsLoading {
                    ProgressView().controlSize(.small)
                }
                Button {
                    store.generateReview()
                } label: {
                    Label("Generate", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .disabled(store.reviewIsLoading)
            }
            if let err = store.reviewError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if store.reviewBody.isEmpty {
                Text("아직 회고 없음. Generate 버튼으로 LLM 에게 부탁해.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                Text(store.reviewBody)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - week view

    private var weekView: some View {
        let cal = Calendar.current
        let weekStart = store.startOfWeek(store.selectedDate)
        let days: [Date] = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) }
        return ScrollView {
            HStack(alignment: .top, spacing: 8) {
                ForEach(days, id: \.self) { day in
                    weekColumn(for: day)
                }
            }
            .padding(12)
        }
    }

    private func weekColumn(for day: Date) -> some View {
        let dayTasks = store.weekTasks.filter { tasksFallOn(task: $0, date: day) }
        let isToday = Calendar.current.isDateInToday(day)
        let isSelected = Calendar.current.isDate(day, inSameDayAs: store.selectedDate)
        return VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(weekdayLabel(day))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isToday ? Color.accentColor : .secondary)
                Text(dayLabel(day))
                    .font(.title3.weight(.semibold))
            }
            .padding(.bottom, 4)

            ForEach(dayTasks) { task in
                HStack(spacing: 4) {
                    Text(task.status.glyph)
                        .font(.caption2.monospaced())
                    Text(task.title)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(6)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .onTapGesture {
                    store.selectedDate = Calendar.current.startOfDay(for: day)
                    store.select(task.id)
                    store.setMode(.day)
                }
            }
            if dayTasks.isEmpty {
                Text("—")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.04))
        )
        .onTapGesture {
            store.selectedDate = Calendar.current.startOfDay(for: day)
            store.refresh()
        }
    }

    // MARK: - month view (with monthly plan sidebar)

    private var monthView: some View {
        @Bindable var store = store
        let (gridStart, gridEnd) = store.monthGridRange(store.selectedDate)
        let cal = Calendar.current
        var days: [Date] = []
        var cursor = gridStart
        while cursor <= gridEnd {
            days.append(cursor)
            cursor = cal.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(86400)
        }
        let weekdayHeaders = ["월", "화", "수", "목", "금", "토", "일"]

        return HStack(alignment: .top, spacing: 12) {
            // calendar grid
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    ForEach(weekdayHeaders, id: \.self) { wd in
                        Text(wd)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(days, id: \.self) { day in
                        monthCell(for: day)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider()

            // monthly plan sidebar
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Monthly Plan")
                        .font(.headline)
                    Spacer()
                    Text(monthLabel(store.selectedDate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("이 달에 하고 싶은 것 / 큰 흐름. 자유 텍스트.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                TextEditor(text: $store.monthPlanBody)
                    .font(.callout)
                    .padding(6)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .frame(minHeight: 240)
                HStack {
                    Spacer()
                    Button("Save") { store.saveMonthPlan() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("s", modifiers: [.command])
                }
            }
            .padding(12)
            .frame(width: 320, alignment: .top)
        }
    }

    private func monthCell(for day: Date) -> some View {
        let cal = Calendar.current
        let inMonth = cal.component(.month, from: day) == cal.component(.month, from: store.selectedDate)
        let isToday = cal.isDateInToday(day)
        let isSelected = cal.isDate(day, inSameDayAs: store.selectedDate)
        let dayTasks = store.monthTasks.filter { tasksFallOn(task: $0, date: day) }
        let openCount = dayTasks.filter { $0.status == .todo || $0.status == .doing }.count
        let doneCount = dayTasks.filter { $0.status == .done }.count

        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(cal.component(.day, from: day))")
                    .font(.caption.weight(isToday ? .bold : .regular))
                    .foregroundColor(inMonth ? (isToday ? Color.accentColor : Color.primary) : Color.secondary.opacity(0.5))
                Spacer()
                if openCount > 0 {
                    Text("\(openCount)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.orange)
                }
                if doneCount > 0 {
                    Text("✓\(doneCount)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.green)
                }
            }
            ForEach(dayTasks.prefix(2)) { t in
                Text(t.title)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(t.status == .done ? .secondary : .primary)
            }
            if dayTasks.count > 2 {
                Text("+\(dayTasks.count - 2)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(minHeight: 70, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isToday ? Color.accentColor : Color.clear, lineWidth: 1)
        )
        .onTapGesture {
            store.selectedDate = cal.startOfDay(for: day)
            store.refresh()
        }
    }

    // MARK: - throw bar

    private var throwBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle")
                .foregroundStyle(.secondary)
            TextField("새 task 적기 (Enter 로 추가)", text: $newTaskTitle)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .onSubmit(submitTask)
            DatePicker("", selection: $newTaskDate, displayedComponents: [.date])
                .labelsHidden()
                .datePickerStyle(.compact)
            Button("Add") { submitTask() }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func submitTask() {
        let value = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        store.addTask(title: value, dueDate: newTaskDate)
        newTaskTitle = ""
        inputFocused = true
    }

    // MARK: - helpers

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

    private func statusBadge(_ s: TaskStatus) -> some View {
        let color: Color = {
            switch s {
            case .todo: return .blue
            case .doing: return .orange
            case .done: return .green
            case .wont: return .gray
            }
        }()
        return Text("\(s.glyph) \(s.rawValue)")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

struct TaskRowView: View {
    let task: Task
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(task.status.glyph)
                .font(.body.monospaced())
                .frame(width: 14)
                .foregroundStyle(color)
            Text("#\(task.id)")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
            Text(task.title)
                .font(.callout)
                .strikethrough(task.status == .done || task.status == .wont)
                .foregroundStyle(task.status == .done || task.status == .wont ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
    }

    private var color: Color {
        switch task.status {
        case .todo: return .blue
        case .doing: return .orange
        case .done: return .green
        case .wont: return .gray
        }
    }
}
