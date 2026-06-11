"""Pilot-driven tests of the Textual app: tree building, live state, screens."""

import asyncio
import json
import tempfile
from pathlib import Path

from textual.widgets import Tree

from limousine.backend.backend import LocalBackend
from limousine.tui import screens
from limousine.tui.app import LimousineApp

DEMO = str(Path(__file__).parent.parent / "demo" / "demo.wksp")


async def _wait_for(pred, tries: int = 80, delay: float = 0.1) -> bool:
    """Poll a predicate instead of sleeping a fixed time — robust under load /
    slow login-shell startup."""
    for _ in range(tries):
        if pred():
            return True
        await asyncio.sleep(delay)
    return pred()


async def test_tree_state_and_screens():
    backend = LocalBackend()
    await backend.open_workspace(DEMO)
    app = LimousineApp(backend, mcp_allowed=False)  # skip MCP for a fast test
    async with app.run_test(size=(140, 40)) as pilot:
        await pilot.pause()
        app.query_one("#sidebar", Tree)
        assert set(app._svc_nodes) == {"demo/ticker", "demo/prompt"}
        assert app.selected in app._svc_nodes

        # starting always opens the picker; pick the command
        sid = app.selected
        app.action_start()
        await pilot.pause()
        assert isinstance(app.screen, screens.CommandPicker)
        app.screen.dismiss("start")
        await asyncio.sleep(1.0)
        await pilot.pause()
        assert backend.service_states()[sid].status.value == "running"
        await backend.stop_service(sid)

        # env editor opens and closes
        app.action_env()
        await pilot.pause()
        assert isinstance(app.screen, screens.EnvEditorScreen)
        app.screen.dismiss(False)
        await pilot.pause()

        # settings opens and closes
        app.action_settings()
        await pilot.pause()
        assert isinstance(app.screen, screens.SettingsScreen)
        app.screen.dismiss(False)
        await pilot.pause()

        # secrets editor opens (locked store → shows unlock prompt, no crash)
        app.action_secrets()
        await pilot.pause()
        assert isinstance(app.screen, screens.SecretsScreen)
        app.screen.dismiss(False)
        await pilot.pause()


async def test_command_picker_runs_chosen_command():
    tmp = Path(tempfile.mkdtemp())
    proj = tmp / "proj"
    proj.mkdir()
    proj.joinpath("limousine.proj").write_text(
        json.dumps({"modules": {"m": {"services": {"svc": {"commands": {
            "start": "echo AAA; sleep 5",
            "other": "echo BBB; sleep 5",
        }}}}}})
    )
    wksp = tmp / "w.wksp"
    wksp.write_text(json.dumps({"name": "W", "projects": {"p": {"path-on-disk": "proj"}}}))
    backend = LocalBackend()
    await backend.open_workspace(str(wksp))
    app = LimousineApp(backend, mcp_allowed=False)
    async with app.run_test(size=(140, 40)) as pilot:
        await pilot.pause()
        assert app.selected == "m/svc"
        app.action_start()  # multi-command → picker
        await pilot.pause()
        assert isinstance(app.screen, screens.CommandPicker)
        from textual.widgets import OptionList
        assert app.screen.query_one("#cmds", OptionList).highlighted == 0  # first pre-selected
        app.screen.dismiss("other")  # pick the non-default command
        assert await _wait_for(lambda: any("BBB" in l for l in backend.buffer("m/svc")))
        await backend.stop_service("m/svc")


async def test_agent_guide_modal():
    tmp = Path(tempfile.mkdtemp())
    proj = tmp / "proj"
    proj.mkdir()
    proj.joinpath("limousine.proj").write_text(
        json.dumps({"agent-guide": ["Line one.", "Line two."],
                    "modules": {"m": {"services": {"s": {"commands": {"start": "true"}}}}}})
    )
    wksp = tmp / "w.wksp"
    wksp.write_text(json.dumps({"name": "W", "projects": {"p": {"path-on-disk": "proj"}}}))
    backend = LocalBackend()
    await backend.open_workspace(str(wksp))
    app = LimousineApp(backend, mcp_allowed=False)
    async with app.run_test(size=(140, 40)) as pilot:
        await pilot.pause()
        assert app.current_project == "p"
        app.action_agent_guide()
        await pilot.pause()
        assert isinstance(app.screen, screens.TextModal)
        assert "Line one." in app.screen._body and "Line two." in app.screen._body


