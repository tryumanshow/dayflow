"""dayflow Textual TUI — `df` command."""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.reactive import reactive
from textual.widgets import Footer, Header, ListItem, ListView, Static

from dayflow.data import DOING, DONE, TODO, Repo, Task

from .widgets.throw_modal import ThrowModal

_GLYPH = {TODO: "[ ]", DOING: "[~]", DONE: "[x]"}
_NEXT_STATE = {TODO: DOING, DOING: DONE, DONE: TODO}


class TaskRow(ListItem):
    def __init__(self, task: Task) -> None:
        super().__init__(Static(self._format_label(task)))
        self.task_data = task

    @staticmethod
    def _format_label(task: Task) -> str:
        glyph = _GLYPH.get(task.status, "[?]")
        return f"{glyph}  #{task.id:<3} {task.title}"


class DayflowApp(App[None]):
    CSS = """
    Screen {
        layout: vertical;
    }
    #body {
        height: 1fr;
    }
    #left {
        width: 50%;
        border: round $primary;
        padding: 0 1;
    }
    #right {
        width: 50%;
        layout: vertical;
    }
    #notes {
        height: 1fr;
        border: round $secondary;
        padding: 0 1;
    }
    #history {
        height: 12;
        border: round $secondary;
        padding: 0 1;
    }
    """

    BINDINGS = [
        Binding("a", "throw", "Add"),
        Binding("space", "toggle_status", "Toggle"),
        Binding("e", "edit_note", "Note"),
        Binding("r", "refresh", "Refresh"),
        Binding("j", "cursor_down", "Down", show=False),
        Binding("k", "cursor_up", "Up", show=False),
        Binding("q", "quit", "Quit"),
    ]

    selected_id: reactive[int | None] = reactive(None)

    def __init__(self, repo: Repo | None = None) -> None:
        super().__init__()
        self.repo = repo or Repo()

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        with Horizontal(id="body"):
            yield ListView(id="left")
            with Vertical(id="right"):
                yield Static("", id="notes")
                yield Static("", id="history")
        yield Footer()

    def on_mount(self) -> None:
        self.title = "dayflow"
        self.sub_title = "today"
        self.refresh_tasks()

    # ---- data refresh --------------------------------------------------------

    def refresh_tasks(self, focus_id: int | None = None) -> None:
        list_view = self.query_one("#left", ListView)
        list_view.clear()
        tasks = self.repo.list_today()
        if not tasks:
            list_view.append(ListItem(Static("inbox empty — press 'a' to throw a task")))
            self.selected_id = None
            self._format_label_panels(None)
            return
        target_index = 0
        for i, task in enumerate(tasks):
            list_view.append(TaskRow(task))
            if focus_id is not None and task.id == focus_id:
                target_index = i
        list_view.index = target_index
        # selection refresh after the list mount cycle
        self.call_after_refresh(self._sync_selection)

    def _sync_selection(self) -> None:
        list_view = self.query_one("#left", ListView)
        item = list_view.highlighted_child
        if isinstance(item, TaskRow):
            self.selected_id = item.task_data.id
            self._format_label_panels(item.task_data)
        else:
            self.selected_id = None
            self._format_label_panels(None)

    def on_list_view_highlighted(self, event: ListView.Highlighted) -> None:
        item = event.item
        if isinstance(item, TaskRow):
            self.selected_id = item.task_data.id
            self._format_label_panels(item.task_data)
        else:
            self.selected_id = None
            self._format_label_panels(None)

    def _format_label_panels(self, task: Task | None) -> None:
        notes_w = self.query_one("#notes", Static)
        hist_w = self.query_one("#history", Static)
        if task is None:
            notes_w.update("(no task selected)")
            hist_w.update("")
            return

        notes = self.repo.list_notes(task.id)
        if notes:
            body = "\n\n---\n\n".join(n.body_md for n in notes)
        else:
            body = "(no notes — press 'e' to add one)"
        notes_w.update(f"[b]#{task.id} {task.title}[/b]\n\n{body}")

        history = self.repo.list_state_history(task.id)
        time_entries = self.repo.list_time_entries(task.id)
        lines = ["[b]history[/b]"]
        for h in history[-6:]:
            arrow = f"{h.from_status or '∅'} → {h.to_status}"
            lines.append(f"  {h.changed_at[11:19]}  {arrow}")
        if time_entries:
            total = sum((e.duration_sec or 0) for e in time_entries)
            lines.append(f"[dim]focused: {total // 60}m {total % 60}s[/dim]")
        hist_w.update("\n".join(lines))

    # ---- actions -------------------------------------------------------------

    def action_throw(self) -> None:
        def after(value: str | None) -> None:
            if value:
                task = self.repo.add_task(value)
                self.refresh_tasks(focus_id=task.id)

        self.push_screen(ThrowModal(), after)

    def action_toggle_status(self) -> None:
        if self.selected_id is None:
            return
        task = self.repo.get_task(self.selected_id)
        if task is None:
            return
        next_state = _NEXT_STATE.get(task.status, TODO)
        self.repo.change_status(task.id, next_state)
        self.refresh_tasks(focus_id=task.id)

    def action_edit_note(self) -> None:
        if self.selected_id is None:
            return
        task_id = self.selected_id
        with self.suspend():
            text = _open_external_editor()
        if text:
            self.repo.add_note(task_id, text)
        self.refresh_tasks(focus_id=task_id)

    def action_refresh(self) -> None:
        self.refresh_tasks(focus_id=self.selected_id)

    def action_cursor_down(self) -> None:
        self.query_one("#left", ListView).action_cursor_down()

    def action_cursor_up(self) -> None:
        self.query_one("#left", ListView).action_cursor_up()


def _open_external_editor() -> str:
    editor = os.environ.get("EDITOR", "vim")
    with tempfile.NamedTemporaryFile(suffix=".md", mode="w+", delete=False) as f:
        tmp = Path(f.name)
    try:
        subprocess.call([editor, str(tmp)])
        return tmp.read_text(encoding="utf-8").strip()
    finally:
        try:
            tmp.unlink()
        except OSError:
            pass


def run() -> None:
    DayflowApp().run()


if __name__ == "__main__":
    run()
