"""Markdown vault — daily files at ~/dayflow/vault/YYYY-MM-DD.md.

Vault holds free-form memos and the daily review. It mirrors notes from SQLite,
but SQLite remains source of truth.
"""

from __future__ import annotations

from datetime import date
from pathlib import Path

DEFAULT_VAULT_DIR = Path.home() / "dayflow" / "vault"

SECTIONS = ("## TODO", "## DOING", "## DONE", "## 메모", "## 회고")


def _empty_vault_body(d: date) -> str:
    header = f"# {d.isoformat()}\n\n"
    return header + "\n\n".join(f"{s}\n" for s in SECTIONS) + "\n"


def get_or_create_vault(d: date | None = None, vault_dir: Path | None = None) -> Path:
    """Return path to today's vault file, creating it (idempotent) if missing."""
    d = d or date.today()
    vault_dir = vault_dir or DEFAULT_VAULT_DIR
    vault_dir.mkdir(parents=True, exist_ok=True)
    path = vault_dir / f"{d.isoformat()}.md"
    if not path.exists():
        path.write_text(_empty_vault_body(d), encoding="utf-8")
    return path


def replace_section(path: Path, section_header: str, new_body: str) -> None:
    """Replace the body of a `## Section` (idempotent overwrite).

    Used by the LLM review generator (task-06) to overwrite `## 회고`.
    """
    if section_header not in SECTIONS:
        raise ValueError(f"unknown section: {section_header}")
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    out: list[str] = []
    skipping = False
    replaced = False
    for line in lines:
        if line.strip() == section_header:
            out.append(line)
            out.append(new_body.rstrip())
            skipping = True
            replaced = True
            continue
        if skipping:
            if line.startswith("## "):
                skipping = False
                out.append("")
                out.append(line)
            continue
        out.append(line)
    if not replaced:
        out.append("")
        out.append(section_header)
        out.append(new_body.rstrip())
    path.write_text("\n".join(out) + "\n", encoding="utf-8")