def test_format_git_status():
    from limousine.core.dtos import DirtyFile, GitStatus
    from limousine.tui.screens import format_git_status

    s = GitStatus(
        project="x", exists=True, branch="main", short_sha="abc123",
        dirty_files=[DirtyFile("a.py", " M", False), DirtyFile("uv.lock", " M", True)],
        upstream="origin/main", behind_upstream=2, ahead_upstream=1,
    )
    out = format_git_status(s)
    assert "main @ abc123" in out
    assert "2 (1 code, 1 lock)" in out
    assert "origin/main" in out
    # labels are right-aligned to a fixed column
    assert "\n   dirty:" in out or out.startswith("   branch:")


async def test_header_instant_log_debounced_and_cursor_targeting():
    backend = LocalBackend()
    await backend.open_workspace(DEMO)
    app = LimousineApp(backend, mcp_allowed=False)
    app._display_debounce = 1.0
    async with app.run_test(size=(140, 40)) as pilot:
        await pilot.pause()
        assert app.selected == "demo/ticker"
        assert app._displayed == "demo/ticker"  # shown immediately on build

        # navigate the cursor onto the other service
        for _ in range(6):
            if app._cursor_sid() == "demo/prompt":
                break
            await pilot.press("down")
        await pilot.pause()
        assert app.selected == "demo/prompt"      # header/selection update instantly
        assert app._displayed is None             # pane cleared immediately as a switch cue
        await asyncio.sleep(1.2)
        await pilot.pause()
        assert app._displayed == "demo/prompt"     # new log loaded once the cursor settled

        # an action targets the cursor service, no space needed
        app.action_start()
        await pilot.pause()
        assert isinstance(app.screen, screens.CommandPicker)
        app.screen.dismiss("start")
        await asyncio.sleep(0.6)
        assert backend.service_states()["demo/prompt"].status.value == "running"
        await backend.stop_service("demo/prompt")


async def test_git_dashboard_and_menu():
    backend = LocalBackend()
    await backend.open_workspace(DEMO)
    app = LimousineApp(backend, mcp_allowed=False)
    async with app.run_test(size=(140, 40)) as pilot:
        await pilot.pause()
        app.action_git()
        await pilot.pause()
        assert isinstance(app.screen, screens.GitDashboard)
        await asyncio.sleep(0.5)  # let it load status for the (non-repo) demo project
        await pilot.pause()
        assert "demo" in app.screen._status
        app.screen.dismiss(None)
        await pilot.pause()

        # menu opens, dispatches the chosen action
        app.action_menu()
        await pilot.pause()
        assert isinstance(app.screen, screens.ActionMenu)
        app.screen.dismiss("clear")  # → action_clear (harmless)
        await pilot.pause()


async def test_r_starts_shiftR_reloads():
    backend = LocalBackend()
    await backend.open_workspace(DEMO)
    app = LimousineApp(backend, mcp_allowed=False)
    async with app.run_test(size=(140, 40)) as pilot:
        await pilot.pause()
        await pilot.press("r")  # synonym for start → command picker
        await pilot.pause()
        assert isinstance(app.screen, screens.CommandPicker)
        app.screen.dismiss(None)
        await pilot.pause()
        await pilot.press("R")  # shift+R → reload workspace, NOT the picker
        await pilot.pause()
        assert not isinstance(app.screen, screens.CommandPicker)


