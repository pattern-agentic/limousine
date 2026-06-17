"""Long-lived daemon: owns a LocalBackend (PTYs, secret store, MCP) and serves
TUI clients over a unix socket. Services survive client disconnect/crash because
the daemon — not the TUI — holds the PTY master fds. MCP runs here so agents
reach it even with no TUI attached."""

from __future__ import annotations

import asyncio
import inspect
import os

from . import wire
from .backend import LocalBackend
from .mcp_server import build_mcp, make_server


class Daemon:
    def __init__(self, backend: LocalBackend, socket_path: str, mcp_allowed: bool = True,
                 mcp_port_override: int | None = None, mcp_host: str = "127.0.0.1"):
        self.backend = backend
        self.socket_path = socket_path
        self.mcp_allowed = mcp_allowed
        self.mcp_port_override = mcp_port_override
        self.mcp_host = mcp_host
        self._clients: set = set()
        self._mcp_server = None
        self._tail_state: dict[str, tuple] = {}
        self._shutdown_event = asyncio.Event()
        backend.on_state = self._push_state
        backend.on_output = self._push_output
        backend.on_workspace_change = self._push_wschange
        backend.on_secret_status = self._push_secret_status
        self._mcp_cfg = None

    async def start(self):
        try:
            os.unlink(self.socket_path)  # clear a stale socket
        except OSError:
            pass
        self._server = await asyncio.start_unix_server(self._handle, path=self.socket_path)
        self._start_mcp()
        self._tail_task = asyncio.ensure_future(self._tail_loop())
        return self._server

    async def serve(self) -> None:
        # start_unix_server is already accepting; just stay alive until a
        # shutdown_daemon RPC (or Ctrl-C) unblocks us, then clean up.
        await self.start()
        await self._shutdown_event.wait()
        await self.stop()

    async def stop(self) -> None:
        if getattr(self, "_tail_task", None):
            self._tail_task.cancel()
        if self._mcp_server is not None:
            self._mcp_server.should_exit = True
            if getattr(self, "_mcp_task", None):
                await self._mcp_task
        if getattr(self, "_server", None):
            self._server.close()
        try:
            os.unlink(self.socket_path)
        except OSError:
            pass

    async def _shutdown(self) -> None:
        """Stop every running service, then unblock serve() so the daemon exits."""
        running = [sid for sid, st in self.backend.service_states().items()
                   if st.status.value == "running"]
        if running:
            await asyncio.gather(*(self.backend.stop_service(sid) for sid in running),
                                 return_exceptions=True)
        self._shutdown_event.set()

    # ---- client connections ---------------------------------------------

    async def _handle(self, reader, writer) -> None:
        self._clients.add(writer)
        try:
            while True:
                msg = await wire.read_frame(reader)
                if msg is None:
                    break
                resp = await self._dispatch(msg)
                wire.write_frame(writer, resp)
                await writer.drain()
        finally:
            self._clients.discard(writer)
            try:
                writer.close()
            except Exception:
                pass

    async def _dispatch(self, msg: dict) -> dict:
        mid = msg.get("id")
        method = msg.get("method")
        args = msg.get("args", [])
        try:
            if method == "snapshot":
                return {"id": mid, "result": self._snapshot()}
            if method == "shutdown_daemon":
                asyncio.ensure_future(self._shutdown())  # after this reply flushes
                return {"id": mid, "result": True}
            fn = getattr(self.backend, method)
            r = fn(*args)
            if inspect.isawaitable(r):
                r = await r
            return {"id": mid, "result": wire.to_wire(r)}
        except Exception as e:
            return {"id": mid, "error": str(e)}

    def _snapshot(self) -> dict:
        b = self.backend
        return {
            "workspace": wire.to_wire(b.workspace),
            "projects": {k: wire.to_wire(v) for k, v in b.projects.items()},
            "services": [wire.to_wire(s) for s in b.list_services()],
            "states": {k: wire.to_wire(v) for k, v in b.service_states().items()},
            "secret_status": b.secret_store_status().value,
        }

    # ---- pushes ----------------------------------------------------------

    def _broadcast(self, msg: dict) -> None:
        for w in list(self._clients):
            wire.write_frame(w, msg)

    def _push_state(self, state) -> None:
        self._broadcast({"type": "state", "state": wire.to_wire(state)})

    def _push_output(self, sid: str, lines: list) -> None:
        self._broadcast({"type": "output", "sid": sid, "lines": lines})

    def _push_wschange(self) -> None:
        self._broadcast({"type": "workspace-change"})
        self._restart_mcp_if_changed()  # a settings edit may have changed MCP config

    def _push_secret_status(self, status) -> None:
        self._broadcast({"type": "secret-status", "status": status.value})

    async def _tail_loop(self) -> None:
        # the partial line / waiting-for-input state has no event; poll the
        # in-process backend cheaply and push deltas (covers a prompt that
        # prints no newline, which never fires on_output).
        while True:
            await asyncio.sleep(0.05)
            for sid, st in self.backend.service_states().items():
                if st.status.value != "running":
                    cur = ("", False)
                else:
                    cur = (self.backend.tail(sid), self.backend.awaiting_input(sid))
                if self._tail_state.get(sid) != cur:
                    self._tail_state[sid] = cur
                    self._broadcast({"type": "tail", "sid": sid, "tail": cur[0], "awaiting": cur[1]})

    # ---- MCP -------------------------------------------------------------

    def _mcp_config(self) -> tuple:
        mcp = self.backend.workspace.mcp_config if self.backend.workspace else None
        return (mcp.enabled, mcp.port, mcp.token) if mcp else (True, 6891, None)

    def _start_mcp(self) -> None:
        self._mcp_cfg = self._mcp_config()
        enabled, port, token = self._mcp_cfg
        if not (self.mcp_allowed and enabled):
            self._mcp_server = None
            return
        self._mcp_server = make_server(
            build_mcp(self.backend, self.mcp_port_override or port, host=self.mcp_host), token=token
        )
        self._mcp_task = asyncio.ensure_future(self._mcp_server.serve())

    def _restart_mcp_if_changed(self) -> None:
        if self._mcp_config() == self._mcp_cfg:
            return
        if self._mcp_server is not None:
            self._mcp_server.should_exit = True
            self._mcp_server = None
        self._start_mcp()
