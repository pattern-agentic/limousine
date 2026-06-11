# Limousine: Dart/Flutter → Python TUI migration

Status of the rewrite from the Dart headless-server + Flutter-web + Docker stack
to a single Python Textual TUI. The risky unknowns were retired by the spike
(`../spike-tui/`); this is the real package.

## Architecture

```
limousine/
  core/        pure data, no I/O
    models.py    Workspace/ProjectRef/McpConfig, Project/Module/Service/ModuleConfig
    dtos.py      ServiceState, GitStatus, EnvComparison, ConfigDelta, …
  backend/     UI-free; the seam a daemon later sits behind
    backend.py     Backend ABC + LocalBackend  ← TUI and MCP program against this
    manager.py     ServiceManager — PTY lifecycle (ptyprocess + loop.add_reader)
    workspace_manager.py  open/reload/diff, all_services
    git.py · secret_store.py · env.py · storage.py · project_status.py
    mcp_server.py  FastMCP (streamable-HTTP) on the TUI's loop, driving Backend
  tui/         Textual UI (app.py, screens.py)
  cli.py       `limousine <workspace.wksp>`
```

The `Backend` ABC is the load-bearing seam: `LocalBackend` runs in-process
(ship now, tmux-owned); a future `DaemonBackend` (unix-socket client) implements
the same interface so the TUI and MCP layers don't change.

## Done (ported + tested — `uv run pytest`, 35 tests)

- [x] File schemas (`core/models.py`) — both module forms, agent-guide list, MCP defaults
- [x] DTOs (`core/dtos.py`) — plain dataclasses; no wire ser/deser (in-process)
- [x] `env.py`, `storage.py` — parse/serialize/compare, PID files, JSON-error snippet
- [x] `git.py` — clone (SSH hardening + partial-rescue), status, refresh, pull-ff (lock auto-stash); status tested against this repo
- [x] `secret_store.py` — sops/age, stamp verify, decrypt/encrypt (compiles; needs a live-key integration test)
- [x] `manager.py` — PTY lifecycle, CRLF-correct buffering, escalating stop, orphan re-adoption, waiting heuristic
- [x] `workspace_manager.py`, `project_status.py`
- [x] `backend.py` — `Backend` ABC + `LocalBackend`
- [x] `mcp_server.py` — list/start/stop/logs/project_info/git_status/git_fetch; HTTP end-to-end test proves it drives the shared backend
- [x] `tui/app.py` — **module-grouped Tree sidebar**, live logs, stdin+waiting, stop-confirm, kill-orphan, workspace reload
- [x] `cli.py` — open workspace (optional), fatal-exit on secret-store mismatch, launch

**Phase B — TUI breadth (done):**
- [x] Tree sidebar (project → module → service) with live state labels
- [x] Env editor screen (`get_env`/`save_env`)
- [x] Secrets editor screen with runtime age-key unlock (`unlock_secrets`)
- [x] Settings screen (MCP enable/port, git SSH key) → `update_settings`, with MCP restart-on-change
- [x] Startup screen: open by path + recents (`~/.limousine.json`); also drives the no-arg launch
- [x] Clone action + git-status modal (`g`/`c`)
- [x] Backend grew: `clone`, `get_env`/`save_env`, `secrets_keys`/`get_secrets`/`save_secrets`/`unlock_secrets`, `update_settings`, recents

**Phase C — robustness (done):**
- [x] `DaemonBackend` + unix-socket daemon (`daemon.py`, `daemon_backend.py`, `wire.py`): the daemon owns PTYs + runs MCP; services survive client disconnect/crash (tested). Hot-path queries answered from a push-fed local mirror; cold reads/writes are RPC; reflective method dispatch + generic `to_wire`.
- [x] MCP token auth — `Authorization: Bearer <token>` guard on the streamable-HTTP app (tested: rejected without, works with).
- [x] CLI: `limousine --daemon <wksp>` (headless) and `limousine --connect <socket>` (attach TUI).

## Remaining (labor, sequenced)

**Phase A + C leftovers (done):**
- [x] Live secret-store integration test — real age/sops: stamp create→verify→mismatch + encrypt/decrypt round-trip + runtime unlock (skipped if binaries absent)
- [x] Secret-store status callback (`SecretStore.on_status` → `Backend.on_secret_status`) → live `🔒/🔓 secrets` chip in the subtitle; pushed over the daemon socket too
- [x] Per-project reload action (`p`); `reload_project`/`reload_workspace` made consistently async (fixed a latent sync-call-of-async bug in the workspace-reload action)
- [x] Daemon live-restarts its MCP server when a settings change alters the MCP config (port/enable/token)

