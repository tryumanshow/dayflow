#!/Users/swryu/dayflow/.venv/bin/python
# <bitbar.title>dayflow</bitbar.title>
# <bitbar.version>v0.1</bitbar.version>
# <bitbar.author>swryu</bitbar.author>
# <bitbar.desc>Glance at today's inbox-thrown tasks.</bitbar.desc>
# <bitbar.dependencies>python3</bitbar.dependencies>
#
# SwiftBar plugin. Refresh interval is encoded in the filename (5m).
#
# Output protocol (SwiftBar / xbar):
#   line 1            : menubar text
#   ---               : separator
#   subsequent lines  : dropdown items, each may carry "| key=value" hints
"""dayflow SwiftBar plugin — read-only glance at today's tasks."""

from __future__ import annotations

import sys
from pathlib import Path

# Make src/ importable when run as a standalone shebang script.
_REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO / "src"))

from dayflow.data import DOING, TODO, Repo  # noqa: E402

MAX_LIST = 5
DF_BIN = "/Users/swryu/dayflow/.venv/bin/df"


def main() -> None:
    repo = Repo()
    tasks = repo.list_today()
    todo = [t for t in tasks if t.status == TODO]
    doing = [t for t in tasks if t.status == DOING]

    # Header line — what shows in the menubar
    if doing:
        head = f"\u25B6 {doing[0].title[:30]}"
    elif todo:
        head = f"\U0001F4CB {len(todo)} todo"
    else:
        head = "\U0001F331 inbox empty"
    print(head)

    print("---")
    print(f"dayflow \u00B7 {len(todo)} todo \u00B7 {len(doing)} doing | size=11")
    print("---")

    if not todo and not doing:
        print("nothing thrown today | color=gray")
    else:
        for t in doing:
            print(f"\u25B6 #{t.id} {t.title} | color=orange")
        for t in todo[:MAX_LIST]:
            print(f"\u2610 #{t.id} {t.title}")
        remaining = len(todo) - MAX_LIST
        if remaining > 0:
            print(f"\u2026 and {remaining} more | color=gray")

    print("---")
    print(f"Open TUI | shell={DF_BIN} | terminal=true")
    print("Refresh | refresh=true")


if __name__ == "__main__":
    main()
