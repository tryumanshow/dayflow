"""Tests for the dayflow data layer."""

from __future__ import annotations

import time
from datetime import date
from pathlib import Path

import pytest

from dayflow.data import (
    DOING,
    DONE,
    TODO,
    Repo,
    get_or_create_vault,
    replace_section,
)


@pytest.fixture
def repo(tmp_path: Path) -> Repo:
    return Repo(db_path=tmp_path / "test.db")


def test_add_task_creates_row_and_history(repo: Repo) -> None:
    task = repo.add_task("write tests")
    assert task.id > 0
    assert task.title == "write tests"
    assert task.status == TODO

    history = repo.list_state_history(task.id)
    assert len(history) == 1
    assert history[0].from_status is None
    assert history[0].to_status == TODO


def test_add_task_rejects_empty(repo: Repo) -> None:
    with pytest.raises(ValueError):
        repo.add_task("   ")


def test_change_status_records_history(repo: Repo) -> None:
    task = repo.add_task("foo")
    repo.change_status(task.id, DOING)
    repo.change_status(task.id, DONE)

    history = repo.list_state_history(task.id)
    assert [h.to_status for h in history] == [TODO, DOING, DONE]


def test_change_status_idempotent(repo: Repo) -> None:
    task = repo.add_task("foo")
    repo.change_status(task.id, DOING)
    repo.change_status(task.id, DOING)  # noop
    history = repo.list_state_history(task.id)
    assert len(history) == 2  # initial TODO + DOING


def test_doing_writes_time_log(repo: Repo) -> None:
    task = repo.add_task("focus")
    repo.change_status(task.id, DOING)
    time.sleep(1.1)
    repo.change_status(task.id, DONE)

    entries = repo.list_time_entries(task.id)
    assert len(entries) == 1
    assert entries[0].started_at is not None
    assert entries[0].ended_at is not None
    assert entries[0].duration_sec is not None
    assert entries[0].duration_sec >= 1


def test_invalid_status_rejected(repo: Repo) -> None:
    task = repo.add_task("foo")
    with pytest.raises(ValueError):
        repo.change_status(task.id, "BOGUS")


def test_list_today_includes_open_old_tasks(repo: Repo) -> None:
    a = repo.add_task("alpha")
    b = repo.add_task("beta")
    repo.change_status(b.id, DONE)
    today = repo.list_today()
    titles = [t.title for t in today]
    assert "alpha" in titles
    assert "beta" in titles  # finished today is still listed


def test_add_note(repo: Repo) -> None:
    task = repo.add_task("foo")
    repo.add_note(task.id, "막힌 부분: x")
    repo.add_note(task.id, "해결: y")
    notes = repo.list_notes(task.id)
    assert [n.body_md for n in notes] == ["막힌 부분: x", "해결: y"]


def test_get_or_create_vault_idempotent(tmp_path: Path) -> None:
    path = get_or_create_vault(date(2026, 4, 11), vault_dir=tmp_path)
    assert path.exists()
    body1 = path.read_text(encoding="utf-8")
    path2 = get_or_create_vault(date(2026, 4, 11), vault_dir=tmp_path)
    assert path == path2
    assert path2.read_text(encoding="utf-8") == body1
    assert "## TODO" in body1
    assert "## 회고" in body1


def test_replace_section_overwrites(tmp_path: Path) -> None:
    path = get_or_create_vault(date(2026, 4, 11), vault_dir=tmp_path)
    replace_section(path, "## 회고", "오늘은 잘 했음")
    body = path.read_text(encoding="utf-8")
    assert "오늘은 잘 했음" in body
    # second call overwrites, no duplication
    replace_section(path, "## 회고", "다시 작성")
    body = path.read_text(encoding="utf-8")
    assert "다시 작성" in body
    assert "오늘은 잘 했음" not in body
