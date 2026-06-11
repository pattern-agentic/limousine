"""Modal screens: confirm, text viewer, env/secrets editors, settings, startup."""

from __future__ import annotations

import asyncio
import time

from rich.text import Text
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.widgets import Button, Checkbox, Input, Label, OptionList, Static, TextArea
from textual.widgets.option_list import Option

from ..backend import env as env_mod
from ..backend.secret_store import SecretStoreStatus

_DIFF_CSS = """
#box { width: 92%; height: 88%; border: round $primary; background: $surface; padding: 1 2; }
#title { text-style: bold; }
#status { color: $text-muted; padding-bottom: 1; }
#unlock { border: tall $warning; }
#panes { height: 1fr; }
#left { width: 1fr; border-right: solid $panel; padding-right: 1; }
#right { width: 1fr; padding-left: 1; }
.panehdr { text-style: bold; color: $accent; }
#active, #template { height: 1fr; border: tall $panel; }
#ebuttons { height: auto; align: right middle; padding-top: 1; }
#ebuttons Button { margin: 0 1; }
"""


def _unlocked(status: SecretStoreStatus) -> bool:
    return status in (SecretStoreStatus.VERIFIED, SecretStoreStatus.NEW_STAMP)


class ConfirmScreen(ModalScreen[bool]):
    DEFAULT_CSS = """
    ConfirmScreen { align: center middle; }
    #dialog { width: 56; height: auto; border: thick $warning; background: $surface; padding: 1 2; }
    #question { width: 100%; content-align: center middle; padding-bottom: 1; }
    #buttons { width: 100%; height: auto; align: center middle; }
    #buttons Button { margin: 0 1; }
    """
    BINDINGS = [
        Binding("y", "confirm", "Yes"),
        Binding("n", "cancel", "No"),
        Binding("escape", "cancel", "No", show=False),
    ]

    def __init__(self, message: str):
        super().__init__()
        self.message = message

    def compose(self) -> ComposeResult:
        with Vertical(id="dialog"):
            yield Label(self.message, id="question")
            with Horizontal(id="buttons"):
                yield Button("Yes", variant="error", id="yes")
                yield Button("No", variant="primary", id="no")

    def on_mount(self) -> None:
        self.query_one("#yes", Button).focus()  # default to Yes — the dialog itself is the guard

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "yes")

    def action_confirm(self) -> None:
        self.dismiss(True)

    def action_cancel(self) -> None:
        self.dismiss(False)


class CommandPicker(ModalScreen[object]):
    """Pick a command to run for a service. Enter runs the highlighted one; `e`
    edits it before running (a one-off command); `y` copies it. Dismisses with
    the command name, or `("raw", text)` for an edited command."""

    DEFAULT_CSS = """
    CommandPicker { align: center middle; }
    #box { width: 86%; height: 74%; border: round $primary; background: $surface; padding: 1 1; }
    #cmds { height: 1fr; }
    #edit { border: tall $accent; }
    #phint { color: $text-muted; padding: 0 1; }
    """
    BINDINGS = [
        Binding("e", "edit", "Edit"),
        Binding("y", "copy", "Copy"),
        Binding("escape", "cancel", "Cancel"),
    ]

    def __init__(self, sid: str, commands: dict[str, str]):
        super().__init__()
        self.sid = sid
        self.commands = commands

    def compose(self) -> ComposeResult:
        with Vertical(id="box"):
            yield Label(f"Run which command for {self.sid}?")
            yield OptionList(id="cmds")
            yield Input(id="edit", placeholder="edit the command, Enter to run")
            yield Static("Enter run · e edit before running · y copy · esc cancel", id="phint")

    def on_mount(self) -> None:
        ol = self.query_one("#cmds", OptionList)
        for name, cmd in self.commands.items():
            label = Text()
            label.append(name + "\n", style="bold")
            label.append("    " + cmd, style="green")
            ol.add_option(Option(label, id=name))
        if ol.option_count:
            ol.highlighted = 0  # pre-select the first command
        self.query_one("#edit", Input).display = False
        ol.focus()

    def _highlighted(self) -> tuple[str | None, str | None]:
        ol = self.query_one("#cmds", OptionList)
        i = ol.highlighted
        if i is None:
            return None, None
        opt = ol.get_option_at_index(i)
        return opt.id, self.commands.get(opt.id)

    def on_option_list_option_selected(self, event: OptionList.OptionSelected) -> None:
        self.dismiss(event.option.id)  # run the named command

    def action_copy(self) -> None:
        _, cmd = self._highlighted()
        if cmd:
            self.app.copy_text(cmd)

    def action_edit(self) -> None:
        _, cmd = self._highlighted()
        if cmd is None:
            return
        inp = self.query_one("#edit", Input)
        inp.value = cmd
        inp.display = True
        inp.focus()
        inp.cursor_position = len(cmd)

    def on_input_submitted(self, event: Input.Submitted) -> None:
        if event.input.id == "edit" and event.value.strip():
            self.dismiss(("raw", event.value))

    def action_cancel(self) -> None:
        inp = self.query_one("#edit", Input)
        if inp.display:  # exit edit mode back to the list — don't cancel the picker
            inp.display = False
            inp.value = ""
            self.query_one("#cmds", OptionList).focus()
        else:
            self.dismiss(None)


