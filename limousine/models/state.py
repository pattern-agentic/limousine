from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from collections import deque
from typing import Any


@dataclass
class ProcessState:
    state: str
    last_error: str | None = None
    pid: int | None = None
    start_time: datetime | None = None
    output_buffer: deque = field(default_factory=lambda: deque(maxlen=5000))

    def add_output(self, line: str) -> None:
        self.output_buffer.append(line)

    def get_output_lines(self, limit: int | None = None) -> list[str]:
        if limit is None:
            return list(self.output_buffer)
        return list(self.output_buffer)[-limit:]


@dataclass
class SourceState:
    cloned: bool = False


@dataclass
class ServiceState:
    command_states: dict[str, ProcessState] = field(default_factory=dict)


@dataclass
class ModuleState:
    services: dict[str, ServiceState]
    source_state: SourceState = field(default_factory=SourceState)


@dataclass
class AppState:
    current_project_file: Path | None = None
    modules: dict[str, ModuleState] = field(default_factory=dict)
    docker_services: dict[str, ServiceState] = field(default_factory=dict)
