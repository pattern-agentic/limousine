"""Per-service PTY lifecycle — port of lib/server/service_manager.dart, built on
the spike's validated PTY core (ptyprocess + loop.add_reader, CRLF-correct line
buffering, escalating stop, orphan re-adoption, waiting-for-input heuristic).

UI-free: drives PTYs and emits state/output via callbacks. The TUI and the MCP
server both sit on top of this through the Backend."""

from __future__ import annotations

import asyncio
import codecs
import os
import signal
import time
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from ptyprocess import PtyProcess

from ..core.dtos import ProcessStatus, ServiceState, StopSignal
from ..core.models import ModuleConfig, Service
from . import env as env_mod
from . import storage

BUFFER_LINES = 2000
_ESCALATION = [
    (signal.SIGINT, StopSignal.sigint),
    (signal.SIGTERM, StopSignal.sigterm),
    (signal.SIGKILL, StopSignal.sigkill),
]


@dataclass
class ServiceInfo:
    """Server-side view of a service (= lib/server ServiceInfo). Carries
    everything the manager needs to spawn and everything the UI needs to show."""

    project_name: str
    project_path: str
    module_name: str
    module_config: ModuleConfig
    service_name: str
    service: Service

    @property
    def id(self) -> str:
        return f"{self.module_name}/{self.service_name}"


@dataclass
class _Running:
    proc: PtyProcess
    buffer: deque
    decoder: object
    pid: int
    start_mono: float
    start_epoch: float
    tail: str = ""
    next_signal: int = 0  # index into _ESCALATION
    last_output: float = 0.0
    info: "ServiceInfo | None" = None  # what it was started with (survives a project reload)


OutputCb = Callable[[str, list], None]
StateCb = Callable[[ServiceState], None]


