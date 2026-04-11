"""LLM-powered daily review generator."""

from __future__ import annotations

import os
from datetime import date

from dayflow.data import Repo, get_or_create_vault, replace_section

from .prompt import SYSTEM_PROMPT, build_user_prompt, collect_day_data

DEFAULT_MODEL = "claude-sonnet-4-5"
MODEL_ENV = "DAYFLOW_REVIEW_MODEL"


class ReviewError(RuntimeError):
    pass


def generate_daily_review(
    target: date | None = None,
    repo: Repo | None = None,
    client=None,
) -> str:
    """Run the LLM call and write the result into the vault `## 회고` section.

    Returns the markdown body that was written.
    """
    repo = repo or Repo()
    target = target or date.today()

    day_data = collect_day_data(repo, target)
    if not day_data["tasks"]:
        body = "오늘은 던진 task 가 하나도 없어. 내일은 한 줄이라도 throw 해보자."
    else:
        body = _call_llm(day_data, client=client)

    vault_path = get_or_create_vault(target)
    replace_section(vault_path, "## 회고", body)
    return body


def _call_llm(day_data: dict, client=None) -> str:
    if client is None:
        api_key = os.environ.get("ANTHROPIC_API_KEY")
        if not api_key:
            raise ReviewError(
                "ANTHROPIC_API_KEY 가 안 잡혀있어. "
                "`export ANTHROPIC_API_KEY=...` 해두고 다시 시도해."
            )
        from anthropic import Anthropic

        client = Anthropic(api_key=api_key)

    model = os.environ.get(MODEL_ENV, DEFAULT_MODEL)
    msg = client.messages.create(
        model=model,
        max_tokens=1024,
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": build_user_prompt(day_data)}],
    )

    parts: list[str] = []
    for block in msg.content:
        text = getattr(block, "text", None)
        if text:
            parts.append(text)
    return "\n".join(parts).strip() or "(빈 응답)"
