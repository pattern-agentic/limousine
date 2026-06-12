"""Env-file parsing, base env for spawned processes, and active/source drift.
Port of lib/server/env.dart.

Limousine deliberately does NOT load active-env / secrets files into spawned
services — each project's start command self-loads (dotenv ... sops exec-env).
This only builds the host env + PATH/TERM tweaks and compares files for the UI.
"""

from __future__ import annotations

import os
from pathlib import Path

from ..core.dtos import EnvComparison

_EXTRA_PATHS = [
    "/usr/local/bin",
    "/opt/homebrew/bin",
    "/opt/homebrew/sbin",
    "/home/linuxbrew/.linuxbrew/bin",
    "/snap/bin",
]


def parse_env_lines(lines: list[str]) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in lines:
        trimmed = line.strip()
        if not trimmed or trimmed.startswith("#"):
            continue
        eq = trimmed.find("=")
        if eq == -1:
            continue
        key = trimmed[:eq].strip()
        value = trimmed[eq + 1 :].strip()
        if (value.startswith('"') and value.endswith('"')) or (
            value.startswith("'") and value.endswith("'")
        ):
            value = value[1:-1]
        result[key] = value
    return result


def load_env_file(path: str | Path) -> dict[str, str]:
    p = Path(path)
    if not p.exists():
        return {}
    return parse_env_lines(p.read_text().splitlines())


def build_base_env() -> dict[str, str]:
    env = dict(os.environ)
    current = env.get("PATH", "")
    to_add = [p for p in _EXTRA_PATHS if p not in current]
    if to_add:
        env["PATH"] = os.pathsep.join([current, *to_add]) if current else os.pathsep.join(to_add)
    env["TERM"] = "xterm-256color"
    env["COLORTERM"] = "truecolor"
    env["FORCE_COLOR"] = "1"
    env["CLICOLOR_FORCE"] = "1"
    return env


def serialize(content: dict[str, str]) -> str:
    out = []
    for key, v in content.items():
        if "\n" in v or "\r" in v:
            raise ValueError(f"Value for {key} contains newline")
        needs_quoting = any(c in v for c in (" ", "#", "=", "'", '"'))
        quoted = '"' + v.replace('"', '\\"') + '"' if needs_quoting else v
        out.append(f"{key}={quoted}")
    return "\n".join(out) + ("\n" if out else "")


def write_env_file(path: str | Path, content: dict[str, str]) -> None:
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(serialize(content))


def compare_env_files(active_path: str | Path, source_path: str | Path) -> EnvComparison:
    return EnvComparison(
        active_exists=Path(active_path).exists(),
        source_exists=Path(source_path).exists(),
        active_content=load_env_file(active_path),
        source_content=load_env_file(source_path),
    )
