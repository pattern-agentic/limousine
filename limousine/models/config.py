from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class ModuleConfig:
    active_env_file: str | None = None
    source_env_file: str | None = None
    secrets_file: str | None = None
    secrets_example_file: str | None = None


@dataclass
class Service:
    commands: dict[str, str]


@dataclass
class DockerService:
    commands: dict[str, str]


@dataclass
class Module:
    name: str
    git_repo_url: str
    clone_path: str
    services: dict[str, Service]
    config: ModuleConfig | None = None


@dataclass
class ProjectConfig:
    modules: dict[str, Module]
    docker_services: dict[str, DockerService] = field(default_factory=dict)


@dataclass
class GlobalConfig:
    projects: list[Path] = field(default_factory=list)