def test_footer_is_decluttered():
    # the noisy keys are hidden from the footer but still bound
    from limousine.tui.app import LimousineApp

    shown = {b.key for b in LimousineApp.BINDINGS if b.show}
    hidden = {b.key for b in LimousineApp.BINDINGS if not b.show}
    assert shown == {"s", "x", "i", "e", "v", "g", "y", "m", "q"}
    assert {"k", "o", "r", "p", "comma", "ctrl+l", "a", "w"} <= hidden


async def test_save_log_writes_buffer(tmp_path, monkeypatch):
    monkeypatch.setattr("tempfile.gettempdir", lambda: str(tmp_path))
    backend = LocalBackend()
    await backend.open_workspace(DEMO)
    app = LimousineApp(backend, mcp_allowed=False)
    async with app.run_test(size=(140, 40)) as pilot:
        await pilot.pause()
        app.action_start()
        await pilot.pause()
        app.screen.dismiss("start")  # demo/ticker
        assert await _wait_for(lambda: any("tick" in l for l in backend.buffer("demo/ticker")))
        await pilot.pause()
        app.action_save_log()
        await pilot.pause()
        f = tmp_path / "limousine-demo_ticker.log"
        assert f.exists()
        assert any("tick" in line for line in f.read_text().splitlines())
        await backend.stop_service("demo/ticker")


def test_stop_hint_messages():
    from limousine.core.dtos import ServiceState, StopSignal

    f = LimousineApp._stop_hint
    assert "SIGINT" in f(ServiceState("x", next_signal=StopSignal.sigterm))
    assert "SIGTERM" in f(ServiceState("x", next_signal=StopSignal.sigkill))
    assert "stopping" in f(ServiceState("x", next_signal=StopSignal.sigint)).lower()


async def test_stop_shows_progress_and_completes():
    from textual.widgets import Static

    backend = LocalBackend()
    await backend.open_workspace(DEMO)
    app = LimousineApp(backend, mcp_allowed=False)
    async with app.run_test(size=(140, 40)) as pilot:
        await pilot.pause()
        app.action_start()
        await pilot.pause()
        app.screen.dismiss("start")  # demo/ticker
        assert await _wait_for(lambda: any("tick" in l for l in backend.buffer("demo/ticker")))
        app.selected = "demo/ticker"

        # the header shows a live "stopping…" cue while a stop is in flight
        app._stopping.add("demo/ticker")
        app._update_header()
        assert "stopping" in app.query_one("#current", Static).render().plain
        app._stopping.discard("demo/ticker")

        # a real stop completes and clears the tracking
        app.action_stop()
        await pilot.pause()
        app.screen.dismiss(True)  # confirm
        assert await _wait_for(lambda: backend.service_states()["demo/ticker"].status.value == "stopped")
        assert await _wait_for(lambda: "demo/ticker" not in app._stopping)


async def test_sidebar_autosizes_to_widest_service():
    from textual.widgets import Tree

    async def _width(svc_names):
        tmp = Path(tempfile.mkdtemp())
        proj = tmp / "proj"
        proj.mkdir()
        proj.joinpath("limousine.proj").write_text(
            json.dumps({"modules": {"demo": {"services": {n: {"commands": {"start": "true"}} for n in svc_names}}}})
        )
        wksp = tmp / "w.wksp"
        wksp.write_text(json.dumps({"name": "W", "projects": {"demo": {"path-on-disk": "proj"}}}))
        backend = LocalBackend()
        await backend.open_workspace(str(wksp))
        app = LimousineApp(backend, mcp_allowed=False)
        async with app.run_test(size=(160, 40)) as pilot:
            await pilot.pause()
            await pilot.pause()
            return app.query_one("#sidebar", Tree).size.width

    assert await _width(["create-supervisor-agent-service"]) > await _width(["web", "db"])