**Pulled in from the old `scripts/limousine` wrapper (done):**
- [x] Interactive age-key prompt at startup (no echo, never on disk); honors `LIMOUSINE_AGE_KEY` / `LIMOUSINE_NO_KEY_PROMPT` (`launch.py`)
- [x] `~/.limousine.config` launch defaults (WORKSPACE / CLONE_ROOT / MCP_PORT / LAN), env-wins precedence, never sourced
- [x] `--lan` → MCP binds 0.0.0.0; startup summary prints config loaded + secret-store status
- [x] `--setup` interactive wizard (writes `~/.limousine.config`, backs up existing) + `--help-config`
- [x] No-argument UX: configured workspace → opens it; true first run (no config) → runs `--setup` then launches; else the startup/recents picker (which also points at `--setup`)
- Most of the wrapper was Docker plumbing (bind-mounts, `--network host`, ssh-agent forwarding, `DOCKER_HOST`, uid mapping, IMAGE/PORT/MOUNT_ROOT) — **N/A**: the native TUI already has the host's env, sockets, and PATH directly.

**Parity pass (vs Flutter/Dart) — closed:**
- [x] **Choose which command to run** — services with >1 command (e.g. `mgmt-api/server` has ~20: start, create-db, upgrade-db, …) now show a command picker on `s`. One-command services start directly. (Backend/MCP already took a `command` arg.)
- [x] **Agent guide viewer** — `a` shows a project's `agent-guide` (also exposed to MCP via `get_project_info`)
- [x] **Git dashboard** (`g`) — a separate view listing every project with its full state (branch/sha, last commit, dirty code-vs-lock + file list, upstream ahead/behind, behind-main, **latest tag + commits-since-tag**, **last-fetched**, per-module env/secrets drift) and Fetch (`f`) / ff-only Pull (`p`) / Clone (`c`) per project. All of `git.dart`'s computed state is now surfaced (tags + fetched weren't before).
- [x] **Footer decluttered** — only the run/read loop shows (`s x i e v g m q`); the rest (open/reload/settings/kill-orphan/clear/agent-guide) moved into a Menu (`m`)
- [x] **Current-service header** on the right pane (`▶ <id>  ● running`) so an empty log is never ambiguous; updates instantly on cursor move
- [x] **Actions target the tree cursor** (no space/select needed) — `s`/`x`/`e`/`v`/… resolve the service under the cursor
- [x] **Debounced log swap** (bashbuild's 1s pattern) — header is instant, the log pane only reloads once the cursor settles, so scrolling the tree doesn't thrash

**Parity — known remaining gaps (intentional / minor):**
- `visible-tabs` in `limousine.proj` is ignored — the tree shows all services (Flutter used it to curate a tab bar). Could add a "visible only" toggle.
- One process per service id (matches Dart): auxiliary one-shot commands (create-db, validate-*) can't run while the service's `start` is running — stop it first, as the agent guides already instruct. Possible future improvement: run one-shots as separate ephemeral processes.
- `RichLog` renders ANSI + scrollback + a live partial line, but is not a full xterm (no cursor addressing / full-screen TUIs inside a service). Fine for log-streamers; documented tradeoff.
- Settings screen doesn't show version / workspace path (cosmetic).

**Optimistic project reload (done):**
- [x] Reload no longer requires stopping the project's services. It re-parses the definition (picking up new/changed commands); a running service whose definition was dropped stays alive as a "ghost" — still shown (tagged `(removed)`) and stoppable — and drops off the tree on the next reload once it exits. Built on the ServiceManager owning PTYs by id independent of the definition (`tracked_infos()`); `list_services` = definition ∪ running ghosts.

**Phase D — cutover**
- [ ] Parity pass against the Dart build on a real workspace
- [ ] `uv tool install` packaging; drop Docker image + Flutter toolchain
- [ ] Remove `lib/` (Dart), `docker/`, Flutter scaffolds; move `tui/` to repo root

## Run / test

```bash
cd tui
uv sync --extra dev
uv run pytest                       # 21 tests
uv run limousine demo/demo.wksp     # or a real .wksp (run inside tmux to detach)
```
