"""Unix-socket framing + DTO (de)serialization for the daemon boundary.

`to_wire` generically encodes any dataclass/enum tree to JSON-safe data, so the
daemon dispatches Backend methods reflectively and wraps results with one call.
The `*_from_wire` decoders reconstruct typed DTOs on the client. Field-name
encoding (not the .wksp JSON schema) — both ends speak dataclass fields."""

from __future__ import annotations

import dataclasses
import enum
import json
from collections import deque
from pathlib import Path

from ..core.dtos import (
    ConfigDelta,
    DirtyFile,
    EnvComparison,
    GitStatus,
    LoadedProject,
    ProcessStatus,
    SecretsKeys,
    ServiceState,
    StopSignal,
)
from ..core.models import McpConfig, Module, ModuleConfig, Project, ProjectRef, Service, Workspace
from .git import GitCloneResult
from .manager import ServiceInfo
from .workspace_manager import WorkspaceDiff

# ---- framing -------------------------------------------------------------


async def read_frame(reader) -> dict | None:
    """Read one length-prefixed JSON frame; None on EOF/short read."""
    try:
        header = await reader.readexactly(4)
        length = int.from_bytes(header, "big")
        body = await reader.readexactly(length)
    except (EOFError, ConnectionError, OSError):
        return None
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        return None


def write_frame(writer, obj: dict) -> None:
    """Write one frame (best-effort, no drain — safe from sync push callbacks)."""
    data = json.dumps(obj).encode()
    try:
        writer.write(len(data).to_bytes(4, "big") + data)
    except (ConnectionError, OSError):
        pass


# ---- generic encode ------------------------------------------------------


def to_wire(o):
    if dataclasses.is_dataclass(o) and not isinstance(o, type):
        return {f.name: to_wire(getattr(o, f.name)) for f in dataclasses.fields(o)}
    if isinstance(o, enum.Enum):
        return o.value
    if isinstance(o, dict):
        return {k: to_wire(v) for k, v in o.items()}
    if isinstance(o, (list, tuple, set, deque)):
        return [to_wire(v) for v in o]
    if isinstance(o, Path):
        return str(o)
    return o


# ---- typed decoders ------------------------------------------------------


def _service(d: dict) -> Service:
    return Service(name=d["name"], commands=d["commands"])


def _module(d: dict) -> Module:
    return Module(
        name=d["name"],
        services={k: _service(v) for k, v in d["services"].items()},
        config=ModuleConfig(**d["config"]),
    )


def project_from_wire(d: dict | None) -> Project | None:
    if d is None:
        return None
    return Project(
        modules=[_module(m) for m in d["modules"]],
        visible_tabs=d.get("visible_tabs", []),
        agent_guide=d.get("agent_guide"),
    )


def workspace_from_wire(d: dict | None) -> Workspace | None:
    if d is None:
        return None
    return Workspace(
        name=d["name"],
        projects={k: ProjectRef(**v) for k, v in d["projects"].items()},
        git_ssh_key_path=d.get("git_ssh_key_path"),
        mcp_config=McpConfig(**d["mcp_config"]) if d.get("mcp_config") else None,
    )


def loaded_project_from_wire(d: dict) -> LoadedProject:
    return LoadedProject(
        name=d["name"],
        resolved_path=d["resolved_path"],
        exists_on_disk=d["exists_on_disk"],
        git_repo_url=d.get("git_repo_url"),
        project_data=project_from_wire(d.get("project_data")),
        load_error=d.get("load_error"),
    )


def service_info_from_wire(d: dict) -> ServiceInfo:
    return ServiceInfo(
        project_name=d["project_name"],
        project_path=d["project_path"],
        module_name=d["module_name"],
        module_config=ModuleConfig(**d["module_config"]),
        service_name=d["service_name"],
        service=_service(d["service"]),
    )


def service_state_from_wire(d: dict) -> ServiceState:
    return ServiceState(
        service_id=d["service_id"],
        status=ProcessStatus(d["status"]),
        pid=d.get("pid"),
        start_time=d.get("start_time"),
        next_signal=StopSignal(d["next_signal"]),
    )


def git_status_from_wire(d: dict) -> GitStatus:
    out = dict(d)
    out["dirty_files"] = [DirtyFile(**f) for f in d.get("dirty_files", [])]
    out["config_deltas"] = [ConfigDelta(**c) for c in d.get("config_deltas", [])]
    return GitStatus(**out)


def env_comparison_from_wire(d: dict) -> EnvComparison:
    return EnvComparison(**d)


def secrets_keys_from_wire(d: dict) -> SecretsKeys:
    return SecretsKeys(**d)


def clone_from_wire(d: dict) -> GitCloneResult:
    return GitCloneResult(**d)


def workspace_diff_from_wire(d: dict) -> WorkspaceDiff:
    return WorkspaceDiff(
        added=d["added"],
        removed=d["removed"],
        changed=d["changed"],
        new_workspace=workspace_from_wire(d["new_workspace"]),
    )
