"""Textual front-end. Tree sidebar (project → module → service) + log pane.
All process/workspace state lives behind the Backend; this owns rendering, key
dispatch, the modal screens, and the MCP server lifecycle."""

from __future__ import annotations

import asyncio
import os
import shutil
import socket
import subprocess
import tempfile
from pathlib import Path

from rich.text import Text
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.widgets import Footer, Header, Input, RichLog, Static, Tree

from ..backend.backend import Backend, BackendError, LocalBackend
from ..backend.mcp_server import build_mcp, make_server
from ..backend.secret_store import SecretStoreStatus
from ..core.dtos import ProcessStatus, ServiceState, StopSignal
from . import screens
from .widgets import SelectableRichLog

_DOT = {
    ProcessStatus.running: "[green]●[/]",
    ProcessStatus.stopped: "[grey50]○[/]",
    ProcessStatus.orphaned: "[yellow]◍[/]",
}

_SECRET_LABEL = {
    SecretStoreStatus.VERIFIED: "🔓 secrets",
    SecretStoreStatus.NEW_STAMP: "🔓 secrets (new)",
    SecretStoreStatus.MISSING_KEY: "🔒 secrets locked",
    SecretStoreStatus.MISMATCH: "⚠ secrets mismatch",
}


class LimousineApp(App):
    CSS = """
    #sidebar { width: auto; min-width: 18; max-width: 60%; border-right: solid $panel; }
    #current { height: 1; padding: 0 1; background: $boost; text-style: bold; }
    #log { height: 1fr; border: round $primary; padding: 0 1; }
    #liveline { height: 1; padding: 0 1; color: $text-muted; }
    #liveline.waiting { color: $warning; text-style: bold; }
    #stdin { dock: bottom; }
    #stdin.waiting { border: tall $warning; }
    """

    BINDINGS = [
        # shown in the footer — the run / read loop
        Binding("s", "start", "Start"),
        Binding("x", "stop", "Stop"),
        Binding("i", "input", "Input"),
        Binding("e", "env", "Env"),
        Binding("v", "secrets", "Secrets"),
        Binding("g", "git", "Git"),
        Binding("y", "copy_selection", "Copy sel"),
        Binding("m", "menu", "Menu"),
        Binding("q", "quit", "Quit"),
        # still bound, hidden from the footer (also reachable via the menu)
        Binding("w", "save_log", "Save log", show=False),
        Binding("c", "clone", "Clone", show=False),
        Binding("r", "start", "Start", show=False),  # synonym for s (muscle memory)
        Binding("k", "kill", "Kill orphan", show=False),
        Binding("a", "agent_guide", "Agent guide", show=False),
        Binding("R", "reload", "Reload workspace", show=False),  # shift+R (was r)
        Binding("p", "reload_project", "Reload project", show=False),
        Binding("comma", "settings", "Settings", show=False),
        Binding("o", "open", "Open workspace", show=False),
        Binding("ctrl+l", "clear", "Clear log", show=False),
    ]

    def __init__(self, backend: Backend, mcp_allowed: bool = True, mcp_port_override: int | None = None,
                 mcp_host: str = "127.0.0.1"):
        super().__init__()
        self.backend = backend
        self.mcp_host = mcp_host
        self.backend.on_output = self._on_output
        self.backend.on_state = self._on_state
        self.backend.on_workspace_change = lambda: self.call_after_refresh(self._rebuild)
        self.backend.on_secret_status = self._on_secret_status
        self._mcp_label = ""
        self._secret_label = ""
        self.mcp_allowed = mcp_allowed
        self.mcp_port_override = mcp_port_override
        self.selected: str | None = None       # service under the tree cursor (actions + header)
        self._displayed: str | None = None      # service whose log is in the pane (debounced)
        self.current_project: str | None = None
        self._pending: list[str] = []
        self._waiting = False
        self._auto_input = False
        self._stopping: set[str] = set()  # services with a stop escalation in flight
        self._svc_nodes: dict = {}
        self._svc_short: dict[str, str] = {}
        self._stale_ids: set[str] = set()  # running services dropped by a reload
        self._mcp_server = None
        self._display_timer = None
        self._display_debounce = 0.4  # header instant, log swaps after the cursor settles

    def compose(self) -> ComposeResult:
        yield Header()
        with Horizontal():
            yield Tree("workspace", id="sidebar")
            with Vertical(id="right"):
                yield Static("", id="current")
                yield SelectableRichLog(id="log", highlight=False, markup=False, wrap=False, max_lines=5000)
                yield Static("", id="liveline")
                yield Input(id="stdin", placeholder="input for selected service — Enter sends")
        yield Footer()

    def on_mount(self) -> None:
        self.query_one("#stdin", Input).display = False
        self.query_one("#sidebar", Tree).show_root = False
        self.set_interval(0.05, self._drain)
        self.run_worker(self._startup(), exclusive=False)

    async def _startup(self) -> None:
        try:
            await self.backend.aopen()  # DaemonBackend connects here
        except Exception as e:
            self.notify(f"connect failed: {e}", severity="error")
            return
        if self.backend.workspace is None:
            self._prompt_open()
        else:
            self._rebuild()
            self._refresh_mcp()
            self._secret_label = _SECRET_LABEL.get(self.backend.secret_store_status(), "")
            self._update_subtitle()

    # ---- sidebar ---------------------------------------------------------

    def _rebuild(self) -> None:
        ws = self.backend.workspace
        self.title = f"limousine · {ws.name if ws else 'no workspace'}"
        tree = self.query_one("#sidebar", Tree)
        tree.clear()
        self._svc_nodes.clear()
        self._svc_short.clear()
        states = self.backend.service_states()
        # services = definition + still-running ghosts (dropped by a reload)
        self._stale_ids = {s.id for s in self.backend.list_services()} - self._definition_ids()
        grouped: dict[str, dict[str, list]] = {}
        for s in self.backend.list_services():
            grouped.setdefault(s.project_name, {}).setdefault(s.module_name, []).append(s)

        def add_service(mnode, s) -> None:
            self._svc_short[s.id] = s.service_name
            st = states.get(s.id)
            leaf = mnode.add_leaf(
                self._svc_label(s.id, st.status if st else ProcessStatus.stopped),
                data={"type": "service", "id": s.id, "name": s.project_name},
            )
            self._svc_nodes[s.id] = leaf

        rendered = set()
        for name, lp in self.backend.projects.items():
            rendered.add(lp.name)
            pnode = tree.root.add(lp.name, data={"type": "project", "name": name}, expand=True)
            if not lp.exists_on_disk:
                pnode.add_leaf("(not cloned — press c)", data={"type": "clone", "name": name})
                continue
            if lp.load_error:
                pnode.add_leaf("⚠ load error", data={"type": "error", "name": name})
                continue
            for module_name, svcs in grouped.get(lp.name, {}).items():
                mnode = pnode.add(module_name, data={"type": "module", "name": name}, expand=True)
                for s in svcs:
                    add_service(mnode, s)
        # ghosts whose whole project was removed from the workspace but still run
        for pname, mods in grouped.items():
            if pname in rendered:
                continue
            pnode = tree.root.add(pname, data={"type": "project", "name": pname}, expand=True)
            for module_name, svcs in mods.items():
                mnode = pnode.add(module_name, data={"type": "module", "name": pname}, expand=True)
                for s in svcs:
                    add_service(mnode, s)

        first = next(iter(self._svc_nodes), None)
        self.selected = first
        if first and self.backend.find_service(first):
            self.current_project = self.backend.find_service(first).project_name
        self._show_displayed(first)

    def _definition_ids(self) -> set[str]:
        ids = set()
        for lp in self.backend.projects.values():
            if lp.project_data:
                for m in lp.project_data.modules:
                    ids.update(f"{m.name}/{sn}" for sn in m.services)
        return ids

    def _svc_label(self, sid: str, status: ProcessStatus) -> Text:
        name = self._svc_short.get(sid, sid)
        suffix = " [dim](removed)[/]" if sid in self._stale_ids else ""
        return Text.from_markup(f"{_DOT[status]} {name}{suffix}")

    # ---- cursor → current selection -------------------------------------

    def _cursor_node_data(self) -> dict:
        node = self.query_one("#sidebar", Tree).cursor_node
        return (node.data or {}) if node else {}

    def _cursor_sid(self) -> str | None:
        data = self._cursor_node_data()
        return data["id"] if data.get("type") == "service" else None

    def _target_sid(self) -> str | None:
        # what s/x/etc act on: the service under the cursor, else the shown one
        return self._cursor_sid() or self.selected

    def _cursor_project(self) -> str | None:
        return self._cursor_node_data().get("name") or self.current_project

    def on_tree_node_highlighted(self, event: Tree.NodeHighlighted) -> None:
        data = event.node.data or {}
        if data.get("name"):
            self.current_project = data["name"]
        if data.get("type") == "service":
            sid = data["id"]
            self.selected = sid
            if sid != self._displayed:
                self._clear_pane()           # immediate cue that we're switching
            self._update_header()            # instant
            self._schedule_display(sid)      # new log loads once the cursor settles

    def _clear_pane(self) -> None:
        """Blank the log the moment the selection changes; the new one loads
        after the debounce. Pausing `_displayed` keeps stray output from either
        service out of the now-empty pane during the transition."""
        self._displayed = None
        self._pending.clear()
        self.query_one("#log", RichLog).clear()
        self._update_liveline()

    # ---- log rendering (debounced like bashbuild) -----------------------

    def _update_header(self) -> None:
        try:
            cur = self.query_one("#current", Static)
        except Exception:
            return
        sid = self.selected
        if not sid:
            cur.update("no service selected")
            return
        st = self._state_of(sid)
        status = st.status if st else ProcessStatus.stopped
        if sid in self._stopping and status == ProcessStatus.running:
            suffix = "    " + self._stop_hint(st)
        elif sid != self._displayed:
            suffix = "    loading log…"
        else:
            suffix = ""
        cur.update(Text.from_markup(f"▶ {sid}    {_DOT[status]} {status.value}{suffix}"))

    @staticmethod
    def _stop_hint(st) -> str:
        # next_signal is the signal that WOULD be sent next, so it reveals what
        # was just sent during the escalation.
        nxt = st.next_signal if st else StopSignal.sigint
        if nxt == StopSignal.sigterm:
            return "[yellow]⏳ stopping — sent SIGINT, waiting…[/]"
        if nxt == StopSignal.sigkill:
            return "[yellow]⏳ stopping — escalating SIGTERM → SIGKILL…[/]"
        return "[yellow]⏳ stopping…[/]"

    def _schedule_display(self, sid: str) -> None:
        if self._display_timer is not None:
            self._display_timer.stop()
            self._display_timer = None
        if sid == self._displayed:
            return
        self._display_timer = self.set_timer(self._display_debounce, self._flush_display)

    def _flush_display(self) -> None:
        self._display_timer = None
        self._show_displayed(self.selected)

    def _show_displayed(self, sid: str | None) -> None:
        """Swap the log pane to `sid` now (bypassing the debounce)."""
        if self._display_timer is not None:
            self._display_timer.stop()
            self._display_timer = None
        self._displayed = sid
        log = self.query_one("#log", RichLog)
        self._pending.clear()
        log.clear()
        buf = list(self.backend.buffer(sid)) if sid else []
        if buf:
            log.write(Text.from_ansi("\n".join(buf)))
        self._update_header()
        self._update_liveline()

    def _update_liveline(self) -> None:
        sid = self._displayed
        tail = self.backend.tail(sid) if sid else ""
        waiting = bool(sid) and self.backend.awaiting_input(sid)
        try:
            live = self.query_one("#liveline", Static)
        except Exception:
            return
        text = Text.from_ansi(tail)
        if waiting:
            text.append("  ⌨ waiting for input", style="reverse")
        live.update(text)
        live.set_class(waiting, "waiting")
        self._sync_input(waiting)

    def _sync_input(self, waiting: bool) -> None:
        inp = self.query_one("#stdin", Input)
        if waiting and not self._waiting:
            inp.display = True
            inp.add_class("waiting")
            inp.focus()
            self._auto_input = True
        elif not waiting and self._waiting and self._auto_input:
            self._hide_input()
        self._waiting = waiting

    def _hide_input(self) -> None:
        inp = self.query_one("#stdin", Input)
        inp.display = False
        inp.value = ""
        inp.remove_class("waiting")
        self._auto_input = False
        self.query_one("#sidebar", Tree).focus()

    def _drain(self) -> None:
        self._update_liveline()
        if not self._pending:
            return
        take = self._pending[:300]
        del self._pending[:300]
        self.query_one("#log", RichLog).write(Text.from_ansi("\n".join(take)))

    # ---- backend callbacks ----------------------------------------------

    def _on_output(self, sid: str, newlines: list) -> None:
        if sid == self._displayed:
            self._pending.extend(newlines)

    def _on_state(self, state: ServiceState) -> None:
        leaf = self._svc_nodes.get(state.service_id)
        if leaf is not None:
            leaf.set_label(self._svc_label(state.service_id, state.status))
        if state.service_id == self.selected:
            self._update_header()

    # ---- MCP lifecycle ---------------------------------------------------

    def _refresh_mcp(self) -> None:
        if not isinstance(self.backend, LocalBackend):
            self._mcp_label = "daemon (MCP server-side)"
            self._update_subtitle()
            return
        if self._mcp_server is not None:
            self._mcp_server.should_exit = True
            self._mcp_server = None
        ws = self.backend.workspace
        mcp = ws.mcp_config if ws else None
        enabled = self.mcp_allowed and (mcp.enabled if mcp else True)
        port = self.mcp_port_override or (mcp.port if mcp else 6891)
        if not enabled:
            self._mcp_label = "MCP off"
        elif not self._port_free(self.mcp_host, port):
            self._mcp_label = f"MCP off — :{port} in use"
            self.notify(
                f"MCP not started: port {port} is already in use (another limousine?). "
                "Continuing without it.",
                severity="warning", timeout=8,
            )
        else:
            self.run_worker(self._serve_mcp(port), exclusive=False, name="mcp")
            self._mcp_label = f"MCP :{port}"
        self._update_subtitle()

    @staticmethod
    def _port_free(host: str, port: int) -> bool:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            s.bind((host, port))
            return True
        except OSError:
            return False
        finally:
            s.close()

    def _update_subtitle(self) -> None:
        self.sub_title = "  ·  ".join(p for p in (self._mcp_label, self._secret_label) if p)

    def _on_secret_status(self, status) -> None:
        self._secret_label = _SECRET_LABEL.get(status, "")
        self._update_subtitle()

    async def _serve_mcp(self, port: int) -> None:
        ws = self.backend.workspace
        token = ws.mcp_config.token if ws and ws.mcp_config else None
        server = make_server(build_mcp(self.backend, port, host=self.mcp_host), token=token)
        self._mcp_server = server
        try:
            await server.serve()
        except asyncio.CancelledError:
            raise
        except (SystemExit, Exception) as exc:
            # uvicorn raises SystemExit(1) on a bind failure — a BaseException, so
            # `except Exception` missed it and it killed the whole app. Swallow it
            # and keep running without MCP.
            self._mcp_server = None
            self._mcp_label = f"MCP off — :{port} unavailable"
            self._update_subtitle()
            self.notify(f"MCP couldn't start on :{port} ({exc}). Continuing without it.",
                        severity="warning", timeout=8)

    def on_unmount(self) -> None:
        if self._mcp_server is not None:
            self._mcp_server.should_exit = True

    # ---- workspace open --------------------------------------------------

    def _prompt_open(self) -> None:
        def cb(path: str | None) -> None:
            if path:
                self.run_worker(self._open_workspace(path), exclusive=False)

        self.push_screen(screens.StartupScreen(self.backend), cb)

    async def _open_workspace(self, path: str) -> None:
        try:
            await self.backend.open_workspace(path)
        except Exception as e:
            self.notify(f"open failed: {e}", severity="error")
            self._prompt_open()
            return
        if self.backend.secret_store_status() == SecretStoreStatus.MISMATCH:
            self.notify("secret-store key mismatch — set the correct LIMOUSINE_AGE_KEY", severity="error")
        self.backend.add_recent(path)
        self._rebuild()
        self._refresh_mcp()

    # ---- helpers ---------------------------------------------------------

    def _state_of(self, sid: str | None) -> ServiceState | None:
        return self.backend.service_states().get(sid) if sid else None

    # ---- actions ---------------------------------------------------------

    def _focus_service(self, sid: str) -> None:
        """Point the header/selection at `sid` so an action is unambiguous."""
        self.selected = sid
        self._update_header()

    def action_start(self) -> None:
        sid = self._target_sid()
        if not sid:
            self.notify("Move the cursor to a service first")
            return
        self._focus_service(sid)
        st = self._state_of(sid)
        if st and st.status == ProcessStatus.orphaned:
            self.notify("Orphaned — kill it first (k)", severity="warning")
            return
        if st and st.status == ProcessStatus.running:
            self.notify("Already running")
            return
        info = self.backend.find_service(sid)
        if info is None:
            return
        if not info.service.commands:
            self.notify(f"{sid} has no commands")
            return

        # always show the picker (first pre-selected) — no mental load remembering
        # which services have a single command
        def on_pick(result) -> None:
            if not result:
                return
            if isinstance(result, tuple) and result[0] == "raw":
                self.backend.start_service(sid, raw=result[1])  # an edited command
            else:
                self.backend.start_service(sid, command=result)
            self._show_displayed(sid)

        self.push_screen(screens.CommandPicker(sid, info.service.commands), on_pick)

    def action_stop(self) -> None:
        sid = self._target_sid()
        st = self._state_of(sid)
        if not sid or not st or st.status != ProcessStatus.running:
            self.notify("Not running")
            return
        self._focus_service(sid)

        def on_confirm(yes: bool) -> None:
            if yes:
                self._stopping.add(sid)
                self._update_header()  # live "stopping…" cue
                self.run_worker(self._stop_service(sid), exclusive=False)

        self.push_screen(screens.ConfirmScreen(f"Stop {sid}?"), on_confirm)

    async def _stop_service(self, sid: str) -> None:
        stopped = await self.backend.stop_service(sid)
        self._stopping.discard(sid)
        if stopped:
            self.notify(f"✓ stopped {sid}", timeout=3)
        else:
            self.notify(f"⚠ {sid} still running after SIGKILL", severity="error")
        if sid == self.selected:
            self._update_header()

    def action_kill(self) -> None:
        sid = self._target_sid()
        st = self._state_of(sid)
        if sid and st and st.status == ProcessStatus.orphaned:
            self.backend.kill_orphan(sid)
            self.notify(f"Killed orphan {sid}")

    def action_input(self) -> None:
        inp = self.query_one("#stdin", Input)
        if inp.display:
            self._hide_input()
        else:
            inp.display = True
            inp.focus()
            self._auto_input = False

    def on_input_submitted(self, event: Input.Submitted) -> None:
        if event.input.id == "stdin":
            if self._displayed:  # input belongs to the service whose log/prompt is shown
                self.backend.send_input(self._displayed, event.value + "\n")
            self._hide_input()

    def action_env(self) -> None:
        sid = self._target_sid()
        if sid:
            self.push_screen(screens.EnvEditorScreen(self.backend, sid))

    def action_secrets(self) -> None:
        sid = self._target_sid()
        if sid:
            self.push_screen(screens.SecretsScreen(self.backend, sid))

    def action_git(self) -> None:
        def on_close(result) -> None:
            # the dashboard hands clone back to the main view so its output lands
            # in the copyable log pane
            if isinstance(result, tuple) and result and result[0] == "clone":
                self._start_clone(result[1])

        self.push_screen(screens.GitDashboard(self.backend, self._cursor_project()), on_close)

    def action_clone(self) -> None:
        name = self._cursor_project()
        if name:
            self._start_clone(name)

    def _start_clone(self, name: str) -> None:
        loaded = self.backend.projects.get(name)
        if loaded and loaded.exists_on_disk:
            self.notify(f"{name} is already cloned")
            return
        self.run_worker(self._clone(name), exclusive=False)

    async def _clone(self, name: str) -> None:
        loaded = self.backend.projects.get(name)
        url = loaded.git_repo_url if loaded else None
        log = self.query_one("#log", RichLog)
        self._displayed = None  # take over the log pane for clone output
        self._pending.clear()
        log.clear()
        self.query_one("#current", Static).update(Text.from_markup(f"▶ cloning [b]{name}[/]…"))
        if not url:
            log.write(Text.from_markup(f"[red]✗ {name}: no git-repo-url in the .wksp[/]"))
            self.notify(f"{name}: no git-repo-url", severity="error")
            return
        log.write(Text.from_markup(f"[bold cyan]$ git clone[/] {url}"))
        streamed = []

        def on_line(line: str) -> None:
            streamed.append(1)
            log.write(Text.from_ansi(line))

        try:
            res = await self.backend.clone(name, on_line=on_line)
        except Exception as e:
            log.write(Text.from_markup(f"[red]✗ clone error: {e}[/]"))
            self.notify("clone failed — see log (select + y to copy)", severity="error")
            return
        if res.success:
            log.write(Text.from_markup(f"[green]✓ cloned {name}[/]"))
            self.notify(f"✓ cloned {name}")  # success triggers a tree rebuild
        else:
            if not streamed:  # daemon path doesn't stream — dump the captured output
                full = "\n".join(p for p in (res.stdout, res.stderr) if p)
                if full:
                    log.write(Text.from_ansi(full))
            log.write(Text.from_markup(f"[red]✗ clone failed (exit {res.exit_code}) — select + y to copy[/]"))
            self.notify(f"clone failed (exit {res.exit_code}) — see log", severity="error")

    def action_menu(self) -> None:
        items = [
            ("agent_guide", "Agent guide"),
            ("save_log", "Save log to file"),
            ("kill", "Kill orphan"),
            ("reload_project", "Reload project"),
            ("reload", "Reload workspace"),
            ("open", "Open workspace…"),
            ("settings", "Settings"),
            ("clear", "Clear log"),
        ]

        def on_pick(action_id: str | None) -> None:
            if action_id:
                getattr(self, f"action_{action_id}")()

        self.push_screen(screens.ActionMenu(items), on_pick)

    def action_agent_guide(self) -> None:
        name = self._cursor_project()
        info = self.backend.project_info(name) if name else None
        if not info:
            return
        guide = info.get("agentGuide")
        if not guide:
            self.notify(f"{name}: no agent guide")
            return
        self.push_screen(screens.TextModal(f"agent guide — {name}", guide))

    def action_reload(self) -> None:
        self.run_worker(self._reload_workspace(), exclusive=False)

    async def _reload_workspace(self) -> None:
        try:
            diff = await self.backend.reload_workspace()
            self.notify(f"Reloaded: +{len(diff.added)} -{len(diff.removed)} ~{len(diff.changed)}")
        except BackendError as e:
            self.notify(f"Reload blocked: {', '.join(e.blockers)}", severity="error")

    def action_reload_project(self) -> None:
        name = self._cursor_project()
        if name:
            self.run_worker(self._reload_project(name), exclusive=False)

    async def _reload_project(self, name: str) -> None:
        try:
            await self.backend.reload_project(name)
            self.notify(f"Reloaded {name}")
        except BackendError as e:
            self.notify(f"Reload blocked: {', '.join(e.blockers)}", severity="error")

    def action_settings(self) -> None:
        def cb(saved: bool) -> None:
            if saved:
                self._refresh_mcp()
                self.notify("settings saved")

        self.push_screen(screens.SettingsScreen(self.backend), cb)

    def action_open(self) -> None:
        self._prompt_open()

    def action_clear(self) -> None:
        self.query_one("#log", RichLog).clear()

    # ---- capturing the log ----------------------------------------------

    def copy_text(self, text: str) -> None:
        """Copy to the system clipboard (native helper, OSC 52 fallback)."""
        if not text:
            return
        if self._system_clipboard_copy(text):
            self.notify(f"Copied {len(text)} chars to clipboard")
        else:
            self.copy_to_clipboard(text)  # OSC 52 fallback
            self.notify(f"Copied {len(text)} chars (terminal OSC 52)")

    def action_copy_selection(self) -> None:
        # Textual captures the mouse, so drag over the log to make a Textual
        # selection (or Shift+drag for the terminal's own), then copy it here.
        text = self.screen.get_selected_text()
        if not text:
            self.notify("Drag over the log to select text first", severity="warning")
            return
        self.copy_text(text)

    def action_save_log(self) -> None:
        sid = self._displayed
        lines = list(self.backend.buffer(sid)) if sid else []
        if not lines:
            self.notify("No log to save")
            return
        path = Path(tempfile.gettempdir()) / f"limousine-{sid.replace('/', '_')}.log"
        path.write_text("\n".join(lines) + "\n")
        self.notify(f"Saved {len(lines)} lines → {path}")

    @staticmethod
    def _system_clipboard_copy(text: str) -> bool:
        # OSC 52 is silently dropped by some terminals, so prefer a native
        # helper and fall back to OSC 52 only when none is available.
        cmds = {
            "wl-copy": ["wl-copy"],
            "xclip": ["xclip", "-selection", "clipboard"],
            "xsel": ["xsel", "--clipboard", "--input"],
            "pbcopy": ["pbcopy"],
        }
        order = (
            ["wl-copy", "xclip", "xsel", "pbcopy"]
            if os.environ.get("WAYLAND_DISPLAY")
            else ["xclip", "xsel", "wl-copy", "pbcopy"]
        )
        for name in order:
            if shutil.which(name) is None:
                continue
            try:
                subprocess.run(cmds[name], input=text.encode(), check=True)
                return True
            except (OSError, subprocess.CalledProcessError):
                continue
        return False
