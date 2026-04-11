import Foundation
import SQLite3

/// Thin wrapper around the dayflow SQLite DB.
///
/// Talks to the same file at `~/dayflow/dayflow.db` that the Python data layer
/// initialises. WAL mode lets the Swift app read/write concurrently.
final class DayflowDB {
    static let shared = DayflowDB()

    private var db: OpaquePointer?

    static var defaultPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("dayflow/dayflow.db").path
    }

    init(path: String = DayflowDB.defaultPath) {
        // Make sure the parent dir exists if the user has never run Python.
        let parent = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)

        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            NSLog("dayflow: failed to open db at \(path)")
            return
        }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil)
        ensureSchema()
    }

    deinit {
        if db != nil { sqlite3_close(db) }
    }

    /// Idempotent — mirrors `src/dayflow/data/schema.py`. Either side may run first.
    private func ensureSchema() {
        let ddl = """
        CREATE TABLE IF NOT EXISTS tasks (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            title       TEXT    NOT NULL,
            status      TEXT    NOT NULL DEFAULT 'TODO',
            inbox_at    TEXT    NOT NULL,
            due_date    TEXT,
            updated_at  TEXT    NOT NULL
        );
        CREATE TABLE IF NOT EXISTS state_history (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id     INTEGER NOT NULL,
            from_status TEXT,
            to_status   TEXT    NOT NULL,
            changed_at  TEXT    NOT NULL,
            FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS time_log (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id      INTEGER NOT NULL,
            started_at   TEXT    NOT NULL,
            ended_at     TEXT,
            duration_sec INTEGER,
            FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS notes (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id    INTEGER NOT NULL,
            body_md    TEXT    NOT NULL,
            written_at TEXT    NOT NULL,
            FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS reviews (
            review_date  TEXT PRIMARY KEY,
            body_md      TEXT NOT NULL,
            generated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS month_plans (
            year_month TEXT PRIMARY KEY,
            body_md    TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_tasks_due_date ON tasks(due_date);
        CREATE INDEX IF NOT EXISTS idx_tasks_inbox_at ON tasks(inbox_at);
        """
        sqlite3_exec(db, ddl, nil, nil, nil)
    }

    // MARK: - format helpers

    private func nowISO() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    static func ymd(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }

    static func ym(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
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

    private static let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String) {
        sqlite3_bind_text(stmt, idx, value, -1, Self.TRANSIENT)
    }

    // MARK: - tasks

    /// A task "belongs to" a date when its due_date matches OR (no due_date set
    /// and its inbox_at falls on that date). This means quick `inb` throws
    /// always show on the day they were thrown.
    func listForDate(_ d: Date) -> [Task] {
        let dateStr = Self.ymd(d)
        let sql = """
        SELECT id, title, status, inbox_at, due_date, updated_at
        FROM tasks
        WHERE due_date = ?
           OR (due_date IS NULL AND substr(inbox_at, 1, 10) = ?)
        ORDER BY
          CASE status WHEN 'DOING' THEN 0 WHEN 'TODO' THEN 1
                      WHEN 'DONE' THEN 2 ELSE 3 END,
          id ASC;
        """
        return runTaskQuery(sql) { stmt in
            self.bindText(stmt, 1, dateStr)
            self.bindText(stmt, 2, dateStr)
        }
    }

    /// All tasks that fall in [start, end] inclusive. Used by week and month grids.
    func listForRange(start: Date, end: Date) -> [Task] {
        let s = Self.ymd(start)
        let e = Self.ymd(end)
        let sql = """
        SELECT id, title, status, inbox_at, due_date, updated_at
        FROM tasks
        WHERE (due_date IS NOT NULL AND due_date BETWEEN ? AND ?)
           OR (due_date IS NULL AND substr(inbox_at, 1, 10) BETWEEN ? AND ?)
        ORDER BY
          CASE status WHEN 'DOING' THEN 0 WHEN 'TODO' THEN 1
                      WHEN 'DONE' THEN 2 ELSE 3 END,
          id ASC;
        """
        return runTaskQuery(sql) { stmt in
            self.bindText(stmt, 1, s)
            self.bindText(stmt, 2, e)
            self.bindText(stmt, 3, s)
            self.bindText(stmt, 4, e)
        }
    }

    private func runTaskQuery(_ sql: String, bind: (OpaquePointer?) -> Void) -> [Task] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        var out: [Task] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Int(sqlite3_column_int64(stmt, 0))
            let title = textCol(stmt, 1)
            let status = TaskStatus(rawValue: textCol(stmt, 2)) ?? .todo
            let inboxAt = textCol(stmt, 3)
            let due = textColOpt(stmt, 4)
            let updated = textCol(stmt, 5)
            out.append(Task(id: id, title: title, status: status, inboxAt: inboxAt, dueDate: due, updatedAt: updated))
        }
        return out
    }

    @discardableResult
    func addTask(title: String, dueDate: Date? = nil) -> Task? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let now = nowISO()
        let dueStr = dueDate.map { Self.ymd($0) }

        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        defer { sqlite3_exec(db, "COMMIT", nil, nil, nil) }

        var stmt: OpaquePointer?
        let insertSQL = """
        INSERT INTO tasks (title, status, inbox_at, due_date, updated_at)
        VALUES (?, 'TODO', ?, ?, ?);
        """
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else { return nil }
        bindText(stmt, 1, trimmed)
        bindText(stmt, 2, now)
        if let d = dueStr {
            bindText(stmt, 3, d)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        bindText(stmt, 4, now)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            sqlite3_finalize(stmt)
            return nil
        }
        sqlite3_finalize(stmt)
        let taskId = Int(sqlite3_last_insert_rowid(db))

        var hist: OpaquePointer?
        sqlite3_prepare_v2(db,
            "INSERT INTO state_history (task_id, from_status, to_status, changed_at) VALUES (?, NULL, 'TODO', ?)",
            -1, &hist, nil)
        sqlite3_bind_int64(hist, 1, sqlite3_int64(taskId))
        bindText(hist, 2, now)
        sqlite3_step(hist)
        sqlite3_finalize(hist)

        return Task(id: taskId, title: trimmed, status: .todo, inboxAt: now, dueDate: dueStr, updatedAt: now)
    }

    func deleteTask(_ taskId: Int) {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "DELETE FROM tasks WHERE id = ?", -1, &stmt, nil)
        sqlite3_bind_int64(stmt, 1, sqlite3_int64(taskId))
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func setDueDate(_ taskId: Int, to date: Date?) {
        let now = nowISO()
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "UPDATE tasks SET due_date=?, updated_at=? WHERE id=?", -1, &stmt, nil)
        if let d = date {
            bindText(stmt, 1, Self.ymd(d))
        } else {
            sqlite3_bind_null(stmt, 1)
        }
        bindText(stmt, 2, now)
        sqlite3_bind_int64(stmt, 3, sqlite3_int64(taskId))
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
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
        bindText(upd, 1, newStatus.rawValue)
        bindText(upd, 2, now)
        sqlite3_bind_int64(upd, 3, sqlite3_int64(taskId))
        sqlite3_step(upd)
        sqlite3_finalize(upd)

        var hist: OpaquePointer?
        sqlite3_prepare_v2(db,
            "INSERT INTO state_history (task_id, from_status, to_status, changed_at) VALUES (?,?,?,?)",
            -1, &hist, nil)
        sqlite3_bind_int64(hist, 1, sqlite3_int64(taskId))
        bindText(hist, 2, current.rawValue)
        bindText(hist, 3, newStatus.rawValue)
        bindText(hist, 4, now)
        sqlite3_step(hist)
        sqlite3_finalize(hist)

        // time_log: opening DOING starts a timer; leaving DOING closes it.
        if newStatus == .doing && current != .doing {
            var t: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO time_log (task_id, started_at) VALUES (?, ?)", -1, &t, nil)
            sqlite3_bind_int64(t, 1, sqlite3_int64(taskId))
            bindText(t, 2, now)
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
                bindText(upd2, 1, now)
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
        bindText(stmt, 2, trimmed)
        bindText(stmt, 3, now)
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

    // MARK: - reviews (LLM daily review)

    func getReview(date: Date) -> String? {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT body_md FROM reviews WHERE review_date = ?", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, Self.ymd(date))
        if sqlite3_step(stmt) == SQLITE_ROW {
            return textCol(stmt, 0)
        }
        return nil
    }

    func saveReview(date: Date, body: String) {
        let now = nowISO()
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, """
            INSERT INTO reviews (review_date, body_md, generated_at) VALUES (?,?,?)
            ON CONFLICT(review_date) DO UPDATE SET body_md=excluded.body_md, generated_at=excluded.generated_at
        """, -1, &stmt, nil)
        bindText(stmt, 1, Self.ymd(date))
        bindText(stmt, 2, body)
        bindText(stmt, 3, now)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    // MARK: - month plans

    func getMonthPlan(yearMonth: String) -> String {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT body_md FROM month_plans WHERE year_month = ?", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, yearMonth)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return textCol(stmt, 0)
        }
        return ""
    }

    func saveMonthPlan(yearMonth: String, body: String) {
        let now = nowISO()
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, """
            INSERT INTO month_plans (year_month, body_md, updated_at) VALUES (?,?,?)
            ON CONFLICT(year_month) DO UPDATE SET body_md=excluded.body_md, updated_at=excluded.updated_at
        """, -1, &stmt, nil)
        bindText(stmt, 1, yearMonth)
        bindText(stmt, 2, body)
        bindText(stmt, 3, now)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }
}
