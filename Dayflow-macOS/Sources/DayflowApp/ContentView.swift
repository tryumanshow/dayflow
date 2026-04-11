import SwiftUI

struct ContentView: View {
    @Environment(DayflowStore.self) private var store
    @State private var newTaskTitle: String = ""
    @State private var newNoteBody: String = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                taskList
                    .frame(width: 280)
                Divider()
                detailPane
                    .frame(minWidth: 320)
            }
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 460)
    }

    // MARK: header

    private var header: some View {
        HStack {
            Text("dayflow")
                .font(.title2.weight(.semibold))
            Spacer()
            Text("\(store.todoTasks.count) todo · \(store.doingTasks.count) doing")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: task list

    private var taskList: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if store.tasks.isEmpty {
                        Text("inbox empty — throw a task below")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 24)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(store.tasks) { task in
                            TaskRowView(task: task,
                                        isSelected: task.id == store.selectedTaskId)
                                .contentShape(Rectangle())
                                .onTapGesture { store.select(task.id) }
                        }
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
            }
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
                TextField("throw into inbox…", text: $newTaskTitle)
                    .textFieldStyle(.plain)
                    .focused($inputFocused)
                    .onSubmit(submitTask)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func submitTask() {
        let value = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        store.addTask(value)
        newTaskTitle = ""
        inputFocused = true
    }

    // MARK: detail

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                            Button("\(s.glyph) \(s.rawValue)") {
                                store.setStatus(task.id, to: s)
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                }

                Divider()

                Text("Notes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    if store.notes.isEmpty {
                        Text("(no notes — add one below)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
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
                }
                .frame(maxHeight: 160)

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

                Divider()

                Text("History")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
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
                }
                .frame(maxHeight: 80)
            } else {
                VStack {
                    Spacer()
                    Text("nothing selected")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(14)
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

    // MARK: footer

    private var footer: some View {
        HStack {
            Text("Cmd+Return to add note · click row to select · Cycle = ☐→▶→☑")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
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
