"""SQLite schema DDL for dayflow.

Single source of truth for table definitions. Idempotent — `init_schema()` is
safe to call on every connection.
"""

from __future__ import annotations

import sqlite3

DDL = """
CREATE TABLE IF NOT EXISTS tasks (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    title       TEXT    NOT NULL,
    status      TEXT    NOT NULL DEFAULT 'TODO',
    inbox_at    TEXT    NOT NULL,
    due_date    TEXT,
    updated_at  TEXT    NOT NULL
);

CREATE TABLE IF NOT EXISTS state_history (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id     INTEGER NOT NULL,
    from_status TEXT,
    to_status   TEXT    NOT NULL,
    changed_at  TEXT    NOT NULL,
    FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS time_log (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id      INTEGER NOT NULL,
    started_at   TEXT    NOT NULL,
    ended_at     TEXT,
    duration_sec INTEGER,
    FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS notes (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id    INTEGER NOT NULL,
    body_md    TEXT    NOT NULL,
    written_at TEXT    NOT NULL,
    FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_tasks_inbox_at ON tasks(inbox_at);
CREATE INDEX IF NOT EXISTS idx_state_history_task ON state_history(task_id);
CREATE INDEX IF NOT EXISTS idx_time_log_task ON time_log(task_id);
CREATE INDEX IF NOT EXISTS idx_notes_task ON notes(task_id);
"""


def init_schema(conn: sqlite3.Connection) -> None:
    """Apply DDL. Safe to call repeatedly.

    WAL journal mode lets the SwiftUI menubar app read concurrently while
    the Python TUI/CLI writes.
    """
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.executescript(DDL)
    conn.commit()
