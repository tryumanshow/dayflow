"""dayflow CLI — `dayflow` group + `inb` shortcut."""

from __future__ import annotations

import sys
from datetime import date

import click

from dayflow.data import DOING, DONE, STATUSES, TODO, WONT, Repo

# Status -> short glyph for plain-text output
_GLYPH = {TODO: "[ ]", DOING: "[~]", DONE: "[x]", WONT: "[-]"}


@click.group(help="dayflow — personal calendar / inbox-throw")
def cli() -> None:
    pass


@cli.command("add", help="Add a task to the inbox.")
@click.argument("title", nargs=-1, required=True)
def add_cmd(title: tuple[str, ...]) -> None:
    text = " ".join(title).strip()
    if not text:
        click.echo("error: empty title", err=True)
        sys.exit(2)
    repo = Repo()
    task = repo.add_task(text)
    click.echo(f"[#{task.id}] {task.title}")


@cli.command("today", help="Print today's tasks (plain text).")
def today_cmd() -> None:
    repo = Repo()
    tasks = repo.list_today()
    if not tasks:
        click.echo("inbox empty")
        return
    for t in tasks:
        click.echo(f"#{t.id:<4} {_GLYPH.get(t.status, '[?]')} {t.title}")


@cli.command("done", help="Mark a task done.")
@click.argument("task_id", type=int)
def done_cmd(task_id: int) -> None:
    _set_status(task_id, DONE)


@cli.command("doing", help="Mark a task in progress.")
@click.argument("task_id", type=int)
def doing_cmd(task_id: int) -> None:
    _set_status(task_id, DOING)


@cli.command("todo", help="Reset a task to TODO.")
@click.argument("task_id", type=int)
def todo_cmd(task_id: int) -> None:
    _set_status(task_id, TODO)


@cli.command("wont", help="Mark a task as won't-do.")
@click.argument("task_id", type=int)
def wont_cmd(task_id: int) -> None:
    _set_status(task_id, WONT)


@cli.command("review", help="Generate today's LLM review into the vault.")
@click.option("--date", "date_str", default=None, help="YYYY-MM-DD (default: today)")
def review_cmd(date_str: str | None) -> None:
    from dayflow.review import ReviewError, generate_daily_review

    target = date.fromisoformat(date_str) if date_str else date.today()
    try:
        body = generate_daily_review(target=target)
    except ReviewError as e:
        click.echo(f"error: {e}", err=True)
        sys.exit(1)
    click.echo(body)


def _set_status(task_id: int, status: str) -> None:
    if status not in STATUSES:
        click.echo(f"error: invalid status {status}", err=True)
        sys.exit(2)
    repo = Repo()
    try:
        task = repo.change_status(task_id, status)
    except LookupError:
        click.echo(f"error: task #{task_id} not found", err=True)
        sys.exit(1)
    click.echo(f"[#{task.id}] {_GLYPH[task.status]} {task.title}")


# ----- `inb` shortcut entry point ---------------------------------------------


@click.command(help="Throw a task into the inbox. Quick shortcut.")
@click.argument("title", nargs=-1, required=True)
def inbox_add_entry(title: tuple[str, ...]) -> None:
    text = " ".join(title).strip()
    if not text:
        click.echo("error: empty title", err=True)
        sys.exit(2)
    repo = Repo()
    task = repo.add_task(text)
    click.echo(f"[#{task.id}] {task.title}")


if __name__ == "__main__":
    cli()