class TextModal(ModalScreen[None]):
    DEFAULT_CSS = """
    TextModal { align: center middle; }
    #box { width: 80%; height: 70%; border: round $primary; background: $surface; padding: 1 2; }
    """
    BINDINGS = [Binding("escape", "close", "Close"), Binding("q", "close", "Close", show=False)]

    def __init__(self, title: str, body: str):
        super().__init__()
        self._title = title
        self._body = body

    def compose(self) -> ComposeResult:
        with Vertical(id="box"):
            yield Label(self._title)
            with VerticalScroll():
                yield Static(self._body, id="body")

    def action_close(self) -> None:
        self.dismiss(None)


_LBL = 10  # right-aligned label column width


def _row(label: str, value: str) -> str:
    return f"{label + ':':>{_LBL}}  {value}"


def format_git_status(s) -> str:
    if not s.exists:
        return _row("project", s.project) + "\n" + " " * (_LBL + 2) + (s.error or "not on disk")
    lines = [_row("branch", f"{s.branch} @ {s.short_sha}")]
    if s.subject:
        lines.append(_row("head", s.subject))
    lines.append(_row("dirty", f"{s.dirty} ({s.dirty_code} code, {s.dirty_lock} lock)"))
    for f in s.code_files[:12]:
        lines.append(f"{'':>{_LBL}}  {f.status} {f.path}")
    lines.append(_row("upstream", f"{s.upstream}  ↓{s.behind_upstream} ↑{s.ahead_upstream}") if s.upstream
                 else _row("upstream", "(none)"))
    if s.behind_main:
        lines.append(_row(f"vs {s.main_branch or 'main'}", f"behind {s.behind_main}"))
    if s.latest_tag:
        since = f"  (+{s.commits_since_tag} commits)" if s.commits_since_tag else ""
        lines.append(_row("tag", f"{s.latest_tag}{since}"))
    if s.last_fetched:
        lines.append(_row("fetched", time.strftime("%Y-%m-%d %H:%M", time.localtime(s.last_fetched))))
    for d in s.config_deltas:
        if d.has_any:
            lines.append(_row("drift", f"{d.module}  env={d.has_env_delta} secrets={d.has_secrets_delta}"))
    if s.error:
        lines.append(_row("error", s.error))
    return "\n".join(lines)


def _git_brief(name: str, s, namew: int = 20) -> Text:
    """One aligned row: dot · name · branch · tag · flags (fixed columns)."""
    t = Text()
    if s is None or not s.exists:
        t.append("○ ", style="grey50")
        t.append(name.ljust(namew))
        t.append("   …" if s is None else "   not cloned", style="grey50")
        return t
    t.append("● ", style="green")
    t.append(name.ljust(namew) + "  ")
    t.append((s.branch or "?").ljust(22))
    tag = (s.latest_tag or "") + (f"+{s.commits_since_tag}" if s.commits_since_tag else "")
    t.append(tag.ljust(14), style="cyan")
    flags = []
    if s.dirty:
        flags.append(f"✎{s.dirty}")
    if s.behind_main:
        flags.append(f"↓{s.behind_main}{s.main_branch or 'main'}")
    if s.behind_upstream:
        flags.append(f"↓{s.behind_upstream}↑{s.ahead_upstream or 0}")
    if any(d.has_any for d in s.config_deltas):
        flags.append("drift")
    if flags:
        t.append("  ".join(flags), style="yellow")
    return t


