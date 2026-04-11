import Foundation
import SQLite3

/// Thin wrapper around the dayflow SQLite DB.
///
/// This is a *peer* to the Python data layer — it talks to the same file at
/// `~/dayflow/dayflow.db` and trusts the same schema. WAL mode (set by the
/// Python side at `init_schema`) lets us read/write concurrently.
final class DayflowDB {
    static let shared = DayflowDB()

    private var db: OpaquePointer?

    static var defaultPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("dayflow/dayflow.db").path
    }

    init(path: String = DayflowDB.defaultPath) {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            NSLog("dayflow: failed to open db at \(path)")
            return
        }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil)
    }

    deinit {
        if db != nil { sqlite3_close(db) }
    }

    // MARK: - helpers

    private func nowISO() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        // Python writes "2026-04-11T17:23:00" (no timezone). Match that.
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df.string(from: Date())
    }

    private func todayISO() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df.string(from: Date())
    }

    private func textCol(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        if let cstr = sqlite3_column_text(stmt, idx) {
            return String(cString: cstr)
        }
        return ""
    }

    private func textColOpt(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        if sqlite3_column_type(stmt, idx) == SQLITE_NULL { return nil }
        return textCol(stmt, idx)
    }

    private func intColOpt(_ stmt: OpaquePointer?, _ idx: Int32) -> Int? {
        if sqlite3_column_type(stmt, idx) == SQLITE_NULL { return nil }
        return Int(sqlite3_column_int64(stmt, idx))
    }

    // MARK: - tasks

    func listToday() -> [Task] {
        let sql = """
        SELECT id, title, status, inbox_at, due_date, updated_at
        FROM tasks
        WHERE substr(inbox_at, 1, 10) = ?
           OR status IN ('TODO', 'DOING')
        ORDER BY
          CASE status WHEN 'DOING' THEN 0 WHEN 'TODO' THEN 1
                      WHEN 'DONE' THEN 2 ELSE 3 END,
          id DESC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        let today = todayISO()
        sqlite3_bind_text(stmt, 1, today, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var out: [Task] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Int(sqlite3_column_int64(stmt, 0))
            let title = textCol(stmt, 1)
            let statusStr = textCol(stmt, 2)
            let status = TaskStatus(rawValue: statusStr) ?? .todo
            let inboxAt = textCol(stmt, 3)
            let due = textColOpt(stmt, 4)
            let updated = textCol(stmt, 5)
            out.append(Task(id: id, title: title, status: status, inboxAt: inboxAt, dueDate: due, updatedAt: updated))
        }
        return out
    }

    @discardableResult
    func addTask(title: String) -> Task? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let now = nowISO()

        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        defer { sqlite3_exec(db, "COMMIT", nil, nil, nil) }

        var stmt: OpaquePointer?
        let insertSQL = """
        INSERT INTO tasks (title, status, inbox_at, due_date, updated_at)
        VALUES (?, 'TODO', ?, NULL, ?);
        """
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, trimmed, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, now, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 3, now, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            sqlite3_finalize(stmt)
            return nil
        }
        sqlite3_finalize(stmt)
        let taskId = Int(sqlite3_last_insert_rowid(db))

        var hist: OpaquePointer?
        let histSQL = """
        INSERT INTO state_history (task_id, from_status, to_status, changed_at)
        VALUES (?, NULL, 'TODO', ?);
        """
        sqlite3_prepare_v2(db, histSQL, -1, &hist, nil)
        sqlite3_bind_int64(hist, 1, sqlite3_int64(taskId))
        sqlite3_bind_text(hist, 2, now, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_step(hist)
        sqlite3_finalize(hist)

        return Task(id: taskId, title: trimmed, status: .todo, inboxAt: now, dueDate: nil, updatedAt: now)
    }

    func changeStatus(taskId: Int, to newStatus: TaskStatus) {
        let now = nowISO()
        var current: TaskStatus = .todo
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT status FROM tasks WHERE id = ?", -1, &stmt, nil)
        sqlite3_bind_int64(stmt, 1, sqlite3_int64(taskId))
        if sqlite3_step(stmt) == SQLITE_ROW, let s = TaskStatus(rawValue: textCol(stmt, 0)) {
            current = s
        } else {
            sqlite3_finalize(stmt)
            return
        }
        sqlite3_finalize(stmt)
        if current == newStatus { return }

        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        defer { sqlite3_exec(db, "COMMIT", nil, nil, nil) }

        var upd: OpaquePointer?
        sqlite3_prepare_v2(db, "UPDATE tasks SET status=?, updated_at=? WHERE id=?", -1, &upd, nil)
        sqlite3_bind_text(upd, 1, newStatus.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(upd, 2, now, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(upd, 3, sqlite3_int64(taskId))
        sqlite3_step(upd)
        sqlite3_finalize(upd)

        var hist: OpaquePointer?
        sqlite3_prepare_v2(db,
            "INSERT INTO state_history (task_id, from_status, to_status, changed_at) VALUES (?,?,?,?)",
            -1, &hist, nil)
        sqlite3_bind_int64(hist, 1, sqlite3_int64(taskId))
        sqlite3_bind_text(hist, 2, current.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(hist, 3, newStatus.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(hist, 4, now, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_step(hist)
        sqlite3_finalize(hist)

        // time_log: opening DOING starts a timer; leaving DOING closes it
        if newStatus == .doing && current != .doing {
            var t: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO time_log (task_id, started_at) VALUES (?, ?)", -1, &t, nil)
            sqlite3_bind_int64(t, 1, sqlite3_int64(taskId))
            sqlite3_bind_text(t, 2, now, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_step(t)
            sqlite3_finalize(t)
        }
        if current == .doing && newStatus != .doing {
            var sel: OpaquePointer?
            sqlite3_prepare_v2(db,
                "SELECT id, started_at FROM time_log WHERE task_id=? AND ended_at IS NULL ORDER BY id DESC LIMIT 1",
                -1, &sel, nil)
            sqlite3_bind_int64(sel, 1, sqlite3_int64(taskId))
            if sqlite3_step(sel) == SQLITE_ROW {
                let entryId = Int(sqlite3_column_int64(sel, 0))
                let startedAt = textCol(sel, 1)
                sqlite3_finalize(sel)

                let inFmt = DateFormatter()
                inFmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                inFmt.locale = Locale(identifier: "en_US_POSIX")
                let started = inFmt.date(from: startedAt) ?? Date()
                let duration = Int(Date().timeIntervalSince(started))

                var upd2: OpaquePointer?
                sqlite3_prepare_v2(db, "UPDATE time_log SET ended_at=?, duration_sec=? WHERE id=?", -1, &upd2, nil)
                sqlite3_bind_text(upd2, 1, now, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_int64(upd2, 2, sqlite3_int64(duration))
                sqlite3_bind_int64(upd2, 3, sqlite3_int64(entryId))
                sqlite3_step(upd2)
                sqlite3_finalize(upd2)
            } else {
                sqlite3_finalize(sel)
            }
        }
    }

    // MARK: - notes

    func listNotes(taskId: Int) -> [Note] {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT id, body_md, written_at FROM notes WHERE task_id=? ORDER BY id ASC", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, sqlite3_int64(taskId))
        var out: [Note] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Int(sqlite3_column_int64(stmt, 0))
            let body = textCol(stmt, 1)
            let written = textCol(stmt, 2)
            out.append(Note(id: id, taskId: taskId, bodyMd: body, writtenAt: written))
        }
        return out
    }

    func addNote(taskId: Int, body: String) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let now = nowISO()
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO notes (task_id, body_md, written_at) VALUES (?,?,?)", -1, &stmt, nil)
        sqlite3_bind_int64(stmt, 1, sqlite3_int64(taskId))
        sqlite3_bind_text(stmt, 2, trimmed, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 3, now, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    // MARK: - history

    func listStateHistory(taskId: Int) -> [StateChange] {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db,
            "SELECT id, from_status, to_status, changed_at FROM state_history WHERE task_id=? ORDER BY id ASC",
            -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, sqlite3_int64(taskId))
        var out: [StateChange] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Int(sqlite3_column_int64(stmt, 0))
            let from = textColOpt(stmt, 1)
            let to = textCol(stmt, 2)
            let at = textCol(stmt, 3)
            out.append(StateChange(id: id, taskId: taskId, fromStatus: from, toStatus: to, changedAt: at))
        }
        return out
    }
}
