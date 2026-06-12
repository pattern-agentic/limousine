"""`limousine` entry point.

  limousine <wksp>                  open a workspace, run the TUI in-process
  limousine --daemon <wksp>         run a headless daemon (owns PTYs + MCP)
  limousine --connect <socket>      attach the TUI to a running daemon

Launch defaults can come from ~/.limousine.config (LIMOUSINE_WORKSPACE,
LIMOUSINE_CLONE_ROOT, LIMOUSINE_MCP_PORT, LIMOUSINE_LAN). The age key is prompted
for interactively at startup (no echo) unless LIMOUSINE_AGE_KEY is set or
LIMOUSINE_NO_KEY_PROMPT=1.
"""

from __future__ import annotations

import argparse
import asyncio
import os
import sys
from pathlib import Path

from . import launch
from .backend.backend import LocalBackend
from .backend.daemon import Daemon
from .backend.daemon_backend import DaemonBackend
from .backend.secret_store import SecretStoreStatus
from .tui.app import LimousineApp


def _default_socket(workspace_path: str) -> str:
    return str(Path(workspace_path).parent / ".limousine" / "daemon.sock")


def _fatal_on_mismatch(backend: LocalBackend) -> None:
    if backend.secret_store_status() == SecretStoreStatus.MISMATCH:
        print(
            "FATAL: secret-store stamp exists but the age key can't decrypt it.\n"
            "Set LIMOUSINE_AGE_KEY to the key this workspace was stamped with.",
            file=sys.stderr,
        )
        raise SystemExit(1)


def main() -> None:
    ap = argparse.ArgumentParser(prog="limousine", description="Local dev orchestrator (TUI)")
    ap.add_argument("workspace", nargs="?", help="path to a .wksp file")
    ap.add_argument("--daemon", action="store_true", help="run headless daemon (owns PTYs + MCP)")
    ap.add_argument("--connect", default=None, help="attach the TUI to a daemon at this unix socket")
    ap.add_argument("--socket", default=None, help="daemon socket path (default: <wksp>/.limousine/daemon.sock)")
    ap.add_argument("--mcp-port", type=int, default=None, help="override MCP port")
    ap.add_argument("--no-mcp", action="store_true", help="don't start the MCP server")
    ap.add_argument("--lan", action="store_true", help="bind MCP to 0.0.0.0 instead of 127.0.0.1")
    ap.add_argument("--clone-root", default=None, help="re-root relative project paths")
    ap.add_argument("--setup", action="store_true", help="interactive first-time setup (writes ~/.limousine.config)")
    ap.add_argument("--help-config", action="store_true", help="show config-file / env-var help and exit")
    args = ap.parse_args()

    try:
        _run(ap, args)
    except SystemExit:
        raise  # explicit, already-explained exits keep their code/message
    except KeyboardInterrupt:
        raise SystemExit(130)
    except Exception as e:
        print(f"\nlimousine failed: {_reason(e)}", file=sys.stderr)
        if os.environ.get("LIMOUSINE_DEBUG") == "1":
            raise
        print("  (set LIMOUSINE_DEBUG=1 for the full traceback)", file=sys.stderr)
        raise SystemExit(1)


def _reason(e: Exception) -> str:
    if isinstance(e, FileNotFoundError):
        return f"file not found: {e.filename or e}"
    if isinstance(e, ValueError):
        return str(e)  # storage produces a numbered JSON-error snippet
    return f"{type(e).__name__}: {e}"


def _run(ap, args) -> None:
    if args.help_config:
        print(launch.HELP_CONFIG)
        return
    if args.setup:
        launch.run_setup_wizard()
        return

    # A daemon client owns nothing locally — no config/key prompt; the daemon
    # holds the workspace + key. The secrets editor unlocks over the socket.
    if args.connect:
        LimousineApp(DaemonBackend(args.connect), mcp_allowed=False).run()
        return

    cfg, from_file = launch.read_config()
    workspace = args.workspace or cfg.get("LIMOUSINE_WORKSPACE")
    clone_root = args.clone_root or cfg.get("LIMOUSINE_CLONE_ROOT")
    mcp_port = args.mcp_port or (int(cfg["LIMOUSINE_MCP_PORT"]) if cfg.get("LIMOUSINE_MCP_PORT") else None)
    lan = args.lan or cfg.get("LIMOUSINE_LAN") in ("1", "true", "True")

    # First run: nothing to launch and no config yet → walk through setup, then
    # launch with whatever it saved. Cancelling drops to the in-app picker.
    if not workspace and not args.daemon and not launch.config_path().exists() and sys.stdin.isatty():
        saved = launch.run_setup_wizard()
        if saved:
            workspace = saved["workspace"] or workspace
            clone_root = saved["clone_root"] or clone_root
            mcp_port = saved["mcp_port"] or mcp_port
            lan = saved["lan"] or lan
            cfg, from_file = launch.read_config()

    mcp_host = "0.0.0.0" if lan else "127.0.0.1"

    if from_file:
        print(f"loaded from {launch.config_path()}:")
        for kv in from_file:
            print(f"  {kv}")
    if lan:
        print("⚠  --lan: MCP will bind 0.0.0.0. Set an mcp.token in the .wksp to gate it.", file=sys.stderr)
    print(f"secret store: {launch.prompt_age_key()}")

    backend = LocalBackend(override_clone_root=clone_root)
    path = None
    if workspace:
        path = str(Path(workspace).expanduser().resolve())
        asyncio.run(backend.open_workspace(path))
        _fatal_on_mismatch(backend)
        backend.add_recent(path)

    if args.daemon:
        if not path:
            ap.error("--daemon requires a workspace path")
        socket = args.socket or _default_socket(path)
        Path(socket).parent.mkdir(parents=True, exist_ok=True)
        print(f"limousine daemon serving on {socket} — owns PTYs + MCP. Ctrl-C to stop.")
        daemon = Daemon(backend, socket, mcp_allowed=not args.no_mcp, mcp_port_override=mcp_port, mcp_host=mcp_host)
        try:
            asyncio.run(daemon.serve())
        except KeyboardInterrupt:
            pass
        return

    LimousineApp(backend, mcp_allowed=not args.no_mcp, mcp_port_override=mcp_port, mcp_host=mcp_host).run()


if __name__ == "__main__":
    main()