class GitDashboard(ModalScreen[None]):
    """Separate git view: every project's state (branch/sha/dirty/upstream/behind
    main/tag/fetched/drift) with Fetch, ff-only Pull, and Clone."""

    DEFAULT_CSS = """
    GitDashboard { align: center middle; }
    #gbox { width: 92%; height: 86%; border: round $primary; background: $surface; }
    #projects { height: 45%; border-bottom: solid $panel; }
    #dtitle { height: 1; padding: 0 2; background: $boost; text-style: bold; }
    #detailwrap { height: 1fr; padding: 1 2; }
    #ghint { dock: bottom; color: $text-muted; padding: 0 1; background: $boost; }
    """
    BINDINGS = [
        Binding("f", "fetch", "Fetch"),
        Binding("p", "pull", "Pull"),
        Binding("c", "clone", "Clone"),
        Binding("escape", "close", "Close"),
    ]

    def __init__(self, backend, initial: str | None = None):
        super().__init__()
        self.backend = backend
        self.initial = initial
        self._names = list(backend.projects)
        self._status: dict = {}
        self._namew = min(max((len(n) for n in self._names), default=8), 28)

    def compose(self) -> ComposeResult:
        with Vertical(id="gbox"):
            yield OptionList(id="projects")
            yield Static("", id="dtitle")
            with VerticalScroll(id="detailwrap"):
                yield Static("loading…", id="detail")
            yield Static("f fetch · p pull (ff-only) · c clone · esc close", id="ghint")

    def on_mount(self) -> None:
        ol = self.query_one("#projects", OptionList)
        for n in self._names:
            ol.add_option(Option(_git_brief(n, None, self._namew), id=n))
        if self._names:
            ol.highlighted = self._names.index(self.initial) if self.initial in self._names else 0
        ol.focus()
        self.run_worker(self._load_all(), exclusive=True)

    async def _load_all(self) -> None:
        results = await asyncio.gather(*(self.backend.git_status(n) for n in self._names))
        self._status = dict(zip(self._names, results))
        self._refresh_list()
        self._refresh_detail()

    def _selected(self) -> str | None:
        i = self.query_one("#projects", OptionList).highlighted
        return self._names[i] if i is not None and 0 <= i < len(self._names) else None

    def _refresh_list(self) -> None:
        ol = self.query_one("#projects", OptionList)
        cur = ol.highlighted
        ol.clear_options()
        for n in self._names:
            ol.add_option(Option(_git_brief(n, self._status.get(n), self._namew), id=n))
        if cur is not None:
            ol.highlighted = cur

    def _refresh_detail(self) -> None:
        n = self._selected()
        title = self.query_one("#dtitle", Static)
        body = self.query_one("#detail", Static)
        if n is None:
            title.update("")
            body.update("")
            return
        st = self._status.get(n)
        if st is None:
            title.update(Text(f"▶ {n}"))
            body.update("loading…")
            return
        dot = "[green]●[/]" if st.exists else "[grey50]○ not cloned[/]"
        title.update(Text.from_markup(f"▶ {n}   {dot}"))
        body.update(format_git_status(st))

    def on_option_list_option_highlighted(self, event: OptionList.OptionHighlighted) -> None:
        self._refresh_detail()

    def action_fetch(self) -> None:
        self.run_worker(self._op("fetch"), exclusive=True)

    def action_pull(self) -> None:
        self.run_worker(self._op("pull"), exclusive=True)

    def action_clone(self) -> None:
        n = self._selected()
        if not n:
            return
        if (st := self._status.get(n)) and st.exists:
            self.notify(f"{n} already cloned")
            return
        # hand off to the main view so the clone streams into the copyable log
        self.dismiss(("clone", n))

    async def _op(self, kind: str) -> None:
        n = self._selected()
        if not n:
            return
        self.query_one("#detail", Static).update(f"{kind}ing {n}…")
        if kind == "fetch":
            self._status[n] = await self.backend.git_refresh(n)
        elif kind == "pull":
            res = await self.backend.git_pull(n)
            self.notify(res.message or ("pulled" if res.ok else "pull failed"),
                        severity="information" if res.ok else "error")
            self._status[n] = res.status
        self._refresh_list()
        self._refresh_detail()

    def action_close(self) -> None:
        self.dismiss(None)


