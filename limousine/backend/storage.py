"""File I/O for workspaces, projects, global config, and PID files. Port of
lib/server/storage.dart. Parsing lives in core/models; this does the disk side
plus the numbered JSON-error snippet."""

from __future__ import annotations

import json
import os
from pathlib import Path

from ..core.models import GlobalConfig, Project, Workspace


def global_config_path() -> Path:
    return Path(os.environ["HOME"]) / ".limousine.json"


def pids_dir(workspace_path: str | Path) -> Path:
    return Path(workspace_path).parent / ".limousine" / "pids"


def load_global_config() -> GlobalConfig:
    p = global_config_path()
    if not p.exists():
        return GlobalConfig()
    return GlobalConfig.from_json(json.loads(p.read_text()))


def save_global_config(config: GlobalConfig) -> None:
    global_config_path().write_text(json.dumps(config.to_json(), indent=2))


def load_workspace(path: str | Path) -> Workspace:
    content = Path(path).read_text()
    try:
        return Workspace.from_json(json.loads(content))
    except json.JSONDecodeError as e:
        raise ValueError(f"Invalid JSON in {path}:\n{json_error_snippet(content, e.pos)}") from e


def save_workspace(path: str | Path, workspace: Workspace) -> None:
    Path(path).write_text(json.dumps(workspace.to_json(), indent=2))


def load_project(project_path: str | Path) -> Project | None:
    proj_file = Path(project_path) / "limousine.proj"
    if not proj_file.exists():
        return None
    content = proj_file.read_text()
    try:
        return Project.from_json(json.loads(content))
    except json.JSONDecodeError as e:
        raise ValueError(
            f"Invalid JSON in limousine.proj:\n{json_error_snippet(content, e.pos)}"
        ) from e


def save_project(project_path: str | Path, project: Project) -> None:
    (Path(project_path) / "limousine.proj").write_text(json.dumps(project.to_json(), indent=2))


def project_exists_on_disk(root_dir: str | Path, path_on_disk: str) -> bool:
    """Present = directory exists AND has an entry other than `.git`. An empty
    dir or a bare `.git/` from a failed clone counts as not present."""
    d = Path(resolve_path(root_dir, path_on_disk))
    if not d.is_dir():
        return False
    return any(child.name != ".git" for child in d.iterdir())


def resolve_path(root_dir: str | Path, path_on_disk: str) -> str:
    p = Path(path_on_disk)
    if p.is_absolute():
        return str(p)
    return os.path.normpath(os.path.join(str(root_dir), path_on_disk))


def _sanitize(service_id: str) -> str:
    return service_id.replace("/", "_")


def _unsanitize(filename: str) -> str:
    return filename.replace("_", "/")


def write_pid_file(workspace_path: str | Path, service_id: str, pid: int) -> None:
    d = pids_dir(workspace_path)
    d.mkdir(parents=True, exist_ok=True)
    (d / f"{_sanitize(service_id)}.pid").write_text(str(pid))


def delete_pid_file(workspace_path: str | Path, service_id: str) -> None:
    f = pids_dir(workspace_path) / f"{_sanitize(service_id)}.pid"
    if f.exists():
        f.unlink()


def load_all_pid_files(workspace_path: str | Path) -> dict[str, int]:
    d = pids_dir(workspace_path)
    if not d.is_dir():
        return {}
    result: dict[str, int] = {}
    for f in d.glob("*.pid"):
        try:
            result[_unsanitize(f.stem)] = int(f.read_text().strip())
        except (OSError, ValueError):
            continue
    return result


def json_error_snippet(content: str, offset: int | None) -> str:
    if offset is None:
        return content[:200] + "..." if len(content) > 200 else content
    lines = content.split("\n")
    char_count = 0
    error_line = 0
    for i, line in enumerate(lines):
        char_count += len(line) + 1
        if char_count > offset:
            error_line = i
            break
    start = max(0, error_line - 3)
    end = min(len(lines), error_line + 4)
    numbered = []
    for i in range(start, end):
        marker = ">>>" if i == error_line else "   "
        numbered.append(f"{marker} {i + 1} | {lines[i]}")
    return "\n".join(numbered)
