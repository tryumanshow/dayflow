import Foundation
import Observation

@MainActor
@Observable
final class DayflowStore {
    var tasks: [Task] = []
    var selectedTaskId: Int?
    var notes: [Note] = []
    var history: [StateChange] = []

    private let db = DayflowDB.shared
    private var refreshTimer: Timer?

    init() {
        refresh()
        // poll every 3 seconds — picks up changes made by `inb` / `df`
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    var menuBarText: String {
        let doing = tasks.first { $0.status == .doing }
        if let d = doing {
            let cap = String(d.title.prefix(28))
            return "▶ \(cap)"
        }
        let todoCount = tasks.filter { $0.status == .todo }.count
        if todoCount == 0 { return "🌱 dayflow" }
        return "📋 \(todoCount)"
    }

    var todoTasks: [Task] { tasks.filter { $0.status == .todo } }
    var doingTasks: [Task] { tasks.filter { $0.status == .doing } }
    var doneTasks: [Task] { tasks.filter { $0.status == .done } }

    func refresh() {
        tasks = db.listToday()
        if let id = selectedTaskId, !tasks.contains(where: { $0.id == id }) {
            selectedTaskId = nil
        }
        if selectedTaskId == nil {
            selectedTaskId = tasks.first?.id
        }
        reloadDetail()
    }

    func select(_ taskId: Int) {
        selectedTaskId = taskId
        reloadDetail()
    }

    func addTask(_ title: String) {
        guard let task = db.addTask(title: title) else { return }
        refresh()
        selectedTaskId = task.id
        reloadDetail()
    }

    func cycleStatus(_ taskId: Int) {
        guard let t = tasks.first(where: { $0.id == taskId }) else { return }
        db.changeStatus(taskId: taskId, to: t.status.nextInCycle)
        refresh()
    }

    func setStatus(_ taskId: Int, to status: TaskStatus) {
        db.changeStatus(taskId: taskId, to: status)
        refresh()
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
        return tasks.first(where: { $0.id == id })
    }
}
