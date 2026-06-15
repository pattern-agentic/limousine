"""The seam. `Backend` is the interface the TUI and the MCP server program
against; `LocalBackend` runs everything in-process. A future `DaemonBackend`
(unix-socket client to a long-lived daemon) implements the same interface so
nothing above this line changes."""

from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Callable

import os

from ..core.dtos import EnvComparison, GitPullResult, GitStatus, ProcessStatus, SecretsKeys, ServiceState
from ..core.models import McpConfig, Workspace
from . import env as env_mod
from . import git, project_status, storage
from .git import GitCloneResult
from .manager import ServiceInfo, ServiceManager
from .secret_store import SecretStore, SecretStoreStatus
from .workspace_manager import WorkspaceDiff, WorkspaceManager


class BackendError(Exception):
    def __init__(self, message: str, blockers: list[str] | None = None):
        super().__init__(message)
        self.blockers = blockers or []


class Backend(ABC):
    # callbacks the UI attaches to receive live updates
    on_output: Callable[[str, list], None] | None = None
    on_state: Callable[[ServiceState], None] | None = None
    on_workspace_change: Callable[[], None] | None = None
    on_secret_status: Callable | None = None

    async def aopen(self) -> None:
        """Async startup hook the app awaits on mount (DaemonBackend connects
        here; LocalBackend is already open)."""
        return

    @abstractmethod
    async def open_workspace(self, path: str) -> None: ...
    @abstractmethod
    def close_workspace(self) -> None: ...
    @abstractmethod
    async def reload_project(self, name: str) -> None: ...
    @abstractmethod
    async def reload_workspace(self) -> WorkspaceDiff: ...

    @property
    @abstractmethod
    def workspace(self) -> Workspace | None: ...
    @property
    @abstractmethod
    def projects(self) -> dict: ...
    @abstractmethod
    def list_services(self) -> list[ServiceInfo]: ...
    @abstractmethod
    def service_states(self) -> dict[str, ServiceState]: ...
    @abstractmethod
    def find_service(self, sid: str) -> ServiceInfo | None: ...

    @abstractmethod
    def start_service(self, sid: str, command: str | None = None, raw: str | None = None) -> None: ...
    @abstractmethod
    async def stop_service(self, sid: str) -> bool: ...
    @abstractmethod
    def kill_orphan(self, sid: str) -> None: ...
    @abstractmethod
    def send_input(self, sid: str, text: str) -> None: ...
    @abstractmethod
    def inject_log(self, sid: str, text: str) -> None: ...
    @abstractmethod
    def buffer(self, sid: str): ...
    @abstractmethod
    def tail(self, sid: str) -> str: ...
    @abstractmethod
    def awaiting_input(self, sid: str) -> bool: ...

    @abstractmethod
    async def git_status(self, name: str) -> GitStatus: ...
    @abstractmethod
    async def git_refresh(self, name: str) -> GitStatus: ...
    @abstractmethod
    async def git_pull(self, name: str) -> GitPullResult: ...
    @abstractmethod
    async def clone(self, name: str, on_line=None) -> GitCloneResult: ...
    @abstractmethod
    def project_info(self, name: str) -> dict | None: ...

    # env / secrets editing
    @abstractmethod
    async def get_env(self, sid: str) -> EnvComparison: ...
    @abstractmethod
    def save_env(self, sid: str, content: dict[str, str]) -> None: ...
    @abstractmethod
    async def secrets_keys(self, sid: str) -> SecretsKeys: ...
    @abstractmethod
    async def get_secrets(self, sid: str) -> dict[str, str]: ...
    @abstractmethod
    async def save_secrets(self, sid: str, content: dict[str, str]) -> None: ...
    @abstractmethod
    async def unlock_secrets(self, key: str) -> SecretStoreStatus: ...
    @abstractmethod
    def secret_store_status(self) -> SecretStoreStatus: ...

    # workspace settings + recents
    @abstractmethod
    def update_settings(self, *, mcp_enabled: bool, mcp_port: int, git_ssh_key_path: str | None) -> None: ...
    @abstractmethod
    def recent_workspaces(self) -> list[str]: ...
    @abstractmethod
    def add_recent(self, path: str) -> None: ...
    @abstractmethod
    def remove_recent(self, path: str) -> None: ...


