"""Textual smoke test using Pilot."""

from __future__ import annotations

from pathlib import Path

import pytest

from dayflow.data import DOING, Repo
from dayflow.tui.app import DayflowApp


@pytest.mark.asyncio
async def test_app_throws_a_task(tmp_path: Path) -> None:
    repo = Repo(db_path=tmp_path / "smoke.db")
    app = DayflowApp(repo=repo)
    async with app.run_test() as pilot:
        await pilot.press("a")
        await pilot.pause()
        # type "hello" into the modal input
        for ch in "hello":
            await pilot.press(ch)
        await pilot.press("enter")
        await pilot.pause()

    tasks = repo.list_today()
    titles = [t.title for t in tasks]
    assert "hello" in titles


@pytest.mark.asyncio
async def test_app_toggle_status(tmp_path: Path) -> None:
    repo = Repo(db_path=tmp_path / "smoke.db")
    repo.add_task("seed")
    app = DayflowApp(repo=repo)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("space")
        await pilot.pause()

    history = repo.list_state_history(1)
    assert any(h.to_status == DOING for h in history)