async def test_clone_from_main_view_streams_to_log(tmp_path):
    from textual.widgets import RichLog

    (tmp_path / "w.wksp").write_text(
        json.dumps({"name": "W", "projects": {
            "myproj": {"path-on-disk": "myproj",
                       "optional-git-repo-url": "file:///definitely-nonexistent-repo-xyz.git"}}})
    )
    backend = LocalBackend()
    await backend.open_workspace(str(tmp_path / "w.wksp"))
    app = LimousineApp(backend, mcp_allowed=False)
    async with app.run_test(size=(140, 40)) as pilot:
        await pilot.pause()
        app.current_project = "myproj"
        app.action_clone()  # 'c' in the main view
        log = app.query_one("#log", RichLog)
        assert await _wait_for(lambda: any("clone failed" in s.text for s in log.lines))
        assert app._displayed is None  # log taken over for clone output
        # the FULL error is in the (copyable) log, not a truncated flash
        assert any("not appear to be a git repository" in s.text for s in log.lines)


async def test_mcp_port_conflict_does_not_crash():
    import socket

    blocker = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    blocker.bind(("127.0.0.1", 0))
    blocker.listen()
    port = blocker.getsockname()[1]
    try:
        tmp = Path(tempfile.mkdtemp())
        (tmp / "w.wksp").write_text(json.dumps({"name": "W", "projects": {}}))
        backend = LocalBackend()
        await backend.open_workspace(str(tmp / "w.wksp"))
        app = LimousineApp(backend, mcp_allowed=True, mcp_port_override=port)
        async with app.run_test(size=(120, 40)) as pilot:
            await pilot.pause()
            await pilot.pause()
            assert app.is_running          # the bind conflict must NOT kill the app
            assert app._mcp_server is None  # MCP skipped
            assert "in use" in app._mcp_label
    finally:
        blocker.close()


async def test_env_editor_diff_and_add_from_template(tmp_path):
    from textual.widgets import Static, TextArea

    proj = tmp_path / "proj"
    proj.mkdir()
    proj.joinpath("limousine.proj").write_text(json.dumps({"modules": {"m": {
        "services": {"svc": {"commands": {"start": "true"}}},
        "config": {"active-env-file": ".env.dev", "source-env-file": "env.example"}}}}))
    proj.joinpath("env.example").write_text("API_URL=http://localhost\nDB_NAME=example\n")  # clean checkout: no .env.dev
    (tmp_path / "w.wksp").write_text(json.dumps({"name": "W", "projects": {"p": {"path-on-disk": "proj"}}}))
    backend = LocalBackend()
    await backend.open_workspace(str(tmp_path / "w.wksp"))
    app = LimousineApp(backend, mcp_allowed=False)
    async with app.run_test(size=(160, 45)) as pilot:
        await pilot.pause()
        app.selected = "m/svc"
        app.action_env()
        await pilot.pause()
        assert await _wait_for(lambda: "DB_NAME" in app.screen.query_one("#template", TextArea).text)
        scr = app.screen
        assert scr.query_one("#active", TextArea).text.strip() == ""              # nothing yet
        assert "missing: API_URL, DB_NAME" in scr.query_one("#status", Static).render().plain
        scr.action_add_missing()                                                  # pull template keys in
        await pilot.pause()
        assert "API_URL" in scr.query_one("#active", TextArea).text
        scr.action_save()
        await pilot.pause()
        assert (proj / ".env.dev").exists()
        assert "DB_NAME=example" in (proj / ".env.dev").read_text()


