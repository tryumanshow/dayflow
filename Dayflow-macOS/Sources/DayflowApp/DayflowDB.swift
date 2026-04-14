import Foundation
import SQLite3

/// A single section inside a month plan. Each month can have
/// multiple sections (e.g. Career, Finance, Health).
struct MonthPlanSection: Identifiable, Equatable {
    let id: Int64
    var title: String
    var sortOrder: Int
    var bodyMd: String
    var bodyJSON: String?
}

/// Category tag for appointments — drives the colored dot in month/week views.
enum AppointmentCategory: String, CaseIterable, Identifiable, Codable {
    case event
    case weekly
    case monthly
    case reminder
    case important

    var id: String { rawValue }

    var label: String {
        switch self {
        case .event:     return L("apt_cat.event")
        case .weekly:    return L("apt_cat.weekly")
        case .monthly:   return L("apt_cat.monthly")
        case .reminder:  return L("apt_cat.reminder")
        case .important: return L("apt_cat.important")
        }
    }
}

/// A single scheduled item (meeting, appointment, time-stamped
/// reminder). `startAt` is always local wall-clock; we don't track
/// timezones — this is a personal per-machine planner.
struct Appointment: Identifiable, Equatable {
    let id: Int64
    let startAt: Date
    let endAt: Date?
    let title: String
    let note: String?
    let category: AppointmentCategory
}

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
        CREATE TABLE IF NOT EXISTS month_plans (
            month_key  TEXT PRIMARY KEY,
            body_md    TEXT NOT NULL,
            body_json  TEXT,
            updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS appointments (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            start_at    TEXT NOT NULL,
            end_at      TEXT,
            title       TEXT NOT NULL,
            note        TEXT,
            category    TEXT NOT NULL DEFAULT 'event',
            created_at  TEXT NOT NULL,
            updated_at  TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_appointments_start ON appointments(start_at);
        CREATE TABLE IF NOT EXISTS month_plan_sections (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            month_key   TEXT NOT NULL,
            title       TEXT NOT NULL,
            sort_order  INTEGER NOT NULL DEFAULT 0,
            body_md     TEXT NOT NULL DEFAULT '',
            body_json   TEXT,
            updated_at  TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_mps_month ON month_plan_sections(month_key);
        """
        sqlite3_exec(db, ddl, nil, nil, nil)
        migrate()
    }

    /// SQLite `user_version` based migration. Each step runs inside
    /// a transaction so a crash between `DROP` / `CREATE` / `PRAGMA
    /// user_version` can't leave the DB in a half-migrated state.
    private func migrate() {
        var current: Int32 = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK,
           sqlite3_step(stmt) == SQLITE_ROW {
            current = sqlite3_column_int(stmt, 0)
        }
        sqlite3_finalize(stmt)

        if current < 1 {
            runMigrationStep(version: 1, sql: """
                ALTER TABLE day_notes ADD COLUMN body_json TEXT;
            """)
        }
        if current < 2 {
            // v2: month_plans. The table is already created by the
            // `CREATE TABLE IF NOT EXISTS` in `ensureSchema` on every
            // open, so this migration is a no-op besides the version
            // bump. Kept as a discrete step so the sequence numbers
            // stay monotone for existing DBs.
            runMigrationStep(version: 2, sql: "")
        }
        if current < 3 {
            runMigrationStep(version: 3, sql: """
                CREATE TABLE IF NOT EXISTS appointments (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    start_at    TEXT NOT NULL,
                    end_at      TEXT,
                    title       TEXT NOT NULL,
                    note        TEXT,
                    created_at  TEXT NOT NULL,
                    updated_at  TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_appointments_start ON appointments(start_at);
            """)
        }
        if current < 4 {
            // v4: legacy ancient-app-version `month_plans` had a
            // `year_month` key. v2's `CREATE TABLE IF NOT EXISTS`
            // was a no-op on those DBs, leaving month-plan writes
            // silently broken. Drop + recreate. Feature shipped
            // publicly for the first time in v0.1.3 so no end-user
            // data is at risk.
            runMigrationStep(version: 4, sql: """
                DROP TABLE IF EXISTS month_plans;
                CREATE TABLE month_plans (
                    month_key  TEXT PRIMARY KEY,
                    body_md    TEXT NOT NULL,
                    body_json  TEXT,
                    updated_at TEXT NOT NULL
                );
            """)
        }
        if current < 5 {
            runMigrationStep(version: 5, sql: """
                ALTER TABLE appointments ADD COLUMN category TEXT NOT NULL DEFAULT 'event';
            """)
        }
        if current < 6 {
            // Rename old frequency-based categories to purpose-based ones.
            runMigrationStep(version: 6, sql: """
                UPDATE appointments SET category = 'event' WHERE category IN ('oneTime', 'personal', 'other', 'meeting', 'deadline', 'plans', 'routine');
                UPDATE appointments SET category = 'weekly' WHERE category IN ('social');
            """)
        }
        if current < 7 {
            // v7: multi-section month plans. Migrate existing
            // month_plans rows into the new sections table.
            runMigrationStep(version: 7, sql: """
                CREATE TABLE IF NOT EXISTS month_plan_sections (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    month_key   TEXT NOT NULL,
                    title       TEXT NOT NULL,
                    sort_order  INTEGER NOT NULL DEFAULT 0,
                    body_md     TEXT NOT NULL DEFAULT '',
                    body_json   TEXT,
                    updated_at  TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_mps_month ON month_plan_sections(month_key);
                INSERT INTO month_plan_sections (month_key, title, sort_order, body_md, body_json, updated_at)
                    SELECT month_key, '계획', 0, body_md, body_json, updated_at
                    FROM month_plans WHERE body_md != '';
            """)
        }
    }

    /// Run one migration step inside a `BEGIN ... COMMIT` block,
    /// bumping `user_version` last so a mid-step crash rolls the
    /// whole thing back and the next launch retries from scratch.
    /// `sql` may be empty for version-bump-only steps.
    private func runMigrationStep(version: Int32, sql: String) {
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        var err: UnsafeMutablePointer<CChar>?
        if !sql.isEmpty {
            if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
                let msg = err.map { String(cString: $0) } ?? "(no message)"
                sqlite3_free(err)
                NSLog("dayflow: migration v\(version) failed: \(msg)")
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                return
            }
        }
        sqlite3_exec(db, "PRAGMA user_version = \(version)", nil, nil, nil)
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    // MARK: - format helpers

    private func nowISO() -> String {
        DF.isoTimestamp.string(from: Date())
    }

    static func ymd(_ d: Date) -> String {
        DF.ymd.string(from: d)
    }

    /// `yyyy-MM` — month-plans primary key. Month-boundary is whatever
    /// the user's current calendar thinks, same as the Month view grid.
    static func monthKey(_ d: Date) -> String {
        DF.monthKey.string(from: d)
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

    private func bindTextOrNull(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, idx, value, -1, Self.TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    // MARK: - body-row helpers

    /// Generic "one key → (markdown, optional JSON)" read shared by
    /// `day_notes` and `month_plans`. Both tables have the same
    /// `(key TEXT PK, body_md TEXT NOT NULL, body_json TEXT, updated_at TEXT)`
    /// shape so a single helper keeps them in lockstep.
    private func getBodyRow(table: String, keyColumn: String, key: String) -> (body: String, bodyJSON: String?) {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT body_md, body_json FROM \(table) WHERE \(keyColumn) = ?", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return ("", nil) }
        let md = textCol(stmt, 0)
        let json = textCol(stmt, 1)
        return (md, json.isEmpty ? nil : json)
    }

    /// Generic UPSERT sibling to `getBodyRow`. `bodyJSON: nil` explicitly
    /// nulls the JSON slot — markdown-only callers (QuickThrow, Week
    /// checkbox toggle) rely on this to force the editor to re-derive
    /// blocks from markdown, dropping rich styles on the affected row.
    private func upsertBodyRow(table: String, keyColumn: String, key: String, body: String, bodyJSON: String?) {
        let now = nowISO()
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, """
            INSERT INTO \(table) (\(keyColumn), body_md, body_json, updated_at) VALUES (?,?,?,?)
            ON CONFLICT(\(keyColumn)) DO UPDATE SET
                body_md=excluded.body_md,
                body_json=excluded.body_json,
                updated_at=excluded.updated_at
        """, -1, &stmt, nil)
        bindText(stmt, 1, key)
        bindText(stmt, 2, body)
        bindTextOrNull(stmt, 3, bodyJSON)
        bindText(stmt, 4, now)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    // MARK: - day notes

    /// Markdown-only read path — used by Week/Month aggregators,
    /// QuickThrow, and the review generator, none of which care about
    /// rich styles.
    func getDayNote(date: Date) -> String {
        getDayNoteFull(date: date).body
    }

    func getDayNoteFull(date: Date) -> (body: String, bodyJSON: String?) {
        getBodyRow(table: "day_notes", keyColumn: "note_date", key: Self.ymd(date))
    }

    func saveDayNote(date: Date, body: String, bodyJSON: String? = nil) {
        upsertBodyRow(table: "day_notes", keyColumn: "note_date", key: Self.ymd(date), body: body, bodyJSON: bodyJSON)
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

    // MARK: - month plan sections

    func getMonthPlanSections(date: Date) -> [MonthPlanSection] {
        let key = Self.monthKey(date)
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, """
            SELECT id, title, sort_order, body_md, body_json
            FROM month_plan_sections WHERE month_key = ?
            ORDER BY sort_order
        """, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        var rows: [MonthPlanSection] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let json = textCol(stmt, 4)
            rows.append(MonthPlanSection(
                id: sqlite3_column_int64(stmt, 0),
                title: textCol(stmt, 1),
                sortOrder: Int(sqlite3_column_int(stmt, 2)),
                bodyMd: textCol(stmt, 3),
                bodyJSON: json.isEmpty ? nil : json
            ))
        }
        return rows
    }

    @discardableResult
    func addMonthPlanSection(date: Date, title: String, sortOrder: Int) -> Int64 {
        let key = Self.monthKey(date)
        let now = nowISO()
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, """
            INSERT INTO month_plan_sections (month_key, title, sort_order, body_md, body_json, updated_at)
            VALUES (?,?,?,?,?,?)
        """, -1, &stmt, nil)
        bindText(stmt, 1, key)
        bindText(stmt, 2, title)
        sqlite3_bind_int(stmt, 3, Int32(sortOrder))
        bindText(stmt, 4, "")
        sqlite3_bind_null(stmt, 5)
        bindText(stmt, 6, now)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        return sqlite3_last_insert_rowid(db)
    }

    func updateMonthPlanSection(id: Int64, body: String, bodyJSON: String?) {
        let now = nowISO()
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, """
            UPDATE month_plan_sections SET body_md = ?, body_json = ?, updated_at = ? WHERE id = ?
        """, -1, &stmt, nil)
        bindText(stmt, 1, body)
        bindTextOrNull(stmt, 2, bodyJSON)
        bindText(stmt, 3, now)
        sqlite3_bind_int64(stmt, 4, id)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func renameMonthPlanSection(id: Int64, title: String) {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "UPDATE month_plan_sections SET title = ?, updated_at = ? WHERE id = ?", -1, &stmt, nil)
        bindText(stmt, 1, title)
        bindText(stmt, 2, nowISO())
        sqlite3_bind_int64(stmt, 3, id)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func deleteMonthPlanSection(id: Int64) {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "DELETE FROM month_plan_sections WHERE id = ?", -1, &stmt, nil)
        sqlite3_bind_int64(stmt, 1, id)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    // MARK: - appointments (scheduled items)

    /// Read every appointment whose `start_at` day-part falls inside
    /// `[start, end]` (inclusive). Ordered by start time.
    func getAppointments(start: Date, end: Date) -> [Appointment] {
        // Range is resolved inclusively at day granularity. Store uses
        // `yyyy-MM-ddTHH:mm`, so a BETWEEN on stringified bounds works.
        let startStr = Self.ymd(start) + "T00:00"
        let endStr = Self.ymd(end) + "T23:59"
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, """
            SELECT id, start_at, end_at, title, note, category
            FROM appointments
            WHERE start_at BETWEEN ? AND ?
            ORDER BY start_at ASC, id ASC
        """, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, startStr)
        bindText(stmt, 2, endStr)

        var out: [Appointment] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let startAt = DF.appointmentStamp.date(from: textCol(stmt, 1)) ?? Date()
            let endAtRaw = textCol(stmt, 2)
            let endAt = endAtRaw.isEmpty ? nil : DF.appointmentStamp.date(from: endAtRaw)
            let title = textCol(stmt, 3)
            let noteRaw = textCol(stmt, 4)
            let note = noteRaw.isEmpty ? nil : noteRaw
            let catRaw = textCol(stmt, 5)
            let category = AppointmentCategory(rawValue: catRaw) ?? .event
            out.append(Appointment(id: id, startAt: startAt, endAt: endAt, title: title, note: note, category: category))
        }
        return out
    }

    /// Returns the newly-inserted row id, or -1 on failure.
    @discardableResult
    func insertAppointment(startAt: Date, endAt: Date?, title: String, note: String?, category: AppointmentCategory = .event) -> Int64 {
        let now = nowISO()
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, """
            INSERT INTO appointments (start_at, end_at, title, note, category, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, DF.appointmentStamp.string(from: startAt))
        bindTextOrNull(stmt, 2, endAt.map { DF.appointmentStamp.string(from: $0) })
        bindText(stmt, 3, title)
        bindTextOrNull(stmt, 4, note)
        bindText(stmt, 5, category.rawValue)
        bindText(stmt, 6, now)
        bindText(stmt, 7, now)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return -1 }
        return sqlite3_last_insert_rowid(db)
    }

    func deleteAppointment(id: Int64) {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "DELETE FROM appointments WHERE id = ?", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        sqlite3_step(stmt)
    }

    func updateAppointment(id: Int64, startAt: Date, endAt: Date?, title: String, note: String?, category: AppointmentCategory) {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, """
            UPDATE appointments
            SET start_at = ?, end_at = ?, title = ?, note = ?, category = ?, updated_at = ?
            WHERE id = ?
        """, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, DF.appointmentStamp.string(from: startAt))
        bindTextOrNull(stmt, 2, endAt.map { DF.appointmentStamp.string(from: $0) })
        bindText(stmt, 3, title)
        bindTextOrNull(stmt, 4, note)
        bindText(stmt, 5, category.rawValue)
        bindText(stmt, 6, nowISO())
        sqlite3_bind_int64(stmt, 7, id)
        sqlite3_step(stmt)
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
