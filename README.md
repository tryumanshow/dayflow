# dayflow

Personal calendar / inbox-throw TUI. Built so I actually open it.

## Why
Notion / Obsidian 은 잘 안 들어가게 됨. 터미널은 항상 켜져 있으니까, 거기서 0-마찰로 task 던지고 보는 도구.

## Quickstart

```bash
uv sync
uv run inb "내일 회의자료 만들기"
uv run df                          # Textual today view
uv run dayflow today               # plain-text quick view
uv run dayflow done 1              # 상태 변경
```

## Components
- **CLI** (`inb`, `dayflow`) — 인박스 throw + 빠른 조회
- **TUI** (`df`) — Textual today view, 메모, 상태 변경
- **Menubar** — SwiftBar 플러그인 (P1)
- **Hotkey** — Hammerspoon `Cmd+Shift+I` (P1)
- **LLM 회고** — `dayflow review` 로 일일 회고 자동 생성 (P2)

## Data
- `~/dayflow/dayflow.db` — SQLite (tasks, state_history, time_log, notes)
- `~/dayflow/vault/YYYY-MM-DD.md` — 일자 단위 마크다운 (메모, 회고)

## Plans
- See `docs/plans/worktree-plan-20260411-1700.md`
