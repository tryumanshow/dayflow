import Testing
import Foundation
import SQLite3
@testable import DayflowApp

private func tempDBPath() -> String {
    let dir = NSTemporaryDirectory() + "dayflow-test-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir + "/dayflow.db"
}

private func userVersion(atPath path: String) -> Int32 {
    var raw: OpaquePointer?
    guard sqlite3_open(path, &raw) == SQLITE_OK else { return -1 }
    defer { sqlite3_close(raw) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(raw, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK else { return -1 }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
    return sqlite3_column_int(stmt, 0)
}

/// Seed a *pristine* (user_version 0) DB carrying only the oldest day_notes
/// shape (no body_json), then open it through DayflowDB and assert the full
/// v1→v8 ladder runs without destroying the row. Primary DB-safety proof.
///
/// NOTE: the seed is user_version 0, not 1 — seeding 1 would skip the v1
/// `ADD COLUMN body_json` step, leaving day_notes without the column every
/// read now selects.
@Test func oldDBMigratesToV8WithoutDataLoss() {
    let path = tempDBPath()
    let cal = Calendar.current
    let d = cal.date(from: DateComponents(year: 2026, month: 1, day: 15))!
    // Timezone-agnostic: derive the exact key DayflowDB will look up.
    let key = DayflowDB.ymd(d)

    var raw: OpaquePointer?
    #expect(sqlite3_open(path, &raw) == SQLITE_OK)
    let seed = """
        CREATE TABLE day_notes (
            note_date  TEXT PRIMARY KEY,
            body_md    TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        INSERT INTO day_notes VALUES ('\(key)', '- [x] survived', '2026-01-15T00:00:00');
        PRAGMA user_version = 0;
    """
    #expect(sqlite3_exec(raw, seed, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(raw)

    // Open through the app's DB layer — runs ensureSchema + migrate.
    let db = DayflowDB(path: path)

    #expect(db.getDayNote(date: d) == "- [x] survived")
    // A read that selects body_json succeeds → v1 column exists.
    #expect(db.getDayNoteFull(date: d).body == "- [x] survived")
    // Ladder reached the current head.
    #expect(userVersion(atPath: path) == 8)
}

@Test func freshDBRoundTrips() {
    let db = DayflowDB(path: tempDBPath())
    let d = Date()
    db.saveDayNote(date: d, body: "hello", bodyJSON: "{\"x\":1}")
    let got = db.getDayNoteFull(date: d)
    #expect(got.body == "hello")
    #expect(got.bodyJSON == "{\"x\":1}")
}

/// bodyJSON: nil explicitly nulls the JSON slot (markdown-only writers
/// depend on this to drop rich styles on the affected row).
@Test func saveDayNoteNilJSONClearsSlot() {
    let db = DayflowDB(path: tempDBPath())
    let d = Date()
    db.saveDayNote(date: d, body: "styled", bodyJSON: "{\"b\":true}")
    db.saveDayNote(date: d, body: "plain", bodyJSON: nil)
    let got = db.getDayNoteFull(date: d)
    #expect(got.body == "plain")
    #expect(got.bodyJSON == nil)
}

@Test func appointmentInsertAndFetch() {
    let db = DayflowDB(path: tempDBPath())
    let start = Date()
    _ = db.insertAppointment(startAt: start, endAt: nil, title: "standup",
                             note: nil, category: .event)
    let got = db.getAppointments(start: start.addingTimeInterval(-3600),
                                 end: start.addingTimeInterval(3600))
    #expect(got.count == 1)
    #expect(got.first?.title == "standup")
    #expect(got.first?.category == .event)
}

@Test func deleteAppointmentRemovesIt() {
    let db = DayflowDB(path: tempDBPath())
    let start = Date()
    let id = db.insertAppointment(startAt: start, endAt: nil, title: "temp",
                                  note: nil, category: .event)
    db.deleteAppointment(id: id)
    let got = db.getAppointments(start: start.addingTimeInterval(-3600),
                                 end: start.addingTimeInterval(3600))
    #expect(got.isEmpty)
}
