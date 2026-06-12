# limousine (Python TUI)

Local dev orchestrator as a single Textual TUI — the Python rewrite of the
Dart/Flutter/Docker build. Reads `.wksp` / `limousine.proj`, runs services in
PTYs, streams logs, and serves an MCP endpoint to agents.

```bash
uv sync --extra dev
uv run limousine demo/demo.wksp     # in-process; run inside tmux to detach + keep services alive
uv run pytest

# or daemon mode — services + MCP survive the TUI closing/crashing:
uv run limousine --daemon demo/demo.wksp           # headless: owns PTYs + MCP
uv run limousine --connect <wksp-dir>/.limousine/daemon.sock   # attach a TUI (reconnectable)
```

Sidebar is a tree (project → module → service); actions apply to the service
under the cursor. Footer keys: `s`/`r` start — shows a command picker where Enter
runs the command, `e` edits it before running (a one-off), `y` copies it ·
`x` stop (confirm → escalating) · `i` input · `e` env editor · `v` secrets
editor · `g` git dashboard · `y` copy selection · `m` menu · `q` quit. The
env/secrets editors show a diff — editable **active** file on the left, read-only
**template** on the right, `ctrl+t` to pull missing keys in from the template (a
clean checkout with only `env.example` is one keystroke from a filled `.env.dev`),
`ctrl+s` to save. The log pane sticks to the bottom only while you're already
there — scroll up (mouse wheel / `pageup`) to read history without being yanked
down by new output; `pagedown`/`end` catch back up. `-` inserts a timestamped
separator line into the current log. The log
pane supports mouse text selection — drag to select, `y` to copy (native
clipboard, OSC 52 fallback). `w` (or the menu) dumps the full log to a tempfile.
The menu (`m`) holds agent guide, save log, kill orphan, reload project, reload
workspace (`shift+R`), open workspace, settings, clear log. Clone/fetch/pull live in the git dashboard. Launch with no
path to get the startup/recents screen. The subtitle shows MCP + secret-store
status (`🔒/🔓 secrets`).

MCP auto-starts on the workspace's configured port (default `:6891`) unless
`--no-mcp`; `--lan` binds it to `0.0.0.0` (gate with an `mcp.token`).

**Age key:** prompted for at startup (no echo, never written to disk) unless
`LIMOUSINE_AGE_KEY` is set or `LIMOUSINE_NO_KEY_PROMPT=1` (CI). Empty input
leaves the secret store locked; unlock later from the secrets editor (`v`).

**Launch defaults** come from `~/.limousine.config` (shell `KEY=VALUE`, never
sourced) — `LIMOUSINE_WORKSPACE`, `LIMOUSINE_CLONE_ROOT`, `LIMOUSINE_MCP_PORT`,
`LIMOUSINE_LAN`. Precedence: CLI flag > shell env > config file > default.
Recent workspaces live separately in `~/.limousine.json`. `limousine
--help-config` lists every key.

**No arguments:** with a configured `LIMOUSINE_WORKSPACE`, `limousine` just opens
it. On a true first run (no config), it walks you through `--setup` (which writes
`~/.limousine.config`), then launches. Otherwise it opens the startup/recents
screen. Run `limousine --setup` any time to re-configure.

See `MIGRATION.md` for architecture and the remaining-work plan.
