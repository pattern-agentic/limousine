# Limousine

Local dev orchestrator — a **Python Textual TUI**. Reads `.wksp` and
`limousine.proj` files; starts/stops services in PTYs, streams their output to a
terminal pane, and serves an MCP endpoint to agents. Single process (run in tmux
to detach), or a headless daemon the TUI attaches to. Replaced an earlier
Dart-server + Flutter-web build (see `MIGRATION.md` for the history).

## Layout

```
limousine/
  core/        pure data, no I/O
    models.py    Workspace/ProjectRef/McpConfig, Project/Module/Service/ModuleConfig
    dtos.py      ServiceState, GitStatus, EnvComparison, ConfigDelta, …
  backend/     UI-free; the seam a daemon sits behind
    backend.py     Backend ABC + LocalBackend  ← the TUI and MCP program against this
    manager.py     ServiceManager — PTY lifecycle (ptyprocess + loop.add_reader)
    workspace_manager.py  open/reload/diff, all_services
    git.py · secret_store.py · env.py · storage.py · project_status.py
    mcp_server.py  FastMCP (streamable-HTTP) on the TUI's loop, driving Backend
    daemon.py · daemon_backend.py · wire.py   (the unix-socket daemon + client)
  tui/         Textual UI (app.py, screens.py, widgets.py)
  launch.py    age-key prompt + ~/.limousine.config
  cli.py       `limousine <workspace.wksp>`
tests/         pytest (asyncio mode)
demo/          a self-contained demo workspace
```

## The Backend seam

`Backend` (ABC in `backend/backend.py`) is the interface the TUI and the MCP
server use. `LocalBackend` runs everything in-process. `DaemonBackend` is a
unix-socket client to a long-lived daemon (`daemon.py`) that owns the PTYs +
runs MCP — so services survive a TUI crash and MCP runs headless. Nothing above
the seam changes between the two. Hot-path queries (states, buffers, tail) are
answered from a push-fed mirror; cold reads/writes are RPCs.

## Run / test

```bash
uv sync --extra dev
uv run limousine                     # first run → setup wizard; else opens configured workspace
uv run limousine demo/demo.wksp      # run inside tmux to detach + keep services alive
uv run limousine --daemon demo/demo.wksp
uv run limousine --connect <wksp-dir>/.limousine/daemon.sock
uv run pytest
```

## Conventions

- **No env/secret injection.** Each project's start command self-loads env via
  `dotenv -f env.dev.meta run -- sops exec-env secrets.env '<cmd>'`. Limousine
  only sets `Platform.environment` + PATH/TERM and forwards `SOPS_AGE_KEY` so the
  command's own sops can decrypt. The `config` block in `limousine.proj` is
  metadata for the editor diff view, not loaded at start time.
- **Secret store = sops + age, shelled out.** Per-dev age key, pasted at startup
  (`launch.prompt_age_key`), held in memory only. A sops-encrypted stamp under
  `<wksp>/.limousine/` binds the key to the workspace; wrong key is fatal.
- **PTY** via `ptyprocess` + `loop.add_reader` (no FFI). `manager._clean_line`
  must `rstrip("\r")` (nested TTYs like `docker run -t` emit `\r\r\n`).
- **`core/` is pure** (no I/O); the backend modules shell out to `git`/`sops`/`age`.
- **MCP runs on the TUI's event loop** (uvicorn in-loop), so its tools hit the
  same in-process backend; a port conflict is caught, not fatal.
- **Tests**: prefer polling for service output over fixed sleeps (login-shell
  startup is slow/variable); don't use async yield-fixtures that spawn PTYs
  (they collide with uvicorn teardown).

## Not part of the project

- `limousine-vscode/` — a separate VS Code companion, unrelated to the TUI.