class ActionMenu(ModalScreen[str]):
    """A small 'more actions' menu so the footer can stay uncluttered."""

    DEFAULT_CSS = """
    ActionMenu { align: center middle; }
    #box { width: 44; height: auto; border: round $primary; background: $surface; padding: 1 1; }
    #title { text-style: bold; padding: 0 1; }
    """
    BINDINGS = [Binding("escape", "cancel", "Cancel")]

    def __init__(self, items: list[tuple[str, str]]):
        super().__init__()
        self.items = items  # (action_id, label)

    def compose(self) -> ComposeResult:
        with Vertical(id="box"):
            yield Label("Menu", id="title")
            ol = OptionList(id="menu")
            yield ol

    def on_mount(self) -> None:
        ol = self.query_one("#menu", OptionList)
        for act, label in self.items:
            ol.add_option(Option(label, id=act))
        ol.highlighted = 0
        ol.focus()

    def on_option_list_option_selected(self, event: OptionList.OptionSelected) -> None:
        self.dismiss(event.option.id)

    def action_cancel(self) -> None:
        self.dismiss(None)


class _DiffEditor(ModalScreen[bool]):
    """Side-by-side editor: editable `active` (left) vs read-only `template`
    (right), with an 'add missing keys from template' action. Subclasses supply
    the kind label, file names, and how to load/save (env vs secrets)."""

    BINDINGS = [
        Binding("ctrl+s", "save", "Save"),
        Binding("ctrl+t", "add_missing", "Add from template"),
        Binding("escape", "cancel", "Cancel"),
    ]
    _kind = "env"
    _left_hdr = "active"

    def __init__(self, backend, sid: str):
        super().__init__()
        self.backend = backend
        self.sid = sid
        self._template: dict[str, str] = {}

    def compose(self) -> ComposeResult:
        with Vertical(id="box"):
            yield Label(f"{self._kind} — {self.sid}", id="title")
            yield Static("", id="status")
            yield Input(placeholder="paste AGE-SECRET-KEY-… to unlock", password=True, id="unlock")
            with Horizontal(id="panes"):
                with Vertical(id="left"):
                    yield Static(self._left_hdr, classes="panehdr", id="lefthdr")
                    yield TextArea(id="active")
                with Vertical(id="right"):
                    yield Static("template", classes="panehdr", id="righthdr")
                    yield TextArea(id="template")
            with Horizontal(id="ebuttons"):
                yield Button("＋ add from template (ctrl+t)", id="add")
                yield Button("Save (ctrl+s)", variant="success", id="save")
                yield Button("Cancel", id="cancel")

    def on_mount(self) -> None:
        info = self.backend.find_service(self.sid)
        c = info.module_config if info else None
        active_file, source_file = self._file_names(c)
        self.query_one("#lefthdr", Static).update(f"{self._left_hdr} — {active_file}")
        self.query_one("#righthdr", Static).update(f"template — {source_file}")
        self.query_one("#template", TextArea).read_only = True
        self.query_one("#unlock", Input).display = False
        self.run_worker(self._load(), exclusive=True)

    # ---- subclass hooks --------------------------------------------------

    def _file_names(self, cfg) -> tuple[str, str]:
        return ((cfg.active_env_file if cfg else "?"), (cfg.source_env_file if cfg else "?"))

    async def _load(self) -> None:
        cmp = await self.backend.get_env(self.sid)
        self._template = dict(cmp.source_content)
        self.query_one("#template", TextArea).text = env_mod.serialize(cmp.source_content) or "(no template file)"
        active = self.query_one("#active", TextArea)
        active.text = env_mod.serialize(cmp.active_content)
        active.focus()
        self._refresh_status()

    def _save_active(self, content: dict[str, str]) -> None:
        self.backend.save_env(self.sid, content)

    # ---- shared behaviour ------------------------------------------------

    def _editable(self) -> bool:
        return not self.query_one("#active", TextArea).read_only

    def _active_keys(self) -> dict[str, str]:
        return env_mod.parse_env_lines(self.query_one("#active", TextArea).text.split("\n"))

    def _set_status(self, markup: str) -> None:
        self.query_one("#status", Static).update(Text.from_markup(markup))

    def _refresh_status(self) -> None:
        if not self._editable():
            return
        active = self._active_keys()
        missing = sorted(set(self._template) - set(active))
        extra = sorted(set(active) - set(self._template))
        parts = [f"{len(active)} active · {len(self._template)} in template"]
        if missing:
            parts.append(f"[yellow]{len(missing)} missing: {', '.join(missing)}[/]")
        if extra:
            parts.append(f"[cyan]{len(extra)} not in template: {', '.join(extra)}[/]")
        self._set_status("    ".join(parts))

    def on_text_area_changed(self, event) -> None:
        if event.text_area.id == "active":
            self._refresh_status()

    def action_add_missing(self) -> None:
        if not self._editable():
            self.notify("nothing to edit yet")
            return
        ed = self.query_one("#active", TextArea)
        active = self._active_keys()
        additions = {k: v for k, v in self._template.items() if k not in active}
        if not additions:
            self.notify("nothing missing from the template")
            return
        base = ed.text.rstrip("\n")
        add = env_mod.serialize(additions).rstrip("\n")
        ed.text = f"{base}\n{add}\n" if base else f"{add}\n"
        self._refresh_status()
        self.notify(f"added {len(additions)} key(s) from template — fill in values, then Save")

    def action_save(self) -> None:
        try:
            self._save_active(self._active_keys())
            self.dismiss(True)
        except Exception as e:
            self.notify(f"save failed: {e}", severity="error")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "add":
            self.action_add_missing()
        elif event.button.id == "save":
            self.action_save()
        else:
            self.dismiss(False)

    def action_cancel(self) -> None:
        self.dismiss(False)


