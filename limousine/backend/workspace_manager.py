"""In-memory state for the open workspace + loaded projects. Port of
lib/server/workspace_manager.dart. Change notification is a simple callback list
(the Dart broadcast stream); the TUI/backend subscribe to refresh on edits."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from ..core.dtos import LoadedProject
from ..core.models import ProjectRef, Workspace
from . import storage
from .manager import ServiceInfo


@dataclass
class WorkspaceDiff:
    added: list[str]
    removed: list[str]
    changed: list[str]
    new_workspace: Workspace

    @property
    def has_changes(self) -> bool:
        return bool(self.added or self.removed or self.changed)


class WorkspaceManager:
    def __init__(self, override_clone_root: str | None = None):
        self.override_clone_root = override_clone_root
        self._workspace_path: str | None = None
        self._workspace: Workspace | None = None
        self._projects: dict[str, LoadedProject] = {}
        self._listeners: list[Callable[[], None]] = []

    # ---- accessors -------------------------------------------------------

    @property
    def workspace_path(self) -> str | None:
        return self._workspace_path

    @property
    def workspace(self) -> Workspace | None:
        return self._workspace

    @property
    def projects(self) -> dict[str, LoadedProject]:
        return dict(self._projects)

    @property
    def clone_root(self) -> str | None:
        if self.override_clone_root is not None:
            return self.override_clone_root
        return str(Path(self._workspace_path).parent) if self._workspace_path else None

    def add_listener(self, cb: Callable[[], None]) -> None:
        self._listeners.append(cb)

    def _notify(self) -> None:
        for cb in self._listeners:
            cb()

    # ---- open / close / reload ------------------------------------------

    def open(self, path: str) -> None:
        self._workspace_path = path
        self._workspace = storage.load_workspace(path)
        self._reload_projects()
        self._notify()

    def close(self) -> None:
        self._workspace_path = None
        self._workspace = None
        self._projects = {}
        self._notify()

    def reload_projects(self) -> None:
        if self._workspace is None:
            return
        self._reload_projects()
        self._notify()

    def _reload_projects(self) -> None:
        root = self.clone_root
        if self._workspace is None or root is None:
            self._projects = {}
            return
        self._projects = {
            name: self._load_one(name, ref, root) for name, ref in self._workspace.projects.items()
        }

    def _load_one(self, name: str, ref: ProjectRef, root: str) -> LoadedProject:
        resolved = storage.resolve_path(root, ref.path_on_disk)
        exists = storage.project_exists_on_disk(root, ref.path_on_disk)
        project_data = None
        load_error = None
        if exists:
            try:
                project_data = storage.load_project(resolved)
            except ValueError as e:
                load_error = str(e)
            except Exception as e:  # surface dev-only failures with detail
                load_error = f"Failed to load project: {e}"
        return LoadedProject(
            name=name,
            resolved_path=resolved,
            git_repo_url=ref.git_repo_url,
            exists_on_disk=exists,
            project_data=project_data,
            load_error=load_error,
        )

    def reload_project(self, name: str) -> None:
        root = self.clone_root
        if self._workspace is None or root is None:
            return
        ref = self._workspace.projects.get(name)
        if ref is None:
            return
        self._projects[name] = self._load_one(name, ref, root)
        self._notify()

    # ---- diff-based workspace reload ------------------------------------

    def peek_diff(self) -> WorkspaceDiff:
        if self._workspace_path is None or self._workspace is None:
            raise RuntimeError("No workspace open")
        nxt = storage.load_workspace(self._workspace_path)
        added, removed, changed = [], [], []
        for key, ref in nxt.projects.items():
            old = self._workspace.projects.get(key)
            if old is None:
                added.append(key)
            elif old.path_on_disk != ref.path_on_disk or old.git_repo_url != ref.git_repo_url:
                changed.append(key)
        for old_key in self._workspace.projects:
            if old_key not in nxt.projects:
                removed.append(old_key)
        return WorkspaceDiff(added=added, removed=removed, changed=changed, new_workspace=nxt)

    def apply_diff(self, diff: WorkspaceDiff) -> None:
        root = self.clone_root
        if root is None:
            return
        self._workspace = diff.new_workspace
        for name in diff.removed:
            self._projects.pop(name, None)
        for name in [*diff.added, *diff.changed]:
            ref = self._workspace.projects.get(name)
            if ref is not None:
                self._projects[name] = self._load_one(name, ref, root)
        self._notify()

    # ---- services --------------------------------------------------------

    def all_services(self) -> list[ServiceInfo]:
        result: list[ServiceInfo] = []
        for project in self._projects.values():
            if project.project_data is None:
                continue
            for module in project.project_data.modules:
                for svc_name, service in module.services.items():
                    result.append(
                        ServiceInfo(
                            project_name=project.name,
                            project_path=project.resolved_path,
                            module_name=module.name,
                            module_config=module.config,
                            service_name=svc_name,
                            service=service,
                        )
                    )
        return result

    def find_service(self, service_id: str) -> ServiceInfo | None:
        return next((s for s in self.all_services() if s.id == service_id), None)

    def save_workspace(self, updated: Workspace) -> None:
        if self._workspace_path is None:
            return
        storage.save_workspace(self._workspace_path, updated)
        self._workspace = updated
        self._notify()
