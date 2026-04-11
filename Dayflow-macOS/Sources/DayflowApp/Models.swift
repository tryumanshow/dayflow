import Foundation

/// Binary task status. The DB still allows arbitrary strings, but the app
/// collapses everything to TODO / DONE for clarity. Legacy DOING → TODO,
/// legacy WONT → DONE.
enum TaskStatus: String, CaseIterable, Identifiable {
    case todo = "TODO"
    case done = "DONE"

    var id: String { rawValue }

    static func parse(_ raw: String) -> TaskStatus {
        switch raw.uppercased() {
        case "DONE", "WONT": return .done
        default:             return .todo
        }
    }

    var isDone: Bool { self == .done }
    var toggled: TaskStatus { self == .todo ? .done : .todo }
}

struct Task: Identifiable, Hashable {
    let id: Int
    var title: String
    var status: TaskStatus
    var inboxAt: String
    var dueDate: String?
    var updatedAt: String
    var parentId: Int?
}

struct StateChange: Identifiable, Hashable {
    let id: Int
    let taskId: Int
    let fromStatus: String?
    let toStatus: String
    let changedAt: String
}

struct Note: Identifiable, Hashable {
    let id: Int
    let taskId: Int
    let bodyMd: String
    let writtenAt: String
}

struct TimeEntry: Identifiable, Hashable {
    let id: Int
    let taskId: Int
    let startedAt: String
    let endedAt: String?
    let durationSec: Int?
}
