import Foundation
import SQLite3

/// One event as it arrives from Google Calendar, already flattened into
/// Dayflow's shape. `externalID` is what makes a re-sync idempotent.
struct MirroredAppointment: Equatable {
    let externalID: String
    let startAt: Date
    let endAt: Date?
    let title: String
    let note: String?
    let isAllDay: Bool
}

extension DayflowDB {
    // MARK: - appointments (scheduled items)

    /// Every column the `Appointment` model needs, in one place so the
    /// row decoder below can't drift out of step with the queries.
    private static let appointmentColumns = "id, start_at, end_at, title, note, category, source, all_day"

    private func decodeAppointment(_ stmt: OpaquePointer?) -> Appointment {
        let endAtRaw = textCol(stmt, 2)
        let noteRaw = textCol(stmt, 4)
        return Appointment(
            id: sqlite3_column_int64(stmt, 0),
            startAt: DF.appointmentStamp.date(from: textCol(stmt, 1)) ?? Date(),
            endAt: endAtRaw.isEmpty ? nil : DF.appointmentStamp.date(from: endAtRaw),
            title: textCol(stmt, 3),
            note: noteRaw.isEmpty ? nil : noteRaw,
            category: AppointmentCategory(rawValue: textCol(stmt, 5)) ?? .event,
            source: AppointmentSource(rawValue: textCol(stmt, 6)) ?? .local,
            isAllDay: sqlite3_column_int(stmt, 7) != 0
        )
    }

    /// Read every appointment whose `start_at` day-part falls inside
    /// `[start, end]` (inclusive). Ordered by start time.
    func getAppointments(start: Date, end: Date) -> [Appointment] {
        // Range is resolved inclusively at day granularity. Store uses
        // `yyyy-MM-ddTHH:mm`, so a BETWEEN on stringified bounds works.
        let startStr = Self.ymd(start) + "T00:00"
        let endStr = Self.ymd(end) + "T23:59"
        var stmt: OpaquePointer?
        // Half-open overlap with the window — pulls in spans whose
        // start_at sits before gridStart but still cross into it.
        sqlite3_prepare_v2(db, """
            SELECT \(Self.appointmentColumns)
            FROM appointments
            WHERE start_at <= ?
              AND COALESCE(end_at, start_at) >= ?
            ORDER BY start_at ASC, id ASC
        """, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, endStr)
        bindText(stmt, 2, startStr)

        var out: [Appointment] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(decodeAppointment(stmt))
        }
        return out
    }

    /// Appointments starting after `after`, soonest first. Drives the
    /// notification scheduler, which needs the next few regardless of which
    /// month the UI happens to be showing.
    func upcomingAppointments(after: Date, limit: Int) -> [Appointment] {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, """
            SELECT \(Self.appointmentColumns)
            FROM appointments
            WHERE start_at > ?
            ORDER BY start_at ASC, id ASC
            LIMIT ?
        """, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, DF.appointmentStamp.string(from: after))
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var out: [Appointment] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(decodeAppointment(stmt))
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

    // MARK: - mirrored (read-only) appointments

    /// Replace the mirrored set for `source` inside `[windowStart, windowEnd]`
    /// with exactly `events`.
    ///
    /// Scoped to a window rather than "delete every mirrored row" on purpose:
    /// the sync only *fetches* a window, so a blanket delete would silently
    /// drop mirrored events that sit outside it and never bring them back.
    ///
    /// Rows are upserted on `external_id`, so a row that survives a sync keeps
    /// its `id`. That matters — the id is what the Month rail's selection and
    /// the notification identifiers are keyed on, and churning it every 30
    /// minutes would make both flicker.
    func replaceMirroredAppointments(
        _ events: [MirroredAppointment],
        source: AppointmentSource,
        windowStart: Date,
        windowEnd: Date
    ) {
        guard source != .local else { return }
        let now = nowISO()
        let startStr = Self.ymd(windowStart) + "T00:00"
        let endStr = Self.ymd(windowEnd) + "T23:59"

        sqlite3_exec(db, "BEGIN", nil, nil, nil)

        // 1. Drop the mirrored rows in the window that Google no longer
        //    returns (deleted or moved out). Anything still present is
        //    re-inserted below and keeps its id via the upsert.
        //
        //    The `NOT IN` list is built from placeholders, not interpolated
        //    text: a Google calendar id is an address the user doesn't
        //    control the shape of, and it is not going anywhere near a
        //    string-concatenated statement.
        var del: OpaquePointer?
        let keepPlaceholders = Array(repeating: "?", count: events.count).joined(separator: ",")
        let keepClause = events.isEmpty ? "" : " AND external_id NOT IN (\(keepPlaceholders))"
        sqlite3_prepare_v2(db, """
            DELETE FROM appointments
            WHERE source = ?
              AND external_id IS NOT NULL
              AND start_at <= ?
              AND COALESCE(end_at, start_at) >= ?
              \(keepClause)
        """, -1, &del, nil)
        bindText(del, 1, source.rawValue)
        bindText(del, 2, endStr)
        bindText(del, 3, startStr)
        for (i, e) in events.enumerated() {
            bindText(del, Int32(4 + i), e.externalID)
        }
        sqlite3_step(del)
        sqlite3_finalize(del)

        // 2. Upsert everything Google gave us.
        for e in events {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, """
                INSERT INTO appointments
                    (start_at, end_at, title, note, category, source, external_id, all_day, created_at, updated_at)
                VALUES (?, ?, ?, ?, 'event', ?, ?, ?, ?, ?)
                -- The unique index on external_id is PARTIAL, and SQLite makes
                -- the upsert target repeat the index's WHERE clause verbatim or
                -- it won't match — without it every INSERT fails outright.
                ON CONFLICT(external_id) WHERE external_id IS NOT NULL DO UPDATE SET
                    start_at   = excluded.start_at,
                    end_at     = excluded.end_at,
                    title      = excluded.title,
                    note       = excluded.note,
                    all_day    = excluded.all_day,
                    updated_at = excluded.updated_at
            """, -1, &stmt, nil)
            bindText(stmt, 1, DF.appointmentStamp.string(from: e.startAt))
            bindTextOrNull(stmt, 2, e.endAt.map { DF.appointmentStamp.string(from: $0) })
            bindText(stmt, 3, e.title)
            bindTextOrNull(stmt, 4, e.note)
            bindText(stmt, 5, source.rawValue)
            bindText(stmt, 6, e.externalID)
            sqlite3_bind_int(stmt, 7, e.isAllDay ? 1 : 0)
            bindText(stmt, 8, now)
            bindText(stmt, 9, now)
            // A silently-failing upsert looks exactly like "Google returned
            // nothing", which is the last thing you want to be debugging.
            if sqlite3_step(stmt) != SQLITE_DONE {
                NSLog("dayflow: failed to mirror \(e.externalID): \(String(cString: sqlite3_errmsg(db)))")
            }
            sqlite3_finalize(stmt)
        }

        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    /// Forget every mirrored row for `source`. Used when the account is
    /// disconnected — the reason to disconnect is usually "get this out of my
    /// calendar", so leaving stale copies behind would be the wrong read.
    func deleteMirroredAppointments(source: AppointmentSource) {
        guard source != .local else { return }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "DELETE FROM appointments WHERE source = ?", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, source.rawValue)
        sqlite3_step(stmt)
    }

    func mirroredAppointmentCount(source: AppointmentSource) -> Int {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM appointments WHERE source = ?", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, source.rawValue)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }
}
