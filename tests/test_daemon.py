"""Daemon ↔ DaemonBackend over a unix socket: RPC, push-fed mirror, and the
load-bearing property — services survive a client disconnect/reconnect."""

import asyncio
import json
import socket
from pathlib import Path

from limousine.backend.backend import LocalBackend
from limousine.backend.daemon import Daemon
from limousine.backend.daemon_backend import DaemonBackend
from limousine.core.dtos import ProcessStatus


def _free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


async def _port_open(port: int, tries: int = 60) -> bool:
    for _ in range(tries):
        try:
            r, w = await asyncio.open_connection("127.0.0.1", port)
            w.close()
            return True
        except OSError:
            await asyncio.sleep(0.05)
    return False


def _ticker_workspace(tmp_path) -> str:
    proj = tmp_path / "proj"
    proj.mkdir()
    proj.joinpath("limousine.proj").write_text(
        json.dumps(
            {"modules": {"demo": {"services": {
                "ticker": {"commands": {"start": "i=0; while true; do echo tick $i; i=$((i+1)); sleep 1; done"}},
                "prompt": {"commands": {"start": "printf 'Q? '; read a; echo got $a"}},
            }}}}
        )
    )
    wksp = tmp_path / "w.wksp"
    wksp.write_text(json.dumps({"name": "D", "projects": {"demo": {"path-on-disk": "proj"}}}))
    return str(wksp)


async def test_daemon_rpc_pushes_and_survival(tmp_path):
    backend = LocalBackend()
    await backend.open_workspace(_ticker_workspace(tmp_path))
    socket = str(tmp_path / "d.sock")
    daemon = Daemon(backend, socket, mcp_allowed=False)
    await daemon.start()
    try:
        client = DaemonBackend(socket)
        await client.connect()

        # snapshot mirrored
        assert {s.id for s in client.list_services()} == {"demo/ticker", "demo/prompt"}
        assert client.workspace.name == "D"

        # fire-and-forget start → state + output pushes update the client mirror
        client.start_service("demo/ticker")
        await asyncio.sleep(1.6)
        assert client.service_states()["demo/ticker"].status == ProcessStatus.running
        assert any(l.startswith("tick") for l in client.buffer("demo/ticker"))

        # SURVIVAL: drop the client; the daemon holds the PTY, so a fresh client
        # reconnecting still sees the service running with no gap.
        client._writer.close()
        await asyncio.sleep(0.2)
        client2 = DaemonBackend(socket)
        await client2.connect()
        assert client2.service_states()["demo/ticker"].status == ProcessStatus.running

        # async RPC stop works from the new client
        assert await client2.stop_service("demo/ticker") is True
        assert client2.service_states()["demo/ticker"].status == ProcessStatus.stopped
    finally:
        await daemon.stop()


async def test_daemon_stdin_and_tail_pushes(tmp_path):
    backend = LocalBackend()
    await backend.open_workspace(_ticker_workspace(tmp_path))
    socket = str(tmp_path / "d.sock")
    daemon = Daemon(backend, socket, mcp_allowed=False)
    await daemon.start()
    try:
        client = DaemonBackend(socket)
        await client.connect()
        client.start_service("demo/prompt")
        # the tail-poll push delivers the no-newline prompt + waiting flag; poll for it
        async def waiting():
            for _ in range(80):
                if client.tail("demo/prompt").startswith("Q?") and client.awaiting_input("demo/prompt"):
                    return True
                await asyncio.sleep(0.1)
            return False

        assert await waiting()
        client.send_input("demo/prompt", "hi\n")
        for _ in range(60):
            if any("got hi" in l for l in client.buffer("demo/prompt")):
                break
            await asyncio.sleep(0.1)
        assert any("got hi" in l for l in client.buffer("demo/prompt"))
    finally:
        await daemon.stop()


async def test_daemon_restarts_mcp_on_settings_change(tmp_path):
    p1, p2 = _free_port(), _free_port()
    proj = tmp_path / "proj"
    proj.mkdir()
    proj.joinpath("limousine.proj").write_text(
        json.dumps({"modules": {"m": {"services": {"s": {"commands": {"start": "true"}}}}}})
    )
    wksp = tmp_path / "w.wksp"
    wksp.write_text(json.dumps({"name": "D", "projects": {"m": {"path-on-disk": "proj"}},
                                "mcp": {"enabled": True, "port": p1}}))
    backend = LocalBackend()
    await backend.open_workspace(str(wksp))
    daemon = Daemon(backend, str(tmp_path / "d.sock"), mcp_allowed=True)
    await daemon.start()
    try:
        assert await _port_open(p1)  # daemon's MCP came up on the configured port
        # a settings save (port change) reaches the daemon → MCP restarts on the new port
        backend.apply_settings(mcp_enabled=True, mcp_port=p2, git_ssh_key_path=None)
        assert await _port_open(p2)
        assert daemon._mcp_cfg[1] == p2
    finally:
        await daemon.stop()
