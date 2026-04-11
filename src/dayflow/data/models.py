"""Plain dataclass models for dayflow rows."""

from __future__ import annotations

from dataclasses import dataclass

# Status values are intentionally plain strings (not Enum) for SQLite friendliness.
TODO = "TODO"
DOING = "DOING"
DONE = "DONE"
WONT = "WONT"
STATUSES = (TODO, DOING, DONE, WONT)


@dataclass
class Task:
    id: int
    title: str
    status: str
    inbox_at: str  # ISO 8601 string
    due_date: str | None
    updated_at: str


@dataclass
class StateChange:
    id: int
    task_id: int
    from_status: str | None
    to_status: str
    changed_at: str


@dataclass
class TimeEntry:
    id: int
    task_id: int
    started_at: str
    ended_at: str | None
    duration_sec: int | None


@dataclass
class Note:
    id: int
    task_id: int
    body_md: str
    written_at: str
