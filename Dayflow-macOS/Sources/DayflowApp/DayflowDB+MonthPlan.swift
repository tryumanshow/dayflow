import Foundation
import SQLite3

extension DayflowDB {
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
        // Snapshot the current row into history BEFORE overwriting whenever
        // we'd be dropping non-empty content into a different body. The
        // BlockNote↔Swift binding race can flush an empty doc back to disk
        // (see `month_plan_section_history` migration v8); this guarantees
        // every prior version stays recoverable even if the editor wipes
        // itself. Snapshot is skipped when body+JSON match exactly so
        // idempotent re-saves (e.g. lossless markdown round-trip after
        // initial load) don't churn history.
        var existingMd: String = ""
        var existingJSON: String? = nil
        var read: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT body_md, body_json FROM month_plan_sections WHERE id = ?", -1, &read, nil) == SQLITE_OK {
            sqlite3_bind_int64(read, 1, id)
            if sqlite3_step(read) == SQLITE_ROW {
                existingMd = textCol(read, 0)
                let j = textCol(read, 1)
                existingJSON = j.isEmpty ? nil : j
            }
            sqlite3_finalize(read)
        }
        let bodyChanged = existingMd != body || existingJSON != bodyJSON
        let droppingContent = !existingMd.isEmpty && bodyChanged
        if droppingContent {
            let reason = body.isEmpty ? "wipe-guard" : "pre-overwrite"
            var hist: OpaquePointer?
            sqlite3_prepare_v2(db, """
                INSERT INTO month_plan_section_history (section_id, body_md, body_json, saved_at, reason)
                VALUES (?, ?, ?, ?, ?)
            """, -1, &hist, nil)
            sqlite3_bind_int64(hist, 1, id)
            bindText(hist, 2, existingMd)
            bindTextOrNull(hist, 3, existingJSON)
            bindText(hist, 4, now)
            bindText(hist, 5, reason)
            sqlite3_step(hist)
            sqlite3_finalize(hist)
            // Bound history at 50 rows per section — older snapshots
            // age out so a long-lived section doesn't grow unbounded.
            var prune: OpaquePointer?
            sqlite3_prepare_v2(db, """
                DELETE FROM month_plan_section_history
                WHERE section_id = ?
                  AND id NOT IN (
                    SELECT id FROM month_plan_section_history
                    WHERE section_id = ?
                    ORDER BY saved_at DESC, id DESC
                    LIMIT 50
                  )
            """, -1, &prune, nil)
            sqlite3_bind_int64(prune, 1, id)
            sqlite3_bind_int64(prune, 2, id)
            sqlite3_step(prune)
            sqlite3_finalize(prune)
        }
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

    struct MonthPlanSectionHistoryEntry {
        let id: Int64
        let bodyMd: String
        let bodyJSON: String?
        let savedAt: String
        let reason: String
    }

    /// Most recent first. Used by the section "복구..." menu so the user
    /// can roll back an accidental wipe without leaving the app.
    func getMonthPlanSectionHistory(sectionId: Int64) -> [MonthPlanSectionHistoryEntry] {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, """
            SELECT id, body_md, body_json, saved_at, reason
            FROM month_plan_section_history
            WHERE section_id = ?
            ORDER BY saved_at DESC, id DESC
        """, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, sectionId)
        var out: [MonthPlanSectionHistoryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let json = textCol(stmt, 2)
            out.append(MonthPlanSectionHistoryEntry(
                id: sqlite3_column_int64(stmt, 0),
                bodyMd: textCol(stmt, 1),
                bodyJSON: json.isEmpty ? nil : json,
                savedAt: textCol(stmt, 3),
                reason: textCol(stmt, 4)
            ))
        }
        return out
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
}