class EnvEditorScreen(_DiffEditor):
    DEFAULT_CSS = "EnvEditorScreen { align: center middle; }" + _DIFF_CSS
    _kind = "env"


class SecretsScreen(_DiffEditor):
    DEFAULT_CSS = "SecretsScreen { align: center middle; }" + _DIFF_CSS
    _kind = "secrets"
    _left_hdr = "active (decrypted)"

    def _file_names(self, cfg) -> tuple[str, str]:
        return ((cfg.active_secrets_env_file if cfg else "?"), (cfg.source_secrets_file if cfg else "?"))

    async def _load(self) -> None:
        # template is cleartext placeholders — always shown, even while locked
        keys = await self.backend.secrets_keys(self.sid)
        self._template = dict(keys.source_content)
        self.query_one("#template", TextArea).text = env_mod.serialize(keys.source_content) or "(no template file)"
        unlock = self.query_one("#unlock", Input)
        active = self.query_one("#active", TextArea)
        if not _unlocked(self.backend.secret_store_status()):
            unlock.display = True
            unlock.focus()
            active.read_only = True
            active.text = ""
            self._set_status("🔒 [yellow]locked[/] — paste your age key to view/edit active secrets")
            return
        unlock.display = False
        active.read_only = False
        try:
            secrets = await self.backend.get_secrets(self.sid)
        except Exception as e:
            active.read_only = True
            self._set_status(f"[red]decrypt failed: {e}[/]")
            return
        active.text = env_mod.serialize(secrets)
        active.focus()
        self._refresh_status()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        if event.input.id == "unlock":
            self.run_worker(self._do_unlock(event.value), exclusive=True)

    async def _do_unlock(self, key: str) -> None:
        status = await self.backend.unlock_secrets(key)
        if _unlocked(status):
            self.query_one("#unlock", Input).value = ""
            await self._load()
        else:
            self._set_status("[red]key rejected (stamp mismatch or invalid key)[/]")

    def action_save(self) -> None:
        self.run_worker(self._save(), exclusive=True)

    async def _save(self) -> None:
        if not (self._editable() and _unlocked(self.backend.secret_store_status())):
            self.notify("secret store is locked", severity="warning")
            return
        try:
            await self.backend.save_secrets(self.sid, self._active_keys())
            self.dismiss(True)
        except Exception as e:
            self.notify(f"save failed: {e}", severity="error")


