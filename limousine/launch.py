"""Startup glue ported from the old `scripts/limousine` wrapper: an interactive
age-key prompt (no echo, never on disk) and `~/.limousine.config` defaults.

The age key is deliberately never taken as a CLI flag — that would land it in
shell history. It comes from the `LIMOUSINE_AGE_KEY` env var or this prompt.
"""

from __future__ import annotations

import getpass
import os
import sys
import time
from pathlib import Path

_KEYS = ("LIMOUSINE_WORKSPACE", "LIMOUSINE_CLONE_ROOT", "LIMOUSINE_MCP_PORT", "LIMOUSINE_LAN")

HELP_CONFIG = """limousine — ~/.limousine.config + environment overrides

Shell-style KEY=VALUE per line in ~/.limousine.config (never sourced, so a
fat-fingered value can't run code), or set as a regular env var. Keys:

  LIMOUSINE_WORKSPACE    default workspace path (positional arg overrides)
  LIMOUSINE_CLONE_ROOT   default for --clone-root
  LIMOUSINE_MCP_PORT     default MCP port (built-in default 6891)
  LIMOUSINE_LAN          set to 1 to bind MCP to 0.0.0.0

Env-only (not in the config file):
  LIMOUSINE_AGE_KEY        age private key; if set, skips the startup prompt
  LIMOUSINE_NO_KEY_PROMPT  set to 1 to skip the age-key prompt (CI/automation)

Precedence (highest wins):
  CLI flag → env var → ~/.limousine.config → built-in default.

Recent workspaces are stored separately in ~/.limousine.json.

  limousine --setup        interactive wizard that writes ~/.limousine.config
"""


def config_path() -> Path:
    return Path.home() / ".limousine.config"


def read_config() -> tuple[dict[str, str], list[str]]:
    """Resolve launch defaults. Precedence: shell env > ~/.limousine.config.
    Returns (resolved values, keys that came from the file) — plain KEY=VALUE
    parsing, never sourced, so a fat-fingered value can't execute code."""
    path = config_path()
    file_vals: dict[str, str] = {}
    if path.exists():
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, val = line.split("=", 1)
            key, val = key.strip(), val.strip().strip('"').strip("'")
            if key in _KEYS and val:
                file_vals[key] = val

    resolved: dict[str, str] = {}
    from_file: list[str] = []
    for key in _KEYS:
        if os.environ.get(key):
            resolved[key] = os.environ[key]  # shell env wins
        elif key in file_vals:
            resolved[key] = file_vals[key]
            from_file.append(f"{key}={file_vals[key]}")
    return resolved, from_file


def _resolve(p: str) -> str:
    return str(Path(p).expanduser().resolve()) if p else p


def run_setup_wizard() -> dict | None:
    """Interactive wizard that writes ~/.limousine.config. Returns the saved
    values (so a first-run launch can use them immediately), or None if the user
    cancelled / it's non-interactive."""
    if not sys.stdin.isatty():
        print("--setup needs an interactive terminal.", file=sys.stderr)
        return None
    path = config_path()
    existing, _ = read_config()

    try:
        if path.exists():
            print(f"⚠ {path} already exists; the wizard overwrites it (a backup is kept).")
            if input("Continue? [y/N] ").strip().lower() not in ("y", "yes"):
                print("Cancelled.")
                return None

        print("\nlimousine setup — press Enter to accept the [default].\n")

        def ask(prompt: str, default: str = "") -> str:
            suffix = f" [{default}]" if default else ""
            return input(f"{prompt}{suffix}: ").strip() or default

        workspace = _resolve(ask("Workspace file (.wksp)", existing.get("LIMOUSINE_WORKSPACE", "")))
        clone_root = _resolve(ask("Clone root for project repos", existing.get("LIMOUSINE_CLONE_ROOT", "")))
        mcp_port = ask("MCP port", existing.get("LIMOUSINE_MCP_PORT", "6891"))
        lan = ask("Bind MCP to LAN / 0.0.0.0? [y/N]").lower() in ("y", "yes")
    except (KeyboardInterrupt, EOFError):
        print("\nCancelled.")
        return None

    if path.exists():
        backup = path.with_name(path.name + f".{time.strftime('%Y-%m-%dT%H-%M-%S')}.bak")
        backup.write_text(path.read_text())
        print(f"Backed up existing config to {backup}")

    lines = ["# Written by `limousine --setup`. Edit by hand or re-run --setup.",
             "# See `limousine --help-config` for all keys."]
    if workspace:
        lines.append(f"LIMOUSINE_WORKSPACE={workspace}")
    if clone_root:
        lines.append(f"LIMOUSINE_CLONE_ROOT={clone_root}")
    if mcp_port:
        lines.append(f"LIMOUSINE_MCP_PORT={mcp_port}")
    if lan:
        lines.append("LIMOUSINE_LAN=1")
    path.write_text("\n".join(lines) + "\n")
    path.chmod(0o600)
    print(f"\n✓ Saved {path}\n")
    return {
        "workspace": workspace or None,
        "clone_root": clone_root or None,
        "mcp_port": int(mcp_port) if mcp_port else None,
        "lan": lan,
    }


def prompt_age_key() -> str:
    """Read the age key interactively (no echo) and stash it in the env so the
    secret store picks it up. Returns a short status for the launch summary.

    Honors `LIMOUSINE_AGE_KEY` (already set) and `LIMOUSINE_NO_KEY_PROMPT=1`
    (CI/automation: skip the prompt). Non-tty with no key → skip, store locked.

    Enter on an empty prompt (or Ctrl+D) skips, leaving the store locked.
    Ctrl+C aborts startup entirely (raises SystemExit), so it never silently
    falls through to a locked TUI.
    """
    if os.environ.get("LIMOUSINE_AGE_KEY"):
        return "from LIMOUSINE_AGE_KEY"
    if os.environ.get("LIMOUSINE_NO_KEY_PROMPT") == "1" or not sys.stdin.isatty():
        return "locked (no key)"
    try:
        key = getpass.getpass(
            "Age private key (paste AGE-SECRET-KEY-…, no echo; Enter to skip, Ctrl+C to abort): "
        ).strip()
    except EOFError:
        key = ""  # Ctrl+D / no input → skip, store stays locked
    except KeyboardInterrupt:
        print("\nAborted.", file=sys.stderr)
        raise SystemExit(130)
    if key:
        os.environ["LIMOUSINE_AGE_KEY"] = key
        return "key supplied"
    return "locked (no key)"
