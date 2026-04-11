import Foundation
import SQLite3

/// Thin wrapper around the Dayflow SQLite DB.
///
/// Stores only what the UI actually reads: one markdown body per day
/// (`day_notes`) and one LLM review per day (`reviews`). The older
/// `tasks` / `state_history` / `time_log` / `notes` / `month_plans`
/// tables were supporting code paths that no longer exist in the app, so
/// they are neither read nor created here.
///
/// Marked `@unchecked Sendable` because SQLite with `SQLITE_OPEN_FULLMUTEX`
/// serializes connection access internally, and all `DayflowDB.shared`
/// callers go through the main-actor store anyway. Swift 6 strict
/// concurrency can't see the SQLite-side lock, so the unchecked escape
/// hatch is the honest annotation.
final class DayflowDB: @unchecked Sendable {
    static let shared = DayflowDB()

    private var db: OpaquePointer?

    /// macOS standard per-app user-data location. Resolves to
    /// `~/Library/Application Support/Dayflow/dayflow.db` for the current
    /// user on every machine.
    static var defaultPath: String {
        let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        if let base = appSupport {
            return base.appendingPathComponent("Dayflow/dayflow.db").path
        }
        // Fallback if Application Support is inaccessible for some reason.
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Dayflow/dayflow.db")
            .path
    }

    init(path: String = DayflowDB.defaultPath) {
        let parent = (path as NSString).deletingLastPathComponent
        // 0o700 on the directory + 0o600 on the DB file — markdown notes
        // are private, so other local users shouldn't see them if the home
        // dir is ever loosened.
        try? FileManager.default.createDirectory(
            atPath: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            NSLog("dayflow: failed to open db at \(path)")
            return
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil)
        ensureSchema()
    }

    deinit {
        if db != nil { sqlite3_close(db) }
    }

    private func ensureSchema() {
        let ddl = """
        CREATE TABLE IF NOT EXISTS day_notes (
            note_date  TEXT PRIMARY KEY,
            body_md    TEXT NOT NULL,
            body_json  TEXT,
            updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS reviews (
            review_date  TEXT PRIMARY KEY,
            body_md      TEXT NOT NULL,
            generated_at TEXT NOT NULL
        );
        """
        sqlite3_exec(db, ddl, nil, nil, nil)
        // Migration for DBs created before `body_json` existed. `ADD COLUMN`
        // errors if the column already exists — we swallow that, the column
        // is the only thing we need and ensureSchema runs on every open.
        sqlite3_exec(db, "ALTER TABLE day_notes ADD COLUMN body_json TEXT", nil, nil, nil)
    }

    // MARK: - format helpers

    private func nowISO() -> String {
        DF.isoTimestamp.string(from: Date())
    }

    static func ymd(_ d: Date) -> String {
        DF.ymd.string(from: d)
    }

    private func textCol(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        if let cstr = sqlite3_column_text(stmt, idx) {
            return String(cString: cstr)
        }
        return ""
    }

    private static let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String) {
        sqlite3_bind_text(stmt, idx, value, -1, Self.TRANSIENT)
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

    /// Markdown is always present; `bodyJSON` is the BlockNote-native
    /// document tree as JSON. JSON carries styles that markdown can't
    /// represent (text/background color, underline) and is preferred on
    /// load when available. Passing `nil` explicitly nulls the JSON slot
    /// so callers who only have markdown (QuickThrow, Week checkbox
    /// toggle) force the editor to re-derive blocks from markdown.
    func saveDayNote(date: Date, body: String, bodyJSON: String? = nil) {
        let now = nowISO()
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, """
            INSERT INTO day_notes (note_date, body_md, body_json, updated_at) VALUES (?,?,?,?)
            ON CONFLICT(note_date) DO UPDATE SET
                body_md=excluded.body_md,
                body_json=excluded.body_json,
                updated_at=excluded.updated_at
        """, -1, &stmt, nil)
        bindText(stmt, 1, Self.ymd(date))
        bindText(stmt, 2, body)
        if let json = bodyJSON {
            bindText(stmt, 3, json)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        bindText(stmt, 4, now)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func getDayNoteJSON(date: Date) -> String? {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT body_json FROM day_notes WHERE note_date = ?", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, Self.ymd(date))
        if sqlite3_step(stmt) == SQLITE_ROW {
            if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return nil }
            let s = textCol(stmt, 0)
            return s.isEmpty ? nil : s
        }
        return nil
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

    /// Returns (open count, done count) for a markdown body.
    static func parseCheckboxes(_ body: String) -> (open: Int, done: Int) {
        var open = 0
        var done = 0
        for line in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            guard case let .task(checked, _) = MarkdownLine.parse(String(line)) ?? .plain(text: "") else { continue }
            if checked { done += 1 } else { open += 1 }
        }
        return (open, done)
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
}
