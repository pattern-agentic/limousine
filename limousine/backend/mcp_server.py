"""FastMCP server (streamable-HTTP) driving the shared Backend. Runs as a task
on the TUI's event loop — the seam the spike proved. Port of the service/project
tool subset of lib/server/mcp.dart."""

from __future__ import annotations

import uvicorn
from mcp.server.fastmcp import FastMCP

from ..core.dtos import GitStatus, ProcessStatus
from . import project_status
from .backend import LocalBackend


def build_mcp(backend: LocalBackend, port: int, host: str = "127.0.0.1") -> FastMCP:
    mcp = FastMCP("limousine")
    mcp.settings.host = host
    mcp.settings.port = port

    @mcp.tool()
    def list_services() -> list[dict]:
        """Every service with status, pid, and available command names."""
        states = backend.service_states()
        out = []
        for s in backend.list_services():
            st = states.get(s.id)
            out.append(
                {
                    "id": s.id,
                    "project": s.project_name,
                    "module": s.module_name,
                    "status": (st.status if st else ProcessStatus.stopped).value,
                    "pid": st.pid if st else None,
                    "commands": list(s.service.commands),
                }
            )
        return out

    @mcp.tool()
    def start_service(service_id: str, command: str | None = None) -> dict:
        """Start a service. `command` selects a named command (default: run/start)."""
        if backend.find_service(service_id) is None:
            return {"ok": False, "error": f"unknown service {service_id}"}
        if backend.service_states().get(service_id) and backend.service_states()[service_id].status == ProcessStatus.running:
            return {"ok": False, "error": "already running"}
        backend.start_service(service_id, command)
        return {"ok": True}

    @mcp.tool()
    async def stop_service(service_id: str) -> dict:
        """Stop a service with escalating SIGINT -> SIGTERM -> SIGKILL."""
        if backend.find_service(service_id) is None:
            return {"ok": False, "error": f"unknown service {service_id}"}
        stopped = await backend.stop_service(service_id)
        return {"ok": stopped}

    @mcp.tool()
    def get_service_logs(service_id: str, lines: int = 100) -> dict:
        """Last `lines` lines of a service's output buffer."""
        if backend.find_service(service_id) is None:
            return {"error": f"unknown service {service_id}"}
        return {"lines": list(backend.buffer(service_id))[-lines:]}

    @mcp.tool()
    def get_project_info(project_name: str | None = None) -> list[dict]:
        """Paths + agent guide + module/service tree, for one or all projects."""
        names = [project_name] if project_name else list(backend.projects)
        return [info for n in names if (info := backend.project_info(n)) is not None]

    @mcp.tool()
    async def get_git_status(project_name: str | None = None):
        """Local git snapshot (branch/sha/dirty/behind + config drift)."""
        if project_name:
            loaded = backend.projects.get(project_name)
            if loaded is None:
                return {"error": f"unknown project {project_name}"}
            dto = await project_status.read(project_name, loaded)
            return project_status.to_agent_summary(dto, loaded)
        return await backend.git_status_all()

    @mcp.tool()
    async def git_fetch(project_name: str | None = None):
        """`git fetch --prune` (one project or all cloned) then refreshed status."""
        if project_name:
            loaded = backend.projects.get(project_name)
            if loaded is None:
                return {"error": f"unknown project {project_name}"}
            dto = await project_status.refresh(project_name, loaded)
            return project_status.to_agent_summary(dto, loaded)
        results = []
        for name, loaded in backend.projects.items():
            if loaded.exists_on_disk:
                dto = await project_status.refresh(name, loaded)
                results.append(project_status.to_agent_summary(dto, loaded))
            else:
                results.append(
                    project_status.to_agent_summary(GitStatus(project=name, exists=False), loaded)
                )
        return results

    return mcp


def _bearer_guard(app, token: str):
    """Minimal ASGI middleware: require `Authorization: Bearer <token>` on HTTP
    requests; pass lifespan/websocket scopes through untouched."""

    async def guarded(scope, receive, send):
        if scope.get("type") == "http":
            headers = dict(scope.get("headers") or [])
            if headers.get(b"authorization", b"").decode() != f"Bearer {token}":
                await send({"type": "http.response.start", "status": 401,
                            "headers": [(b"content-type", b"text/plain")]})
                await send({"type": "http.response.body", "body": b"unauthorized"})
                return
        await app(scope, receive, send)

    return guarded


def make_server(mcp: FastMCP, token: str | None = None) -> uvicorn.Server:
    """Build (don't start) a uvicorn server for the MCP app. Caller awaits
    server.serve() on its own loop and flips should_exit to stop."""
    app = mcp.streamable_http_app()
    if token:
        app = _bearer_guard(app, token)
    config = uvicorn.Config(app, host=mcp.settings.host, port=mcp.settings.port,
                            log_level="warning", lifespan="on")
    server = uvicorn.Server(config)
    server.install_signal_handlers = lambda: None
    return server