async def test_secrets_editor_shows_template_when_locked(tmp_path, monkeypatch):
    from textual.widgets import Input, TextArea

    monkeypatch.delenv("LIMOUSINE_AGE_KEY", raising=False)
    proj = tmp_path / "proj"
    proj.mkdir()
    proj.joinpath("limousine.proj").write_text(json.dumps({"modules": {"m": {
        "services": {"svc": {"commands": {"start": "true"}}},
        "config": {"active-secrets-env-file": "secrets.env", "source-secrets-file": "secrets.env.example"}}}}))
    proj.joinpath("secrets.env.example").write_text("TOKEN=changeme\nAPI_KEY=xxx\n")
    (tmp_path / "w.wksp").write_text(json.dumps({"name": "W", "projects": {"p": {"path-on-disk": "proj"}}}))
    backend = LocalBackend()
    await backend.open_workspace(str(tmp_path / "w.wksp"))
    app = LimousineApp(backend, mcp_allowed=False)
    async with app.run_test(size=(160, 45)) as pilot:
        await pilot.pause()
        app.selected = "m/svc"
        app.action_secrets()
        await pilot.pause()
        assert await _wait_for(lambda: "TOKEN" in app.screen.query_one("#template", TextArea).text)
        scr = app.screen
        assert scr.query_one("#unlock", Input).display is True       # prompts for the key
        assert "changeme" in scr.query_one("#template", TextArea).text  # template visible while locked


async def test_reload_shows_running_ghost_in_tree(tmp_path):
    proj = tmp_path / "proj"
    proj.mkdir()
    pf = proj / "limousine.proj"
    pf.write_text(json.dumps({"modules": {"m": {"services": {
        "keep": {"commands": {"start": "sleep 30"}},
        "gone": {"commands": {"start": "sleep 30"}}}}}}))
    (tmp_path / "w.wksp").write_text(json.dumps({"name": "W", "projects": {"p": {"path-on-disk": "proj"}}}))
    backend = LocalBackend()
    await backend.open_workspace(str(tmp_path / "w.wksp"))
    app = LimousineApp(backend, mcp_allowed=False)
    async with app.run_test(size=(140, 40)) as pilot:
        await pilot.pause()
        backend.start_service("m/gone")
        assert await _wait_for(lambda: backend.service_states().get("m/gone")
                               and backend.service_states()["m/gone"].status.value == "running")
        pf.write_text(json.dumps({"modules": {"m": {"services": {"keep": {"commands": {"start": "sleep 30"}}}}}}))
        await backend.reload_project("p")  # triggers a rebuild via on_workspace_change
        assert await _wait_for(lambda: "m/gone" in app._stale_ids)
        assert "m/gone" in app._svc_nodes  # ghost still in the tree (stoppable)
        await backend.stop_service("m/gone")


async def test_command_picker_copy_and_edit(tmp_path):
    from textual.widgets import Input

    proj = tmp_path / "proj"
    proj.mkdir()
    proj.joinpath("limousine.proj").write_text(
        json.dumps({"modules": {"m": {"services": {"svc": {"commands": {
            "start": "echo ORIG; sleep 30", "other": "echo OTHER; sleep 30"}}}}}})
    )
    (tmp_path / "w.wksp").write_text(json.dumps({"name": "W", "projects": {"p": {"path-on-disk": "proj"}}}))
    backend = LocalBackend()
    await backend.open_workspace(str(tmp_path / "w.wksp"))
    app = LimousineApp(backend, mcp_allowed=False)
    async with app.run_test(size=(140, 40)) as pilot:
        await pilot.pause()
        app.selected = "m/svc"
        app.action_start()
        await pilot.pause()
        scr = app.screen
        assert isinstance(scr, screens.CommandPicker)

        # copy the highlighted (first) command
        copied = []
        app.copy_text = lambda t: copied.append(t)
        scr.action_copy()
        assert copied == ["echo ORIG; sleep 30"]

        # edit it and run the modified one-off command
        scr.action_edit()
        await pilot.pause()
        scr.query_one("#edit", Input).value = "echo EDITED; sleep 30"
        await pilot.press("enter")
        await pilot.pause()
        assert await _wait_for(lambda: any("EDITED" in l for l in backend.buffer("m/svc")))
        await backend.stop_service("m/svc")


async def test_startup_screen_when_no_workspace():
    backend = LocalBackend()  # never opened
    app = LimousineApp(backend, mcp_allowed=False)
    async with app.run_test(size=(120, 40)) as pilot:
        await pilot.pause()
        assert isinstance(app.screen, screens.StartupScreen)
