"""Prompt construction for the daily review LLM call."""

from __future__ import annotations

import json
from datetime import date, datetime

from dayflow.data import Repo

SYSTEM_PROMPT = (
    "너는 사용자의 일일 회고를 돕는 어시스턴트야. "
    "한국어 반말 톤으로, 간결하게 답해. "
    "출력은 마크다운 한 덩어리로, 다음 3개 섹션을 정확히 이 순서로 써:\n"
    "1. **잘 한 것** — 오늘 끝낸 task / 진척 (불릿 2~4개)\n"
    "2. **막힌 것** — 시작했지만 끝내지 못한 부분, 메모에 드러난 어려움 (불릿 1~3개)\n"
    "3. **내일 우선순위 3가지** — 남은 TODO 와 맥락을 고려해서 1-2-3 번호로\n"
    "예의차림 / 인사 / 사족 금지. 본문만."
)


def collect_day_data(repo: Repo, target: date) -> dict:
    """Pull all task/state/note data relevant to a given day."""
    target_iso = target.isoformat()
    tasks = repo.list_today() if target == date.today() else _list_tasks_for_date(repo, target)

    items: list[dict] = []
    for t in tasks:
        history = repo.list_state_history(t.id)
        time_entries = repo.list_time_entries(t.id)
        notes = repo.list_notes(t.id)

        focused_sec = sum((e.duration_sec or 0) for e in time_entries)
        items.append(
            {
                "id": t.id,
                "title": t.title,
                "status": t.status,
                "inbox_at": t.inbox_at,
                "focused_minutes": focused_sec // 60,
                "transitions": [
                    {"from": h.from_status, "to": h.to_status, "at": h.changed_at}
                    for h in history
                ],
                "notes": [n.body_md for n in notes],
            }
        )
    return {"date": target_iso, "tasks": items}


def _list_tasks_for_date(repo: Repo, target: date) -> list:
    """Return tasks whose history touches the given date.

    For non-today reviews we still want all tasks involved that day,
    even if their inbox_at is older.
    """
    # Lightweight: for v1 we just list_today and filter, since the typical
    # call is `dayflow review` at end of day.
    return [t for t in repo.list_today() if t.inbox_at[:10] <= target.isoformat()]


def build_user_prompt(day_data: dict) -> str:
    return (
        f"오늘은 {day_data['date']} 야. 아래 데이터를 바탕으로 회고를 써줘:\n\n"
        "```json\n"
        f"{json.dumps(day_data, ensure_ascii=False, indent=2)}\n"
        "```"
    )