class LocalBackend(Backend):
    def __init__(self, override_clone_root: str | None = None):
        self.secret_store = SecretStore()
        self.wsm = WorkspaceManager(override_clone_root=override_clone_root)
        self.manager = ServiceManager(secret_store=self.secret_store)
        self.manager.on_output = self._fwd_output
        self.manager.on_state = self._fwd_state
        self.secret_store.on_status = self._fwd_secret_status
        self.wsm.add_listener(self._fwd_workspace_change)

    # ---- callback forwarding --------------------------------------------

    def _fwd_output(self, sid: str, lines: list) -> None:
        if self.on_output:
            self.on_output(sid, lines)

    def _fwd_state(self, state: ServiceState) -> None:
        if self.on_state:
            self.on_state(state)

    def _fwd_workspace_change(self) -> None:
        if self.on_workspace_change:
            self.on_workspace_change()

    def _fwd_secret_status(self, status) -> None:
        if self.on_secret_status:
            self.on_secret_status(status)

    # ---- workspace -------------------------------------------------------

    async def open_workspace(self, path: str) -> None:
        self.wsm.open(path)
        self.manager.workspace_path = path
        await self.secret_store.init_for_workspace(path)
        self.manager.scan_orphans()

    def close_workspace(self) -> None:
        self.wsm.close()
        self.manager.workspace_path = None

    @property
    def workspace(self) -> Workspace | None:
        return self.wsm.workspace

    @property
    def projects(self) -> dict:
        return self.wsm.projects

    async def reload_project(self, name: str) -> None:
        # optimistic: just re-parse. Running services whose definition was dropped
        # keep running and stay visible (see list_services) until they exit.
        self.wsm.reload_project(name)

    async def reload_workspace(self) -> WorkspaceDiff:
        diff = self.wsm.peek_diff()
        self.wsm.apply_diff(diff)
        return diff

    # ---- services --------------------------------------------------------

    def list_services(self) -> list[ServiceInfo]:
        # the workspace definition + any running/orphaned service whose definition
        # was dropped by a reload (so it stays stoppable until it exits)
        services = self.wsm.all_services()
        known = {s.id for s in services}
        for sid, info in self.manager.tracked_infos().items():
            if sid not in known:
                services.append(info)
        return services

    def service_states(self) -> dict[str, ServiceState]:
        return self.manager.states()

    def find_service(self, sid: str) -> ServiceInfo | None:
        return next((s for s in self.list_services() if s.id == sid), None)

    def start_service(self, sid: str, command: str | None = None, raw: str | None = None) -> None:
        info = self.wsm.find_service(sid)
        if info is None:
            raise BackendError(f"unknown service {sid}")
        self.manager.start(info, command, raw)

    async def stop_service(self, sid: str) -> bool:
        return await self.manager.stop_escalating(sid)

    def kill_orphan(self, sid: str) -> None:
        self.manager.kill_orphan(sid)

    def send_input(self, sid: str, text: str) -> None:
        self.manager.send_input(sid, text)

    def inject_log(self, sid: str, text: str) -> None:
        self.manager.inject(sid, text)

    def buffer(self, sid: str):
        return self.manager.buffer(sid)

    def tail(self, sid: str) -> str:
        return self.manager.tail(sid)

    def awaiting_input(self, sid: str) -> bool:
        return self.manager.awaiting_input(sid)

    # ---- git -------------------------------------------------------------

    def _resolved_path(self, name: str) -> str | None:
        loaded = self.wsm.projects.get(name)
        return loaded.resolved_path if loaded else None

    async def git_status(self, name: str) -> GitStatus:
        loaded = self.wsm.projects.get(name)
        if loaded is None:
            return GitStatus(project=name, exists=False, error="unknown project")
        return await project_status.read(name, loaded)

    async def git_refresh(self, name: str) -> GitStatus:
        loaded = self.wsm.projects.get(name)
        if loaded is None:
            return GitStatus(project=name, exists=False, error="unknown project")
        return await project_status.refresh(name, loaded)

    async def git_pull(self, name: str) -> GitPullResult:
        path = self._resolved_path(name)
        if path is None:
            return GitPullResult(ok=False, message="unknown project", status=GitStatus(project=name, exists=False))
        return await git.pull_ff_only(name, path)

    async def git_status_all(self) -> list[dict]:
        return await project_status.read_all(self.wsm)

    async def clone(self, name: str, on_line=None) -> GitCloneResult:
        loaded = self.wsm.projects.get(name)
        if loaded is None or not loaded.git_repo_url:
            return GitCloneResult(False, "", "no git-repo-url for project", 1)
        ws = self.wsm.workspace
        ssh_key = ws.git_ssh_key_path if ws else None
        result = await git.clone(loaded.git_repo_url, loaded.resolved_path, ssh_key, on_line=on_line)
        if result.success:
            self.wsm.reload_project(name)
        return result

    # ---- project info ----------------------------------------------------

    def project_info(self, name: str) -> dict | None:
        loaded = self.wsm.projects.get(name)
        if loaded is None:
            return None
        out: dict = {
            "name": loaded.name,
            "path": loaded.resolved_path,
            "existsOnDisk": loaded.exists_on_disk,
        }
        if loaded.load_error:
            out["loadError"] = loaded.load_error
        data = loaded.project_data
        if data is not None:
            if data.agent_guide:
                out["agentGuide"] = data.agent_guide
            out["modules"] = [
                {
                    "name": m.name,
                    "services": [
                        {"name": sn, "commands": list(sv.commands)} for sn, sv in m.services.items()
                    ],
                }
                for m in data.modules
            ]
        return out

    # ---- env / secrets editing ------------------------------------------

    def _service_files(self, sid: str) -> dict | None:
        info = self.wsm.find_service(sid)
        if info is None:
            return None
        base = info.project_path
        c = info.module_config
        return {
            "env_active": os.path.join(base, c.active_env_file),
            "env_source": os.path.join(base, c.source_env_file),
            "sec_active": os.path.join(base, c.active_secrets_env_file),
            "sec_source": os.path.join(base, c.source_secrets_file),
        }

    async def get_env(self, sid: str) -> EnvComparison:
        f = self._service_files(sid)
        if f is None:
            raise BackendError(f"unknown service {sid}")
        return env_mod.compare_env_files(f["env_active"], f["env_source"])

    def save_env(self, sid: str, content: dict[str, str]) -> None:
        f = self._service_files(sid)
        if f is None:
            raise BackendError(f"unknown service {sid}")
        env_mod.write_env_file(f["env_active"], content)

    async def secrets_keys(self, sid: str) -> SecretsKeys:
        f = self._service_files(sid)
        if f is None:
            raise BackendError(f"unknown service {sid}")
        source = env_mod.load_env_file(f["sec_source"])
        active_exists = os.path.exists(f["sec_active"])
        active_keys: list[str] = []
        read_error: str | None = None
        if active_exists:
            if self.secret_store.unlocked:
                try:
                    active_keys = list((await self.secret_store.decrypt_secrets(f["sec_active"])).keys())
                except Exception as e:
                    read_error = str(e)
            else:
                read_error = "secret store locked"
        return SecretsKeys(
            active_exists=active_exists,
            source_exists=os.path.exists(f["sec_source"]),
            active_keys=active_keys,
            source_content=source,
            read_error=read_error,
        )

    async def get_secrets(self, sid: str) -> dict[str, str]:
        f = self._service_files(sid)
        if f is None:
            raise BackendError(f"unknown service {sid}")
        return await self.secret_store.decrypt_secrets(f["sec_active"])

    async def save_secrets(self, sid: str, content: dict[str, str]) -> None:
        f = self._service_files(sid)
        if f is None:
            raise BackendError(f"unknown service {sid}")
        await self.secret_store.save_secrets(f["sec_active"], content)

    async def unlock_secrets(self, key: str) -> SecretStoreStatus:
        return await self.secret_store.unlock(key)

    def secret_store_status(self) -> SecretStoreStatus:
        return self.secret_store.status

    # ---- settings + recents ---------------------------------------------

    def update_settings(self, *, mcp_enabled: bool, mcp_port: int, git_ssh_key_path: str | None) -> None:
        ws = self.wsm.workspace
        if ws is None:
            return
        updated = Workspace(
            name=ws.name,
            projects=ws.projects,
            git_ssh_key_path=git_ssh_key_path or None,
            mcp_config=McpConfig(enabled=mcp_enabled, port=mcp_port,
                                 token=ws.mcp_config.token if ws.mcp_config else None),
        )
        self.wsm.save_workspace(updated)

    def apply_settings(self, mcp_enabled: bool, mcp_port: int, git_ssh_key_path: str | None) -> None:
        """Positional shim so the daemon can dispatch the keyword-only setter."""
        self.update_settings(mcp_enabled=mcp_enabled, mcp_port=mcp_port, git_ssh_key_path=git_ssh_key_path)

    def recent_workspaces(self) -> list[str]:
        return storage.load_global_config().workspace_paths

    def add_recent(self, path: str) -> None:
        cfg = storage.load_global_config()
        paths = [p for p in cfg.workspace_paths if p != path]
        cfg.workspace_paths = [path, *paths]
        storage.save_global_config(cfg)

    def remove_recent(self, path: str) -> None:
        cfg = storage.load_global_config()
        cfg.workspace_paths = [p for p in cfg.workspace_paths if p != path]
        storage.save_global_config(cfg)