class ServiceManager:
    def __init__(self, secret_store=None):
        self.secret_store = secret_store
        self.workspace_path: str | None = None  # set by the backend on workspace open
        self._running: dict[str, _Running] = {}
        self._buffers: dict[str, deque] = {}
        self._states: dict[str, ServiceState] = {}
        self.on_output: OutputCb | None = None
        self.on_state: StateCb | None = None

    # ---- queries ---------------------------------------------------------

    def state(self, sid: str) -> ServiceState:
        return self._states.get(sid, ServiceState(service_id=sid))

    def status(self, sid: str) -> ProcessStatus:
        return self.state(sid).status

    def states(self) -> dict[str, ServiceState]:
        return dict(self._states)

    def tracked_infos(self) -> dict[str, "ServiceInfo"]:
        """ServiceInfo for every running/orphaned service — including ones whose
        definition was dropped by a reload, so the UI can keep showing + stopping
        them. Uses the info it was started with, or a placeholder for orphans."""
        out: dict[str, ServiceInfo] = {}
        for sid, st in self._states.items():
            if st.status in (ProcessStatus.running, ProcessStatus.orphaned):
                r = self._running.get(sid)
                out[sid] = r.info if r and r.info else self._placeholder_info(sid)
        return out

    @staticmethod
    def _placeholder_info(sid: str) -> "ServiceInfo":
        mod, _, svc = sid.partition("/")
        return ServiceInfo(
            project_name="(stale)", project_path="", module_name=mod or sid,
            module_config=ModuleConfig(), service_name=svc or sid, service=Service(name=svc or sid, commands={}),
        )

    def buffer(self, sid: str) -> deque:
        return self._buffers.get(sid, deque())

    def tail(self, sid: str) -> str:
        r = self._running.get(sid)
        return self._clean_line(r.tail) if r and r.tail else ""

    def awaiting_input(self, sid: str, idle: float = 0.4) -> bool:
        """A running service on a non-empty partial line that's gone idle is
        almost certainly blocked on a read (a prompt)."""
        r = self._running.get(sid)
        if r is None or not r.tail:
            return False
        return (time.monotonic() - r.last_output) >= idle

    def uptime(self, sid: str) -> float | None:
        r = self._running.get(sid)
        return (time.monotonic() - r.start_mono) if r else None

    # ---- lifecycle -------------------------------------------------------

    def start(self, info: ServiceInfo, command: str | None = None, raw: str | None = None) -> None:
        sid = info.id
        if sid in self._running:
            return
        if raw is not None:
            cmd = raw  # an edited / one-off command string
        elif command:
            cmd = info.service.commands.get(command)
        else:
            cmd = info.service.default_command
        if not cmd:
            return
        shell = os.environ.get("SHELL", "/bin/bash")
        proc = PtyProcess.spawn(
            [shell, "-l", "-c", cmd],
            cwd=info.project_path,
            env=self._child_env(),
            dimensions=(50, 200),
        )
        buf = self._buffers.setdefault(sid, deque(maxlen=BUFFER_LINES))
        buf.clear()
        now = time.monotonic()
        r = _Running(
            proc=proc,
            buffer=buf,
            decoder=codecs.getincrementaldecoder("utf-8")("replace"),
            pid=proc.pid,
            start_mono=now,
            start_epoch=time.time(),
            last_output=now,
            info=info,
        )
        self._running[sid] = r
        self._write_pid(sid, proc.pid)
        self._set_state(sid, ProcessStatus.running, pid=proc.pid, start_time=r.start_epoch)
        asyncio.get_running_loop().add_reader(proc.fd, self._readable, sid)

    def send_input(self, sid: str, text: str) -> None:
        r = self._running.get(sid)
        if r is not None:
            try:
                r.proc.write(text.encode())
            except OSError:
                pass

    def stop_step(self, sid: str) -> None:
        """Single escalation step (matches the HTTP /stop semantics)."""
        r = self._running.get(sid)
        if r is None:
            return
        sig, _ = _ESCALATION[r.next_signal]
        self._signal(r.pid, sig)
        r.next_signal = min(r.next_signal + 1, len(_ESCALATION) - 1)
        self._set_state(sid, ProcessStatus.running, pid=r.pid, start_time=r.start_epoch)

    async def stop_escalating(self, sid: str, poll: float = 5.0) -> bool:
        """SIGINT, poll; SIGTERM, poll; SIGKILL, poll. EOF on the master fd
        finalizes; we watch _running membership."""
        for idx, (sig, _) in enumerate(_ESCALATION):
            r = self._running.get(sid)
            if r is None:
                return True
            r.next_signal = min(idx + 1, len(_ESCALATION) - 1)
            self._set_state(sid, ProcessStatus.running, pid=r.pid, start_time=r.start_epoch)
            self._signal(r.pid, sig)
            for _ in range(int(poll * 10)):
                await asyncio.sleep(0.1)
                if sid not in self._running:
                    return True
        return sid not in self._running

    # ---- orphans ---------------------------------------------------------

    def scan_orphans(self) -> None:
        if self.workspace_path is None:
            return
        for sid, pid in storage.load_all_pid_files(self.workspace_path).items():
            if self._alive(pid):
                self._set_state(sid, ProcessStatus.orphaned, pid=pid)
            else:
                storage.delete_pid_file(self.workspace_path, sid)

    def kill_orphan(self, sid: str) -> None:
        st = self._states.get(sid)
        if st and st.pid is not None:
            self._signal(st.pid, signal.SIGKILL)
        self._delete_pid(sid)
        self._set_state(sid, ProcessStatus.stopped)

    # ---- internals -------------------------------------------------------

    def _child_env(self) -> dict:
        env = env_mod.build_base_env()
        key = getattr(self.secret_store, "private_key", None)
        if key:
            env["SOPS_AGE_KEY"] = key  # so the command's own `sops exec-env` can decrypt
        return env

    def _readable(self, sid: str) -> None:
        r = self._running.get(sid)
        if r is None:
            return
        try:
            data = os.read(r.proc.fd, 65536)
        except OSError:
            data = b""  # EIO on Linux when the child exits == EOF
        if not data:
            self._finalize(sid)
            return
        r.last_output = time.monotonic()
        newlines = self._feed(r, r.decoder.decode(data))
        if newlines and self.on_output:
            self.on_output(sid, newlines)

    def _feed(self, r: _Running, text: str) -> list:
        r.tail += text
        parts = r.tail.split("\n")
        r.tail = parts.pop()
        out = []
        for line in parts:
            line = self._clean_line(line)
            r.buffer.append(line)
            out.append(line)
        if len(r.tail) > 8192:
            line = self._clean_line(r.tail)
            r.buffer.append(line)
            out.append(line)
            r.tail = ""
        return out

    @staticmethod
    def _clean_line(line: str) -> str:
        # A PTY translates \n to \r\n. Nested TTYs (e.g. `docker run -t`, whose
        # container TTY adds its own \r before our PTY adds another) yield
        # \r\r\n, so strip ALL trailing CRs — not just one — before collapsing a
        # genuine in-line \r redraw (progress bars) to its final state.
        line = line.rstrip("\r")
        if "\r" in line:
            line = line.rsplit("\r", 1)[-1]
        if len(line) > 4000:
            line = line[:4000] + f" …(+{len(line) - 4000} chars)"
        return line

    def _finalize(self, sid: str) -> None:
        r = self._running.pop(sid, None)
        if r is None:
            return
        try:
            asyncio.get_running_loop().remove_reader(r.proc.fd)
        except (OSError, ValueError):
            pass
        if r.tail:
            line = self._clean_line(r.tail)
            r.buffer.append(line)
            if self.on_output:
                self.on_output(sid, [line])
        try:
            r.proc.close(force=False)
        except Exception:
            pass
        self._delete_pid(sid)
        self._set_state(sid, ProcessStatus.stopped)

    def _signal(self, pid: int, sig: int) -> None:
        try:
            os.killpg(pid, sig)  # PtyProcess setsid()s the child: pgid == pid
        except ProcessLookupError:
            pass
        except OSError:
            try:
                os.kill(pid, sig)
            except OSError:
                pass

    def _set_state(self, sid: str, status: ProcessStatus, pid: int | None = None, start_time=None) -> None:
        next_sig = StopSignal.sigint
        r = self._running.get(sid)
        if r is not None:
            next_sig = _ESCALATION[r.next_signal][1]
        state = ServiceState(service_id=sid, status=status, pid=pid, start_time=start_time, next_signal=next_sig)
        self._states[sid] = state
        if self.on_state:
            self.on_state(state)

    # ---- pid files -------------------------------------------------------

    def _write_pid(self, sid: str, pid: int) -> None:
        if self.workspace_path:
            storage.write_pid_file(self.workspace_path, sid, pid)

    def _delete_pid(self, sid: str) -> None:
        if self.workspace_path:
            storage.delete_pid_file(self.workspace_path, sid)

    @staticmethod
    def _alive(pid: int) -> bool:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        return True
