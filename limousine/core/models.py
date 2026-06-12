"""Workspace / project file models. Pure data, no I/O — ports of
lib/core/workspace.dart and lib/core/module.dart. Shared by the whole app."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class GlobalConfig:
    workspace_paths: list[str] = field(default_factory=list)

    @classmethod
    def from_json(cls, j: dict) -> "GlobalConfig":
        return cls(workspace_paths=list(j.get("limousine-workspaces") or []))

    def to_json(self) -> dict:
        return {"limousine-workspaces": self.workspace_paths}


@dataclass
class McpConfig:
    # MCP is on by default: a .wksp with no `mcp` block gets enabled=True.
    enabled: bool = True
    port: int = 6891
    token: str | None = None

    @classmethod
    def from_json(cls, j: dict) -> "McpConfig":
        return cls(enabled=j.get("enabled", True), port=j.get("port", 6891), token=j.get("token"))

    def to_json(self) -> dict:
        out = {"enabled": self.enabled, "port": self.port}
        if self.token:
            out["token"] = self.token
        return out


@dataclass
class ProjectRef:
    name: str
    path_on_disk: str
    git_repo_url: str | None = None

    @classmethod
    def from_json(cls, name: str, j: dict) -> "ProjectRef":
        return cls(name=name, path_on_disk=j.get("path-on-disk", ""), git_repo_url=j.get("optional-git-repo-url"))

    def to_json(self) -> dict:
        out = {"path-on-disk": self.path_on_disk}
        if self.git_repo_url:
            out["optional-git-repo-url"] = self.git_repo_url
        return out


@dataclass
class Workspace:
    name: str
    projects: dict[str, ProjectRef]
    git_ssh_key_path: str | None = None
    mcp_config: McpConfig | None = None

    @classmethod
    def from_json(cls, j: dict) -> "Workspace":
        projects = {k: ProjectRef.from_json(k, v) for k, v in (j.get("projects") or {}).items()}
        mcp = McpConfig.from_json(j["mcp"]) if j.get("mcp") is not None else McpConfig()
        return cls(
            name=j.get("name", ""),
            projects=projects,
            git_ssh_key_path=j.get("git-ssh-key-path"),
            mcp_config=mcp,
        )

    def to_json(self) -> dict:
        # collapsed-modules is deliberately not persisted (ephemeral UI state).
        out: dict = {"name": self.name, "projects": {k: v.to_json() for k, v in self.projects.items()}}
        if self.git_ssh_key_path:
            out["git-ssh-key-path"] = self.git_ssh_key_path
        if self.mcp_config:
            out["mcp"] = self.mcp_config.to_json()
        return out


@dataclass
class ModuleConfig:
    active_env_file: str = ".env"
    active_secrets_env_file: str = "secrets.env"
    source_env_file: str = ".env.example"
    source_secrets_file: str = "secrets.env.example"
    # True only when limousine.proj declared a `config:` block — drift detection
    # is skipped otherwise (module opted out of limousine's env model).
    declared: bool = False

    @classmethod
    def from_json(cls, j: dict, declared: bool = False) -> "ModuleConfig":
        return cls(
            declared=declared,
            active_env_file=j.get("active-env-file", ".env"),
            active_secrets_env_file=j.get("active-secrets-env-file", "secrets.env"),
            source_env_file=j.get("source-env-file", ".env.example"),
            source_secrets_file=j.get("source-secrets-file", "secrets.env.example"),
        )

    def to_json(self) -> dict:
        return {
            "active-env-file": self.active_env_file,
            "active-secrets-env-file": self.active_secrets_env_file,
            "source-env-file": self.source_env_file,
            "source-secrets-file": self.source_secrets_file,
        }


@dataclass
class Service:
    name: str
    commands: dict[str, str]

    @classmethod
    def from_json(cls, name: str, j: dict) -> "Service":
        commands = {k: str(v) for k, v in (j.get("commands") or {}).items()}
        return cls(name=name, commands=commands)

    def to_json(self) -> dict:
        return {"commands": self.commands}

    @property
    def run_command(self) -> str | None:
        return self.commands.get("run")

    @property
    def default_command(self) -> str | None:
        for key in ("run", "start", "dev"):
            if key in self.commands:
                return self.commands[key]
        return next(iter(self.commands.values()), None)


@dataclass
class Module:
    name: str
    services: dict[str, Service]
    config: ModuleConfig

    @classmethod
    def from_json(cls, name: str, j: dict) -> "Module":
        services = {k: Service.from_json(k, v) for k, v in (j.get("services") or {}).items()}
        cfg_raw = j.get("config")
        declared = isinstance(cfg_raw, dict)
        config = ModuleConfig.from_json(cfg_raw if declared else {}, declared=declared)
        return cls(name=name, services=services, config=config)

    def to_json(self) -> dict:
        return {
            "name": self.name,
            "services": {k: v.to_json() for k, v in self.services.items()},
            "config": self.config.to_json(),
        }


@dataclass
class Project:
    modules: list[Module]
    visible_tabs: list[str] = field(default_factory=list)
    agent_guide: str | None = None

    @classmethod
    def from_json(cls, j: dict) -> "Project":
        raw = j.get("modules")
        modules: list[Module] = []
        if isinstance(raw, list):
            modules = [Module.from_json(m.get("name", ""), m) for m in raw]
        elif isinstance(raw, dict):  # tolerate legacy map form
            modules = [Module.from_json(name, m) for name, m in raw.items()]
        return cls(
            modules=modules,
            visible_tabs=list(j.get("visible-tabs") or []),
            agent_guide=cls._parse_agent_guide(j.get("agent-guide")),
        )

    @staticmethod
    def _parse_agent_guide(raw) -> str | None:
        if raw is None:
            return None
        if isinstance(raw, str):
            return raw
        if isinstance(raw, list):  # list of paragraphs joined with blank lines
            return "\n\n".join(p for p in raw if isinstance(p, str))
        return None

    def to_json(self) -> dict:
        out: dict = {"modules": [m.to_json() for m in self.modules]}
        if self.visible_tabs:
            out["visible-tabs"] = self.visible_tabs
        if self.agent_guide is not None:
            out["agent-guide"] = self.agent_guide
        return out
