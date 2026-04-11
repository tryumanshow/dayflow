"""Daily review tests with mocked Anthropic client."""

from __future__ import annotations

from datetime import date
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest

from dayflow.data import DOING, Repo
from dayflow.data import vault as vault_module
from dayflow.review.daily import ReviewError, generate_daily_review


@pytest.fixture
def repo(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Repo:
    monkeypatch.setattr(vault_module, "DEFAULT_VAULT_DIR", tmp_path / "vault")
    return Repo(db_path=tmp_path / "test.db")


def _make_client(text: str) -> MagicMock:
    client = MagicMock()
    client.messages.create.return_value = SimpleNamespace(
        content=[SimpleNamespace(text=text)]
    )
    return client


def test_review_writes_to_vault(repo: Repo) -> None:
    t = repo.add_task("write tests")
    repo.change_status(t.id, DOING)
    client = _make_client("**잘 한 것**\n- 테스트 작성\n\n**막힌 것**\n- 없음\n\n**내일 우선순위 3가지**\n1. a\n2. b\n3. c")

    body = generate_daily_review(target=date.today(), repo=repo, client=client)

    assert "잘 한 것" in body
    vault_path = vault_module.DEFAULT_VAULT_DIR / f"{date.today().isoformat()}.md"
    text = vault_path.read_text(encoding="utf-8")
    assert "잘 한 것" in text
    assert "## 회고" in text
    client.messages.create.assert_called_once()


def test_review_idempotent_overwrite(repo: Repo) -> None:
    repo.add_task("foo")
    client = _make_client("first review")
    generate_daily_review(target=date.today(), repo=repo, client=client)

    client2 = _make_client("second review")
    generate_daily_review(target=date.today(), repo=repo, client=client2)

    vault_path = vault_module.DEFAULT_VAULT_DIR / f"{date.today().isoformat()}.md"
    text = vault_path.read_text(encoding="utf-8")
    assert "second review" in text
    assert "first review" not in text


def test_review_empty_day_no_llm_call(repo: Repo) -> None:
    client = _make_client("should not be used")
    body = generate_daily_review(target=date.today(), repo=repo, client=client)
    assert "던진 task" in body
    client.messages.create.assert_not_called()


def test_review_missing_api_key(repo: Repo, monkeypatch: pytest.MonkeyPatch) -> None:
    repo.add_task("foo")
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    with pytest.raises(ReviewError):
        generate_daily_review(target=date.today(), repo=repo)
