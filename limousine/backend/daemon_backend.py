"""DaemonBackend — a Backend that proxies to a daemon over a unix socket.

Hot-path queries (states, buffers, tail, waiting, workspace/projects/services)
are answered from a local mirror fed by the daemon's pushes, so the TUI's 50ms
drain never blocks on the wire. Cold reads/writes (git, env, secrets, reload)
are RPCs. Fire-and-forget commands (start, input, kill) are scheduled and not
awaited. recents are read straight from the local filesystem (same machine)."""

from __future__ import annotations

import asyncio
import time
from collections import deque

from ..core.dtos import (
    EnvComparison,
    GitPullResult,
    GitStatus,
    LoadedProject,
    ProcessStatus,
    SecretsKeys,
    ServiceState,
)
from ..core.models import Workspace
from . import storage, wire
from .backend import Backend, BackendError
from .git import GitCloneResult
from .manager import ServiceInfo
from .secret_store import SecretStoreStatus
from .workspace_manager import WorkspaceDiff

BUFFER_LINES = 2000


class DaemonBackend(Backend):
    def __init__(self, socket_path: str):
        self.socket_path = socket_path
        self._reader = None
        self._writer = None
        self._next_id = 0
        self._pending: dict[int, asyncio.Future] = {}
        # local mirror
        self._workspace: Workspace | None = None
        self._projects: dict[str, LoadedProject] = {}
        self._services: list[ServiceInfo] = []
        self._states: dict[str, ServiceState] = {}
        self._buffers: dict[str, deque] = {}
        self._tails: dict[str, str] = {}
        self._awaiting: dict[str, bool] = {}
        self._secret_status = SecretStoreStatus.MISSING_KEY

    async def aopen(self) -> None:
        await self.connect()

    async def connect(self) -> None:
        self._reader, self._writer = await asyncio.open_unix_connection(self.socket_path)
        asyncio.ensure_future(self._read_loop())
        await self._refresh_snapshot()

    # ---- transport -------------------------------------------------------

    async def _read_loop(self) -> None:
        while True:
            msg = await wire.read_frame(self._reader)
            if msg is None:
                break  # daemon gone
            if "type" in msg:
                self._handle_push(msg)
            else:
                fut = self._pending.pop(msg.get("id"), None)
                if fut and not fut.done():
                    fut.set_result(msg)

    async def _rpc(self, method: str, *args):
        if self._writer is None:
            raise BackendError("not connected to daemon")
        self._next_id += 1
        mid = self._next_id
        fut = asyncio.get_running_loop().create_future()
        self._pending[mid] = fut
        wire.write_frame(self._writer, {"id": mid, "method": method, "args": list(args)})
        await self._writer.drain()
        resp = await fut
        if resp.get("error"):
            raise BackendError(resp["error"])
        return resp.get("result")

    def _fire(self, method: str, *args) -> None:
        asyncio.ensure_future(self._rpc(method, *args))

    async def _refresh_snapshot(self) -> None:
        snap = await self._rpc("snapshot")
        self._workspace = wire.workspace_from_wire(snap["workspace"])
        self._projects = {k: wire.loaded_project_from_wire(v) for k, v in snap["projects"].items()}
        self._services = [wire.service_info_from_wire(s) for s in snap["services"]]
        self._states = {k: wire.service_state_from_wire(v) for k, v in snap["states"].items()}
        self._secret_status = SecretStoreStatus(snap["secret_status"])

    def _handle_push(self, msg: dict) -> None:
        t = msg["type"]
        if t == "state":
            st = wire.service_state_from_wire(msg["state"])
            self._states[st.service_id] = st
            if self.on_state:
                self.on_state(st)
        elif t == "output":
            sid, lines = msg["sid"], msg["lines"]
            self._buffers.setdefault(sid, deque(maxlen=BUFFER_LINES)).extend(lines)
            if self.on_output and lines:
                self.on_output(sid, lines)
        elif t == "tail":
            self._tails[msg["sid"]] = msg["tail"]
            self._awaiting[msg["sid"]] = msg["awaiting"]
        elif t == "secret-status":
            self._secret_status = SecretStoreStatus(msg["status"])
            if self.on_secret_status:
                self.on_secret_status(self._secret_status)
        elif t == "workspace-change":
            asyncio.ensure_future(self._on_wschange())

    async def _on_wschange(self) -> None:
        await self._refresh_snapshot()
        if self.on_workspace_change:
            self.on_workspace_change()

    # ---- cached / local (sync) ------------------------------------------

    @property
    def workspace(self) -> Workspace | None:
        return self._workspace

    @property
    def projects(self) -> dict[str, LoadedProject]:
        return self._projects

    def list_services(self) -> list[ServiceInfo]:
        return self._services

    def service_states(self) -> dict[str, ServiceState]:
        return self._states

    def find_service(self, sid: str) -> ServiceInfo | None:
        return next((s for s in self._services if s.id == sid), None)

    def buffer(self, sid: str):
        return self._buffers.get(sid, deque())

    def tail(self, sid: str) -> str:
        return self._tails.get(sid, "")

    def awaiting_input(self, sid: str) -> bool:
        return self._awaiting.get(sid, False)

    def secret_store_status(self) -> SecretStoreStatus:
        return self._secret_status

    def recent_workspaces(self) -> list[str]:
        return storage.load_global_config().workspace_paths

    def add_recent(self, path: str) -> None:
        cfg = storage.load_global_config()
        cfg.workspace_paths = [path, *[p for p in cfg.workspace_paths if p != path]]
        storage.save_global_config(cfg)

    def remove_recent(self, path: str) -> None:
        cfg = storage.load_global_config()
        cfg.workspace_paths = [p for p in cfg.workspace_paths if p != path]
        storage.save_global_config(cfg)

    # ---- fire-and-forget commands (sync) --------------------------------

    def start_service(self, sid: str, command: str | None = None, raw: str | None = None) -> None:
        self._fire("start_service", sid, command, raw)

    def kill_orphan(self, sid: str) -> None:
        self._fire("kill_orphan", sid)

    def send_input(self, sid: str, text: str) -> None:
        self._fire("send_input", sid, text)

    def inject_log(self, sid: str, text: str) -> None:
        # injected on the daemon so it lands in-order in the shared buffer and
        # pushes back to every client
        self._fire("inject_log", sid, text)

    def close_workspace(self) -> None:
        self._fire("close_workspace")

    def save_env(self, sid: str, content: dict[str, str]) -> None:
        self._fire("save_env", sid, content)

    def update_settings(self, *, mcp_enabled: bool, mcp_port: int, git_ssh_key_path: str | None) -> None:
        self._fire("apply_settings", mcp_enabled, mcp_port, git_ssh_key_path)

    # ---- RPC reads / writes (async) -------------------------------------

    async def open_workspace(self, path: str) -> None:
        await self._rpc("open_workspace", path)
        await self._refresh_snapshot()

    async def reload_project(self, name: str) -> None:
        await self._rpc("reload_project", name)

    async def reload_workspace(self) -> WorkspaceDiff:
        return wire.workspace_diff_from_wire(await self._rpc("reload_workspace"))

    async def stop_service(self, sid: str) -> bool:
        return await self._rpc("stop_service", sid)

    async def shutdown_daemon(self) -> bool:
        """Ask the daemon to stop all services and exit. The socket dies right
        after the ack, so this is the last RPC on the connection."""
        return await self._rpc("shutdown_daemon")

    async def git_status(self, name: str) -> GitStatus:
        return wire.git_status_from_wire(await self._rpc("git_status", name))

    async def git_refresh(self, name: str) -> GitStatus:
        return wire.git_status_from_wire(await self._rpc("git_refresh", name))

    async def git_pull(self, name: str) -> GitPullResult:
        d = await self._rpc("git_pull", name)
        return GitPullResult(ok=d["ok"], message=d["message"], status=wire.git_status_from_wire(d["status"]))

    async def clone(self, name: str, on_line=None) -> GitCloneResult:
        # streaming over the socket isn't wired; the daemon runs it and returns
        # the full captured output, which the caller can dump to the log.
        return wire.clone_from_wire(await self._rpc("clone", name))

    def project_info(self, name: str) -> dict | None:
        # built from the mirrored project tree — no round-trip needed
        loaded = self._projects.get(name)
        if loaded is None:
            return None
        out: dict = {"name": loaded.name, "path": loaded.resolved_path, "existsOnDisk": loaded.exists_on_disk}
        if loaded.load_error:
            out["loadError"] = loaded.load_error
        data = loaded.project_data
        if data is not None:
            if data.agent_guide:
                out["agentGuide"] = data.agent_guide
            out["modules"] = [
                {"name": m.name, "services": [{"name": sn, "commands": list(sv.commands)}
                                              for sn, sv in m.services.items()]}
                for m in data.modules
            ]
        return out

    async def get_env(self, sid: str) -> EnvComparison:
        return wire.env_comparison_from_wire(await self._rpc("get_env", sid))

    async def secrets_keys(self, sid: str) -> SecretsKeys:
        return wire.secrets_keys_from_wire(await self._rpc("secrets_keys", sid))

    async def get_secrets(self, sid: str) -> dict[str, str]:
        return await self._rpc("get_secrets", sid)

    async def save_secrets(self, sid: str, content: dict[str, str]) -> None:
        await self._rpc("save_secrets", sid, content)

    async def unlock_secrets(self, key: str) -> SecretStoreStatus:
        status = SecretStoreStatus(await self._rpc("unlock_secrets", key))
        self._secret_status = status
        return status