class SettingsScreen(ModalScreen[bool]):
    DEFAULT_CSS = """
    SettingsScreen { align: center middle; }
    #box { width: 64; height: auto; border: round $primary; background: $surface; padding: 1 2; }
    #title { text-style: bold; padding-bottom: 1; }
    #box Input { margin-bottom: 1; }
    #buttons { height: auto; align: right middle; padding-top: 1; }
    #buttons Button { margin: 0 1; }
    """
    BINDINGS = [Binding("escape", "cancel", "Cancel")]

    def __init__(self, backend):
        super().__init__()
        self.backend = backend

    def compose(self) -> ComposeResult:
        ws = self.backend.workspace
        mcp = ws.mcp_config if ws else None
        with Vertical(id="box"):
            yield Label("Settings", id="title")
            yield Checkbox("MCP enabled", value=mcp.enabled if mcp else True, id="mcp_enabled")
            yield Label("MCP port")
            yield Input(str(mcp.port if mcp else 6891), id="mcp_port")
            yield Label("Git SSH key path")
            yield Input(ws.git_ssh_key_path or "" if ws else "", id="ssh_key")
            with Horizontal(id="buttons"):
                yield Button("Save", variant="success", id="save")
                yield Button("Cancel", id="cancel")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id != "save":
            self.dismiss(False)
            return
        try:
            port = int(self.query_one("#mcp_port", Input).value)
        except ValueError:
            self.notify("port must be a number", severity="error")
            return
        self.backend.update_settings(
            mcp_enabled=self.query_one("#mcp_enabled", Checkbox).value,
            mcp_port=port,
            git_ssh_key_path=self.query_one("#ssh_key", Input).value.strip() or None,
        )
        self.dismiss(True)

    def action_cancel(self) -> None:
        self.dismiss(False)


class StartupScreen(ModalScreen[str]):
    DEFAULT_CSS = """
    StartupScreen { align: center middle; }
    #box { width: 80; height: auto; border: round $primary; background: $surface; padding: 1 2; }
    #title { text-style: bold; padding-bottom: 1; }
    #recents { height: auto; max-height: 10; margin-bottom: 1; }
    #buttons { height: auto; align: right middle; padding-top: 1; }
    #buttons Button { margin: 0 1; }
    """
    BINDINGS = [Binding("escape", "quit", "Quit")]

    def __init__(self, backend):
        super().__init__()
        self.backend = backend

    def compose(self) -> ComposeResult:
        recents = self.backend.recent_workspaces()
        with Vertical(id="box"):
            yield Label("Open a workspace", id="title")
            if recents:
                yield OptionList(*recents, id="recents")
            else:
                yield Static("No recent workspaces — type a path below, or quit (Esc) "
                             "and run  limousine --setup", id="recents")
            yield Input(placeholder="absolute path to a .wksp file", id="path")
            with Horizontal(id="buttons"):
                yield Button("Open", variant="primary", id="open")
                yield Button("Quit", id="quit")

    def on_option_list_option_selected(self, event: OptionList.OptionSelected) -> None:
        self.dismiss(str(event.option.prompt))

    def on_input_submitted(self, event: Input.Submitted) -> None:
        if event.value.strip():
            self.dismiss(event.value.strip())

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "open":
            path = self.query_one("#path", Input).value.strip()
            if path:
                self.dismiss(path)
        else:
            self.action_quit()

    def action_quit(self) -> None:
        self.app.exit()
