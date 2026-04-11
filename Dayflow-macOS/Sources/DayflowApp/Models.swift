import Foundation

enum TaskStatus: String, CaseIterable, Identifiable {
    case todo = "TODO"
    case doing = "DOING"
    case done = "DONE"
    case wont = "WONT"

    var id: String { rawValue }

    var glyph: String {
        switch self {
        case .todo:  return "☐"
        case .doing: return "▶"
        case .done:  return "☑"
        case .wont:  return "✗"
        }
    }

    var nextInCycle: TaskStatus {
        switch self {
        case .todo:  return .doing
        case .doing: return .done
        case .done:  return .todo
        case .wont:  return .todo
        }
    }
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
