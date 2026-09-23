import Testing
import Foundation
import SQLite3
@testable import DayflowApp

private func tempDB() -> DayflowDB {
    let dir = NSTemporaryDirectory() + "dayflow-backup-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return DayflowDB(path: dir + "/dayflow.db")
}

private func day(_ ymd: String) -> Date {
    DF.ymd.date(from: ymd)!
}

/// Read a note straight out of a snapshot file, bypassing DayflowDB.
private func noteBody(in file: URL, date: String) -> String? {
    var conn: OpaquePointer?
    guard sqlite3_open_v2(file.path, &conn, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_close(conn) }
    var stmt: OpaquePointer?
    sqlite3_prepare_v2(conn, "SELECT body_md FROM day_notes WHERE note_date = ?", -1, &stmt, nil)
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, date, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
    return String(cString: text)
}

/// The snapshot must include writes still sitting in the WAL — the reason it
/// goes through the backup API instead of copying `dayflow.db`.
@Test func snapshotContainsUncheckpointedWrites() throws {
    let db = tempDB()
    db.saveDayNote(date: day("2026-09-01"), body: "- [ ] in the WAL")

    let url = try #require(try DatabaseBackup.snapshotIfNeeded(db, now: day("2026-09-01")))

    #expect(url.lastPathComponent == "dayflow-2026-09-01.db")
    #expect(noteBody(in: url, date: "2026-09-01") == "- [ ] in the WAL")
}

@Test func oneSnapshotPerDay() throws {
    let db = tempDB()
    db.saveDayNote(date: day("2026-09-01"), body: "first")
    let first = try DatabaseBackup.snapshotIfNeeded(db, now: day("2026-09-01"))
    db.saveDayNote(date: day("2026-09-01"), body: "later edit")
    let second = try DatabaseBackup.snapshotIfNeeded(db, now: day("2026-09-01"))

    #expect(first != nil)
    #expect(second == nil)
    // The day's snapshot is not overwritten by later runs that day.
    #expect(noteBody(in: first!, date: "2026-09-01") == "first")
}

@Test func pruneKeepsTheNewestAndLeavesOtherFilesAlone() throws {
    let db = tempDB()
    for d in 1...5 {
        try DatabaseBackup.snapshotIfNeeded(db, now: day(String(format: "2026-09-%02d", d)))
    }
    let dir = DatabaseBackup.directory(for: db)
    let stray = dir.appendingPathComponent("my-manual-copy.db")
    FileManager.default.createFile(atPath: stray.path, contents: Data("x".utf8))

    DatabaseBackup.prune(dir, keep: 2)

    #expect(DatabaseBackup.snapshots(in: dir).map(\.lastPathComponent) == ["dayflow-2026-09-05.db", "dayflow-2026-09-04.db"])
    #expect(FileManager.default.fileExists(atPath: stray.path))
}

@Test func snapshotsAreOwnerOnly() throws {
    let db = tempDB()
    let url = try #require(try DatabaseBackup.snapshotIfNeeded(db, now: day("2026-09-01")))
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attrs[.posixPermissions] as? Int) == 0o600)
    // Only the snapshot itself: no temp file or -wal/-shm companion left behind.
    let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
    #expect(files == [url.lastPathComponent])
}
