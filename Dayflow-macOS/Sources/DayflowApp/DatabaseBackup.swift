import Foundation
import SQLite3

/// Daily snapshots of `dayflow.db` in a `backups/` folder next to it.
///
/// Everything a user writes lives in that one file, so a bad migration, a
/// sync bug or an accidental select-all-delete that got saved is otherwise
/// unrecoverable. One snapshot per calendar day is taken the first time the
/// app is running that day; the newest `keepCount` are kept.
///
/// Snapshots go through SQLite's online backup API on the live connection, so
/// they are consistent with the WAL (a file copy of `dayflow.db` alone would
/// miss everything still in `dayflow.db-wal`). Each is written under a temp
/// name and renamed into place, so a crash mid-copy never leaves a truncated
/// file that looks like a good backup.
enum DatabaseBackup {
    static let keepCount = 14
    private static let prefix = "dayflow-"
    private static let suffix = ".db"

    enum Failure: Error, LocalizedError {
        case noConnection
        case sqlite(String)

        var errorDescription: String? {
            switch self {
            case .noConnection: "The database is not open."
            case let .sqlite(message): message
            }
        }
    }

    /// `<folder of the database>/backups`.
    static func directory(for db: DayflowDB) -> URL {
        URL(fileURLWithPath: db.path).deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
    }

    /// Snapshot files, newest first.
    static func snapshots(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }
            .sorted(by: >)  // `dayflow-YYYY-MM-DD.db` sorts chronologically
            .map { directory.appendingPathComponent($0) }
    }

    /// Take today's snapshot unless one exists, then prune old ones.
    /// Returns the new snapshot, or nil when today's already existed.
    @discardableResult
    static func snapshotIfNeeded(_ db: DayflowDB, now: Date = Date()) throws -> URL? {
        let dir = directory(for: db)
        let target = dir.appendingPathComponent(prefix + DayflowDB.ymd(now) + suffix)
        guard !FileManager.default.fileExists(atPath: target.path) else { return nil }
        try snapshot(db, to: target)
        prune(dir)
        return target
    }

    /// Write a consistent copy of the live database to `url`, replacing it.
    static func snapshot(_ db: DayflowDB, to url: URL) throws {
        guard let source = db.db else { throw Failure.noConnection }
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        // Same privacy as the database itself: notes are personal.
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).partial")
        let sidecars = ["-wal", "-shm", "-journal"].map { URL(fileURLWithPath: temp.path + $0) }
        defer {
            for leftover in [temp] + sidecars { try? fm.removeItem(at: leftover) }
        }

        try copyDatabase(from: source, to: temp)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.moveItem(at: temp, to: url)
    }

    /// Copy `source` into a new database file at `path` and close it, so the
    /// file is complete and no connection holds it when it is moved.
    private static func copyDatabase(from source: OpaquePointer, to path: URL) throws {
        var dest: OpaquePointer?
        guard sqlite3_open(path.path, &dest) == SQLITE_OK, let dest else {
            sqlite3_close(dest)
            throw Failure.sqlite("could not create \(path.lastPathComponent)")
        }
        defer { sqlite3_close(dest) }
        guard let backup = sqlite3_backup_init(dest, "main", source, "main") else {
            throw Failure.sqlite(String(cString: sqlite3_errmsg(dest)))
        }
        let step = sqlite3_backup_step(backup, -1)
        sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE else {
            throw Failure.sqlite(String(cString: sqlite3_errstr(step)))
        }
        // The copy inherits WAL mode from the live database; a snapshot should
        // be one self-contained file that opens anywhere without growing
        // -wal/-shm companions.
        guard sqlite3_exec(dest, "PRAGMA journal_mode=DELETE;", nil, nil, nil) == SQLITE_OK else {
            throw Failure.sqlite(String(cString: sqlite3_errmsg(dest)))
        }
    }

    /// Delete all but the newest `keep` snapshots. Only files named like a
    /// snapshot are touched; anything else a user drops in the folder stays.
    static func prune(_ directory: URL, keep: Int = keepCount) {
        for old in snapshots(in: directory).dropFirst(keep) {
            try? FileManager.default.removeItem(at: old)
        }
    }
}

/// Runs `DatabaseBackup` for the app: once at launch and then hourly, so an
/// app left open for days still gets one snapshot per day.
@MainActor
final class DatabaseBackupScheduler {
    static let shared = DatabaseBackupScheduler()
    private var timer: Timer?

    func start(db: DayflowDB = .shared) {
        guard timer == nil else { return }
        run(db)
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.run(db) }
        }
    }

    private func run(_ db: DayflowDB) {
        DispatchQueue.global(qos: .utility).async {
            do {
                if let url = try DatabaseBackup.snapshotIfNeeded(db) {
                    NSLog("dayflow: database snapshot \(url.lastPathComponent)")
                }
            } catch {
                NSLog("dayflow: database snapshot failed: \(error.localizedDescription)")
            }
        }
    }
}
