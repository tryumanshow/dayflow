"""CLI tests using Click's CliRunner with an isolated DB via env override."""

from __future__ import annotations

from pathlib import Path

import pytest
from click.testing import CliRunner

from dayflow.cli.main import cli, inbox_add_entry
from dayflow.data import repo as repo_module


@pytest.fixture(autouse=True)
def isolated_db(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    db = tmp_path / "test.db"
    monkeypatch.setattr(repo_module, "DEFAULT_DB_PATH", db)
    return db


def test_add_and_today() -> None:
    runner = CliRunner()
    r = runner.invoke(cli, ["add", "write", "blog", "post"])
    assert r.exit_code == 0
    assert "[#1]" in r.output
    assert "write blog post" in r.output

    r = runner.invoke(cli, ["today"])
    assert r.exit_code == 0
    assert "write blog post" in r.output
    assert "[ ]" in r.output


def test_done_changes_status() -> None:
    runner = CliRunner()
    runner.invoke(cli, ["add", "task one"])
    r = runner.invoke(cli, ["done", "1"])
    assert r.exit_code == 0
    assert "[x]" in r.output


def test_done_unknown_task() -> None:
    runner = CliRunner()
    r = runner.invoke(cli, ["done", "999"])
    assert r.exit_code == 1
    assert "not found" in r.output


def test_inb_shortcut() -> None:
    runner = CliRunner()
    r = runner.invoke(inbox_add_entry, ["plan", "next", "week"])
    assert r.exit_code == 0
    assert "plan next week" in r.output


def test_today_empty_inbox() -> None:
    runner = CliRunner()
    r = runner.invoke(cli, ["today"])
    assert r.exit_code == 0
    assert "inbox empty" in r.output
