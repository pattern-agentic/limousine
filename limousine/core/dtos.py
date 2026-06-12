"""Backend value types — port of lib/core/dto.dart. The backend is in-process
now, so these are plain dataclasses with computed properties; JSON shaping lives
only where it crosses a wire (MCP tool returns, agent summaries)."""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum

from .models import Project


class ProcessStatus(str, Enum):
    stopped = "stopped"
    running = "running"
    orphaned = "orphaned"


class StopSignal(str, Enum):
    sigint = "sigint"
    sigterm = "sigterm"
    sigkill = "sigkill"


@dataclass
class ServiceState:
    service_id: str
    status: ProcessStatus = ProcessStatus.stopped
    pid: int | None = None
    start_time: float | None = None  # epoch seconds, for uptime display
    next_signal: StopSignal = StopSignal.sigint


@dataclass
class LoadedProject:
    name: str
    resolved_path: str
    exists_on_disk: bool
    git_repo_url: str | None = None
    project_data: Project | None = None
    load_error: str | None = None


@dataclass
class EnvComparison:
    active_exists: bool
    source_exists: bool
    active_content: dict[str, str]
    source_content: dict[str, str]

    @property
    def active_keys(self) -> set[str]:
        return set(self.active_content)

    @property
    def source_keys(self) -> set[str]:
        return set(self.source_content)

    @property
    def missing_in_active(self) -> set[str]:
        return self.source_keys - self.active_keys

    @property
    def extra_in_active(self) -> set[str]:
        return self.active_keys - self.source_keys


@dataclass
class SecretsKeys:
    """Keys-only view of a secrets file — no values. Lets the editor render its
    skeleton before the age key is supplied."""

    active_exists: bool
    source_exists: bool
    active_keys: list[str]
    source_content: dict[str, str]  # template, not secret
    read_error: str | None = None


@dataclass
class ConfigDelta:
    module: str
    env_active_exists: bool = False
    env_source_exists: bool = False
    env_missing_in_active: int = 0
    env_extra_in_active: int = 0
    secrets_active_exists: bool = False
    secrets_source_exists: bool = False
    secrets_missing_in_active: int = 0
    secrets_extra_in_active: int = 0

    @property
    def has_env_delta(self) -> bool:
        return self.env_source_exists and (
            self.env_missing_in_active > 0 or self.env_extra_in_active > 0 or not self.env_active_exists
        )

    @property
    def has_secrets_delta(self) -> bool:
        return self.secrets_source_exists and (
            self.secrets_missing_in_active > 0
            or self.secrets_extra_in_active > 0
            or not self.secrets_active_exists
        )

    @property
    def has_any(self) -> bool:
        return self.has_env_delta or self.has_secrets_delta


@dataclass
class DirtyFile:
    path: str
    status: str  # 2-char porcelain code, e.g. " M", "??", "MM"
    is_lock_file: bool


@dataclass
class GitStatus:
    """Per-project git status. All upstream/main counts are local-ref only (no
    network); call refresh() to update after a fetch."""

    project: str
    exists: bool
    branch: str | None = None
    short_sha: str | None = None
    subject: str | None = None
    dirty_files: list[DirtyFile] = field(default_factory=list)
    upstream: str | None = None
    behind_upstream: int | None = None
    ahead_upstream: int | None = None
    main_branch: str | None = None
    behind_main: int | None = None
    latest_tag: str | None = None
    commits_since_tag: int | None = None
    last_fetched: float | None = None  # epoch seconds
    error: str | None = None
    config_deltas: list[ConfigDelta] = field(default_factory=list)

    @property
    def dirty(self) -> int:
        return len(self.dirty_files)

    @property
    def dirty_code(self) -> int:
        return sum(1 for f in self.dirty_files if not f.is_lock_file)

    @property
    def dirty_lock(self) -> int:
        return sum(1 for f in self.dirty_files if f.is_lock_file)

    @property
    def lock_files(self) -> list[DirtyFile]:
        return [f for f in self.dirty_files if f.is_lock_file]

    @property
    def code_files(self) -> list[DirtyFile]:
        return [f for f in self.dirty_files if not f.is_lock_file]


@dataclass
class GitPullResult:
    ok: bool
    message: str
    status: GitStatus
