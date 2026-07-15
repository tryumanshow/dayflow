import Foundation
import SQLite3

extension DayflowDB {
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

    /// Returns (open, done, onHold) task counts for a markdown body.
    /// On-hold is its own bucket so completion ratios can exclude parked
    /// work rather than counting it as outstanding.
    static func parseCheckboxes(_ body: String) -> (open: Int, done: Int, onHold: Int) {
        var open = 0
        var done = 0
        var onHold = 0
        for line in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            guard case let .task(status, _) = MarkdownLine.parse(String(line)) ?? .plain(text: "") else { continue }
            switch status {
            case .open:   open += 1
            case .done:   done += 1
            case .onHold: onHold += 1
            }
        }
        return (open, done, onHold)
    }
}
