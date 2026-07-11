import Foundation
import SQLite3

extension DayflowDB {
    // MARK: - appointments (scheduled items)

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
            SELECT id, start_at, end_at, title, note, category
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

    /// Appointments starting after `after`, soonest first. Drives the
    /// notification scheduler, which needs the next few regardless of which
    /// month the UI happens to be showing.
    func upcomingAppointments(after: Date, limit: Int) -> [Appointment] {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, """
            SELECT id, start_at, end_at, title, note, category
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
            let endAtRaw = textCol(stmt, 2)
            let noteRaw = textCol(stmt, 4)
            out.append(Appointment(
                id: sqlite3_column_int64(stmt, 0),
                startAt: DF.appointmentStamp.date(from: textCol(stmt, 1)) ?? Date(),
                endAt: endAtRaw.isEmpty ? nil : DF.appointmentStamp.date(from: endAtRaw),
                title: textCol(stmt, 3),
                note: noteRaw.isEmpty ? nil : noteRaw,
                category: AppointmentCategory(rawValue: textCol(stmt, 5)) ?? .event
            ))
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
}
