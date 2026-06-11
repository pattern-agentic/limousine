"""End-to-end: a real MCP client over HTTP drives the same Backend the TUI uses."""

import asyncio
import json
from pathlib import Path

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

from limousine.backend.backend import LocalBackend
from limousine.backend.mcp_server import build_mcp, make_server

import socket

import pytest

DEMO = str(Path(__file__).parent.parent / "demo" / "demo.wksp")


def _free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


async def _shutdown(server, task) -> None:
    server.should_exit = True
    await task


def _parse(res):
    sc = res.structuredContent
    if isinstance(sc, dict) and list(sc.keys()) == ["result"]:
        return sc["result"]
    if sc is not None:
        return sc
    return json.loads(res.content[0].text)


async def test_mcp_drives_shared_backend():
    backend = LocalBackend()
    await backend.open_workspace(DEMO)
    port = _free_port()
    server = make_server(build_mcp(backend, port))
    task = asyncio.ensure_future(server.serve())
    try:
        for _ in range(100):
            if server.started:
                break
            await asyncio.sleep(0.05)
        assert server.started

        async with streamablehttp_client(f"http://127.0.0.1:{port}/mcp") as (r, w, _):
            async with ClientSession(r, w) as s:
                await s.initialize()
                names = {t.name for t in (await s.list_tools()).tools}
                assert {"list_services", "start_service", "stop_service", "get_service_logs",
                        "get_project_info", "get_git_status", "git_fetch"} <= names

                svcs = _parse(await s.call_tool("list_services", {}))
                assert {x["id"] for x in svcs} == {"demo/ticker", "demo/prompt"}

                assert _parse(await s.call_tool("start_service", {"service_id": "demo/ticker"}))["ok"]
                await asyncio.sleep(1.5)
                # shared backend: the UI-facing manager sees the MCP-started service
                assert backend.service_states()["demo/ticker"].status.value == "running"
                logs = _parse(await s.call_tool("get_service_logs", {"service_id": "demo/ticker", "lines": 3}))
                assert any(l.startswith("tick ") for l in logs["lines"])
                assert _parse(await s.call_tool("stop_service", {"service_id": "demo/ticker"}))["ok"]
                info = _parse(await s.call_tool("get_project_info", {}))
                assert info[0]["name"] == "demo"
    finally:
        await _shutdown(server, task)


async def test_mcp_token_auth():
    backend = LocalBackend()
    await backend.open_workspace(DEMO)
    port = _free_port()
    server = make_server(build_mcp(backend, port), token="s3cr3t")
    task = asyncio.ensure_future(server.serve())
    url = f"http://127.0.0.1:{port}/mcp"
    try:
        for _ in range(100):
            if server.started:
                break
            await asyncio.sleep(0.05)
        # no token → rejected
        with pytest.raises(Exception):
            async with streamablehttp_client(url) as (r, w, _):
                async with ClientSession(r, w) as s:
                    await s.initialize()
        # correct token → works
        async with streamablehttp_client(url, headers={"Authorization": "Bearer s3cr3t"}) as (r, w, _):
            async with ClientSession(r, w) as s:
                await s.initialize()
                assert (await s.list_tools()).tools
    finally:
        await _shutdown(server, task)
