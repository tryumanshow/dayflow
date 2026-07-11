import Foundation
import SQLite3

extension DayflowDB {
    // MARK: - full-text search
    //
    // A direct case-insensitive substring scan rather than FTS5. The dataset
    // is one row per written day (hundreds over years), so a `LIKE` scan is
    // sub-millisecond — and it matches Korean substrings correctly, which the
    // default `unicode61` FTS tokenizer (one token per CJK run) does not.

    struct DayNoteMatch {
        let date: Date
        let body: String
    }

    struct MonthPlanMatch {
        let monthKey: String
        let title: String
        let body: String
    }

    /// Escapes the LIKE metacharacters so a query containing `%` / `_` / `\`
    /// searches for those literal characters instead of acting as wildcards.
    private func likePattern(_ query: String) -> String {
        var escaped = ""
        for ch in query {
            if ch == "%" || ch == "_" || ch == "\\" { escaped.append("\\") }
            escaped.append(ch)
        }
        return "%\(escaped)%"
    }

    func searchDayNotes(_ query: String, limit: Int = 50) -> [DayNoteMatch] {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, """
            SELECT note_date, body_md FROM day_notes
            WHERE body_md LIKE ? ESCAPE '\\'
            ORDER BY note_date DESC
            LIMIT ?
        """, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, likePattern(query))
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var out: [DayNoteMatch] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let date = DF.ymd.date(from: textCol(stmt, 0)) else { continue }
            out.append(DayNoteMatch(date: date, body: textCol(stmt, 1)))
        }
        return out
    }

    /// Title-only appointment search. `startAt` doubles as the day the result
    /// navigates to.
    func searchAppointments(_ query: String, limit: Int = 50) -> [Appointment] {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, """
            SELECT id, start_at, end_at, title, note, category FROM appointments
            WHERE title LIKE ? ESCAPE '\\'
            ORDER BY start_at DESC
            LIMIT ?
        """, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, likePattern(query))
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var out: [Appointment] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let startAt = DF.appointmentStamp.date(from: textCol(stmt, 1)) ?? Date()
            let endAtRaw = textCol(stmt, 2)
            let endAt = endAtRaw.isEmpty ? nil : DF.appointmentStamp.date(from: endAtRaw)
            let noteRaw = textCol(stmt, 4)
            let category = AppointmentCategory(rawValue: textCol(stmt, 5)) ?? .event
            out.append(Appointment(id: id, startAt: startAt, endAt: endAt,
                                   title: textCol(stmt, 3), note: noteRaw.isEmpty ? nil : noteRaw,
                                   category: category))
        }
        return out
    }

    /// Month-plan sections match on title or body; the result navigates to the
    /// first day of the owning month.
    func searchMonthPlanSections(_ query: String, limit: Int = 50) -> [MonthPlanMatch] {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, """
            SELECT month_key, title, body_md FROM month_plan_sections
            WHERE (title LIKE ? ESCAPE '\\' OR body_md LIKE ? ESCAPE '\\')
            ORDER BY month_key DESC
            LIMIT ?
        """, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, likePattern(query))
        bindText(stmt, 2, likePattern(query))
        sqlite3_bind_int(stmt, 3, Int32(limit))
        var out: [MonthPlanMatch] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(MonthPlanMatch(monthKey: textCol(stmt, 0), title: textCol(stmt, 1), body: textCol(stmt, 2)))
        }
        return out
    }
}
