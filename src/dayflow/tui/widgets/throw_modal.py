"""Modal for inbox-throwing a new task."""

from __future__ import annotations

from textual.app import ComposeResult
from textual.containers import Vertical
from textual.screen import ModalScreen
from textual.widgets import Input, Label


class ThrowModal(ModalScreen[str | None]):
    """Centered prompt — enter to submit, escape to cancel."""

    BINDINGS = [("escape", "cancel", "Cancel")]

    DEFAULT_CSS = """
    ThrowModal {
        align: center middle;
    }
    ThrowModal > Vertical {
        width: 60;
        height: auto;
        padding: 1 2;
        background: $surface;
        border: tall $accent;
    }
    ThrowModal Label {
        margin-bottom: 1;
    }
    """

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Label("→ throw a task into the inbox")
            yield Input(placeholder="e.g. 내일 회의자료 만들기", id="throw-input")

    def on_input_submitted(self, event: Input.Submitted) -> None:
        self.dismiss(event.value.strip() or None)

    def action_cancel(self) -> None:
        self.dismiss(None)
