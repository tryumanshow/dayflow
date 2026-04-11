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
            updated_at  TEXT    NOT NULL,
            parent_id   INTEGER REFERENCES tasks(id) ON DELETE CASCADE
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
        CREATE TABLE IF NOT EXISTS day_notes (
            note_date  TEXT PRIMARY KEY,
            body_md    TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_tasks_due_date ON tasks(due_date);
        CREATE INDEX IF NOT EXISTS idx_tasks_inbox_at ON tasks(inbox_at);
        """
        sqlite3_exec(db, ddl, nil, nil, nil)

        // migration: add parent_id if an older DB lacks it
        var hasParentId = false
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "PRAGMA table_info(tasks)", -1, &stmt, nil)
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cstr = sqlite3_column_text(stmt, 1),
               String(cString: cstr) == "parent_id" {
                hasParentId = true
                break
            }
        }
        sqlite3_finalize(stmt)
        if !hasParentId {
            sqlite3_exec(db,
                "ALTER TABLE tasks ADD COLUMN parent_id INTEGER REFERENCES tasks(id) ON DELETE CASCADE",
                nil, nil, nil)
        }
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_tasks_parent ON tasks(parent_id)", nil, nil, nil)

        // Binary status migration: collapse legacy DOING/WONT.
        sqlite3_exec(db, "UPDATE tasks SET status='TODO' WHERE status='DOING'", nil, nil, nil)
        sqlite3_exec(db, "UPDATE tasks SET status='DONE' WHERE status='WONT'", nil, nil, nil)
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

    private func intColOpt(_ stmt: OpaquePointer?, _ idx: Int32) -> Int? {
        if sqlite3_column_type(stmt, idx) == SQLITE_NULL { return nil }
        return Int(sqlite3_column_int64(stmt, idx))
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
        SELECT id, title, status, inbox_at, due_date, updated_at, parent_id
        FROM tasks
        WHERE due_date = ?
           OR (due_date IS NULL AND substr(inbox_at, 1, 10) = ?)
        ORDER BY
          CASE WHEN parent_id IS NULL THEN id ELSE parent_id END,
          parent_id IS NULL DESC,
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
        SELECT id, title, status, inbox_at, due_date, updated_at, parent_id
        FROM tasks
        WHERE (due_date IS NOT NULL AND due_date BETWEEN ? AND ?)
           OR (due_date IS NULL AND substr(inbox_at, 1, 10) BETWEEN ? AND ?)
        ORDER BY
          CASE WHEN parent_id IS NULL THEN id ELSE parent_id END,
          parent_id IS NULL DESC,
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
            let status = TaskStatus.parse(textCol(stmt, 2))
            let inboxAt = textCol(stmt, 3)
            let due = textColOpt(stmt, 4)
            let updated = textCol(stmt, 5)
            let parentId = intColOpt(stmt, 6)
            out.append(Task(id: id, title: title, status: status, inboxAt: inboxAt, dueDate: due, updatedAt: updated, parentId: parentId))
        }
        return out
    }

    func updateTitle(_ taskId: Int, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = nowISO()
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "UPDATE tasks SET title=?, updated_at=? WHERE id=?", -1, &stmt, nil)
        bindText(stmt, 1, trimmed)
        bindText(stmt, 2, now)
        sqlite3_bind_int64(stmt, 3, sqlite3_int64(taskId))
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    @discardableResult
    func addTask(title: String, dueDate: Date? = nil, parentId: Int? = nil) -> Task? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let now = nowISO()
        let dueStr = dueDate.map { Self.ymd($0) }

        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        defer { sqlite3_exec(db, "COMMIT", nil, nil, nil) }

        var stmt: OpaquePointer?
        let insertSQL = """
        INSERT INTO tasks (title, status, inbox_at, due_date, updated_at, parent_id)
        VALUES (?, 'TODO', ?, ?, ?, ?);
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
        if let pid = parentId {
            sqlite3_bind_int64(stmt, 5, sqlite3_int64(pid))
        } else {
            sqlite3_bind_null(stmt, 5)
        }
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

        return Task(id: taskId, title: trimmed, status: .todo, inboxAt: now, dueDate: dueStr, updatedAt: now, parentId: parentId)
    }

    func setParent(_ taskId: Int, parentId: Int?) {
        let now = nowISO()
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "UPDATE tasks SET parent_id=?, updated_at=? WHERE id=?", -1, &stmt, nil)
        if let pid = parentId {
            sqlite3_bind_int64(stmt, 1, sqlite3_int64(pid))
        } else {
            sqlite3_bind_null(stmt, 1)
        }
        bindText(stmt, 2, now)
        sqlite3_bind_int64(stmt, 3, sqlite3_int64(taskId))
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
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

    func setStatus(_ taskId: Int, to newStatus: TaskStatus) {
        let now = nowISO()
        var current: TaskStatus = .todo
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT status FROM tasks WHERE id = ?", -1, &stmt, nil)
        sqlite3_bind_int64(stmt, 1, sqlite3_int64(taskId))
        if sqlite3_step(stmt) == SQLITE_ROW {
            current = TaskStatus.parse(textCol(stmt, 0))
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

        // Light audit trail — useful for the LLM review feature.
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
    }

    /// Convenience wrapper used by row checkbox click.
    func toggleDone(_ taskId: Int) {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT status FROM tasks WHERE id = ?", -1, &stmt, nil)
        sqlite3_bind_int64(stmt, 1, sqlite3_int64(taskId))
        var current: TaskStatus = .todo
        if sqlite3_step(stmt) == SQLITE_ROW {
            current = TaskStatus.parse(textCol(stmt, 0))
        }
        sqlite3_finalize(stmt)
        setStatus(taskId, to: current.toggled)
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

    // MARK: - time log

    func listTimeEntries(taskId: Int) -> [TimeEntry] {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db,
            "SELECT id, started_at, ended_at, duration_sec FROM time_log WHERE task_id=? ORDER BY id ASC",
            -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, sqlite3_int64(taskId))
        var out: [TimeEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Int(sqlite3_column_int64(stmt, 0))
            let started = textCol(stmt, 1)
            let ended = textColOpt(stmt, 2)
            let dur = intColOpt(stmt, 3)
            out.append(TimeEntry(id: id, taskId: taskId, startedAt: started, endedAt: ended, durationSec: dur))
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

    // MARK: - day notes (markdown body per day)

    func getDayNote(date: Date) -> String {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT body_md FROM day_notes WHERE note_date = ?", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, Self.ymd(date))
        if sqlite3_step(stmt) == SQLITE_ROW {
            return textCol(stmt, 0)
        }
        return ""
    }

    func saveDayNote(date: Date, body: String) {
        let now = nowISO()
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, """
            INSERT INTO day_notes (note_date, body_md, updated_at) VALUES (?,?,?)
            ON CONFLICT(note_date) DO UPDATE SET body_md=excluded.body_md, updated_at=excluded.updated_at
        """, -1, &stmt, nil)
        bindText(stmt, 1, Self.ymd(date))
        bindText(stmt, 2, body)
        bindText(stmt, 3, now)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    /// Returns (open count, done count) for a body that may use either the
    /// canonical markdown form (`- [ ]` / `- [x]`) or the rendered glyph form
    /// (`☐` / `☑`) emitted by MarkdownEditor.
    static func parseCheckboxes(_ body: String) -> (open: Int, done: Int) {
        var open = 0
        var done = 0
        for line in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.hasPrefix("☐") { open += 1; continue }
            if trimmed.hasPrefix("☑") { done += 1; continue }
            guard trimmed.count >= 5 else { continue }
            let bullet = trimmed.first!
            guard bullet == "-" || bullet == "*" || bullet == "+" else { continue }
            let after = trimmed.dropFirst()
            guard after.first == " " else { continue }
            let rest = after.dropFirst()
            guard rest.hasPrefix("[") else { continue }
            let inside = rest.dropFirst()
            guard inside.count >= 2 else { continue }
            let mark = inside.first!
            let close = inside.index(after: inside.startIndex)
            guard inside[close] == "]" else { continue }
            switch mark {
            case " ":              open += 1
            case "x", "X", "✓":    done += 1
            default: break
            }
        }
        return (open, done)
    }

    /// Bulk loader — pull every day note in [start, end] (inclusive) so the
    /// month/week views can compute counts without N round-trips.
    func loadDayNoteRange(start: Date, end: Date) -> [String: String] {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db,
            "SELECT note_date, body_md FROM day_notes WHERE note_date BETWEEN ? AND ?",
            -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, Self.ymd(start))
        bindText(stmt, 2, Self.ymd(end))
        var out: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let date = textCol(stmt, 0)
            let body = textCol(stmt, 1)
            out[date] = body
        }
        return out
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
