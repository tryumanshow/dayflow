"""Data Access Object for dayflow.

All callers go through `Repo`. SQLite connections are short-lived per call to
keep things simple — no connection pool, no async.
"""

from __future__ import annotations

import sqlite3
from contextlib import contextmanager
from datetime import date, datetime
from pathlib import Path
from typing import Iterator

from .models import DOING, DONE, STATUSES, TODO, Note, StateChange, Task, TimeEntry
from .schema import init_schema

DEFAULT_DB_PATH = Path.home() / "dayflow" / "dayflow.db"


def _now_iso() -> str:
    return datetime.now().isoformat(timespec="seconds")


def _today_iso() -> str:
    return date.today().isoformat()


class Repo:
    def __init__(self, db_path: Path | None = None) -> None:
        self.db_path = Path(db_path) if db_path else DEFAULT_DB_PATH
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as conn:
            init_schema(conn)

    @contextmanager
    def _connect(self) -> Iterator[sqlite3.Connection]:
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys = ON")
        try:
            yield conn
        finally:
            conn.close()

    # ---- tasks ---------------------------------------------------------------

    def add_task(self, title: str, due_date: str | None = None) -> Task:
        title = title.strip()
        if not title:
            raise ValueError("title must not be empty")
        now = _now_iso()
        with self._connect() as conn:
            cur = conn.execute(
                "INSERT INTO tasks (title, status, inbox_at, due_date, updated_at) "
                "VALUES (?, ?, ?, ?, ?)",
                (title, TODO, now, due_date, now),
            )
            task_id = cur.lastrowid
            conn.execute(
                "INSERT INTO state_history (task_id, from_status, to_status, changed_at) "
                "VALUES (?, ?, ?, ?)",
                (task_id, None, TODO, now),
            )
            conn.commit()
            return self._get_task(conn, task_id)

    def get_task(self, task_id: int) -> Task | None:
        with self._connect() as conn:
            return self._get_task(conn, task_id)

    @staticmethod
    def _get_task(conn: sqlite3.Connection, task_id: int) -> Task | None:
        row = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
        if row is None:
            return None
        return Task(
            id=row["id"],
            title=row["title"],
            status=row["status"],
            inbox_at=row["inbox_at"],
            due_date=row["due_date"],
            updated_at=row["updated_at"],
        )

    def list_today(self) -> list[Task]:
        """Tasks inbox-d today OR still-open (TODO/DOING) from earlier days.

        Rationale: an open task from yesterday is still 'today's work'.
        """
        today = _today_iso()
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT * FROM tasks "
                "WHERE substr(inbox_at, 1, 10) = ? "
                "   OR status IN ('TODO', 'DOING') "
                "ORDER BY "
                "  CASE status WHEN 'DOING' THEN 0 WHEN 'TODO' THEN 1 "
                "              WHEN 'DONE' THEN 2 ELSE 3 END, "
                "  id DESC",
                (today,),
            ).fetchall()
        return [
            Task(
                id=r["id"],
                title=r["title"],
                status=r["status"],
                inbox_at=r["inbox_at"],
                due_date=r["due_date"],
                updated_at=r["updated_at"],
            )
            for r in rows
        ]

    def change_status(self, task_id: int, new_status: str) -> Task:
        if new_status not in STATUSES:
            raise ValueError(f"invalid status: {new_status}")
        now = _now_iso()
        with self._connect() as conn:
            current = self._get_task(conn, task_id)
            if current is None:
                raise LookupError(f"task {task_id} not found")
            if current.status == new_status:
                return current
            conn.execute(
                "UPDATE tasks SET status = ?, updated_at = ? WHERE id = ?",
                (new_status, now, task_id),
            )
            conn.execute(
                "INSERT INTO state_history (task_id, from_status, to_status, changed_at) "
                "VALUES (?, ?, ?, ?)",
                (task_id, current.status, new_status, now),
            )
            # time tracking: opening DOING starts a timer; leaving DOING closes it
            if new_status == DOING and current.status != DOING:
                conn.execute(
                    "INSERT INTO time_log (task_id, started_at) VALUES (?, ?)",
                    (task_id, now),
                )
            if current.status == DOING and new_status != DOING:
                open_row = conn.execute(
                    "SELECT id, started_at FROM time_log "
                    "WHERE task_id = ? AND ended_at IS NULL "
                    "ORDER BY id DESC LIMIT 1",
                    (task_id,),
                ).fetchone()
                if open_row is not None:
                    started_dt = datetime.fromisoformat(open_row["started_at"])
                    ended_dt = datetime.fromisoformat(now)
                    duration = int((ended_dt - started_dt).total_seconds())
                    conn.execute(
                        "UPDATE time_log SET ended_at = ?, duration_sec = ? WHERE id = ?",
                        (now, duration, open_row["id"]),
                    )
            conn.commit()
            return self._get_task(conn, task_id)  # type: ignore[return-value]

    # ---- notes ---------------------------------------------------------------

    def add_note(self, task_id: int, body_md: str) -> Note:
        body_md = body_md.strip()
        if not body_md:
            raise ValueError("note body must not be empty")
        now = _now_iso()
        with self._connect() as conn:
            cur = conn.execute(
                "INSERT INTO notes (task_id, body_md, written_at) VALUES (?, ?, ?)",
                (task_id, body_md, now),
            )
            note_id = cur.lastrowid
            conn.commit()
        return Note(id=note_id, task_id=task_id, body_md=body_md, written_at=now)

    def list_notes(self, task_id: int) -> list[Note]:
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT * FROM notes WHERE task_id = ? ORDER BY id ASC", (task_id,)
            ).fetchall()
        return [
            Note(id=r["id"], task_id=r["task_id"], body_md=r["body_md"], written_at=r["written_at"])
            for r in rows
        ]

    # ---- history -------------------------------------------------------------

    def list_state_history(self, task_id: int) -> list[StateChange]:
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT * FROM state_history WHERE task_id = ? ORDER BY id ASC", (task_id,)
            ).fetchall()
        return [
            StateChange(
                id=r["id"],
                task_id=r["task_id"],
                from_status=r["from_status"],
                to_status=r["to_status"],
                changed_at=r["changed_at"],
            )
            for r in rows
        ]

    def list_time_entries(self, task_id: int) -> list[TimeEntry]:
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT * FROM time_log WHERE task_id = ? ORDER BY id ASC", (task_id,)
            ).fetchall()
        return [
            TimeEntry(
                id=r["id"],
                task_id=r["task_id"],
                started_at=r["started_at"],
                ended_at=r["ended_at"],
                duration_sec=r["duration_sec"],
            )
            for r in rows
        ]
