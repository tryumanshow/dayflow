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
    updated_at  TEXT    NOT NULL,
    parent_id   INTEGER REFERENCES tasks(id) ON DELETE CASCADE
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

CREATE TABLE IF NOT EXISTS reviews (
    review_date  TEXT PRIMARY KEY,        -- YYYY-MM-DD, one review per day
    body_md      TEXT NOT NULL,
    generated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS month_plans (
    year_month TEXT PRIMARY KEY,           -- "YYYY-MM"
    body_md    TEXT NOT NULL,
    updated_at TEXT NOT NULL
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

    # Migrations for existing databases (idempotent — ALTER fails silently if column exists).
    _add_column_if_missing(conn, "tasks", "parent_id", "INTEGER REFERENCES tasks(id) ON DELETE CASCADE")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_tasks_parent ON tasks(parent_id)")

    conn.commit()


def _add_column_if_missing(
    conn: sqlite3.Connection, table: str, column: str, decl: str
) -> None:
    cur = conn.execute(f"PRAGMA table_info({table})")
    cols = [row[1] for row in cur.fetchall()]
    if column not in cols:
        conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {decl}")
