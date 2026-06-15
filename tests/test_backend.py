import asyncio
import json
from pathlib import Path

import pytest

from limousine.backend.backend import BackendError, LocalBackend
from limousine.core.dtos import ProcessStatus

DEMO = str(Path(__file__).parent.parent / "demo" / "demo.wksp")


async def _open() -> LocalBackend:
    b = LocalBackend()
    await b.open_workspace(DEMO)
    return b


async def _poll(pred, tries: int = 80, delay: float = 0.1) -> bool:
    for _ in range(tries):
        if pred():
            return True
        await asyncio.sleep(delay)
    return pred()


async def _stop_all(b: LocalBackend) -> None:
    for s in b.list_services():
        st = b.service_states().get(s.id)
        if st and st.status == ProcessStatus.running:
            await b.stop_service(s.id)


async def test_open_lists_services():
    b = await _open()
    try:
        ids = sorted(s.id for s in b.list_services())
        assert ids == ["demo/prompt", "demo/ticker"]
    finally:
        await _stop_all(b)


async def test_service_lifecycle_and_logs():
    b = await _open()
    try:
        b.start_service("demo/ticker")
        assert b.service_states()["demo/ticker"].status == ProcessStatus.running
        await asyncio.sleep(1.6)
        assert any(line.startswith("tick ") for line in b.buffer("demo/ticker"))
        assert await b.stop_service("demo/ticker") is True
        assert b.service_states()["demo/ticker"].status == ProcessStatus.stopped
    finally:
        await _stop_all(b)


async def test_stdin_and_waiting():
    b = await _open()
    try:
        b.start_service("demo/prompt")
        # poll until the prompt shows AND has gone idle (the waiting heuristic)
        assert await _poll(lambda: b.tail("demo/prompt").startswith("Continue?") and b.awaiting_input("demo/prompt"))
        b.send_input("demo/prompt", "y\n")
        assert await _poll(lambda: any("you answered: [y]" in l for l in b.buffer("demo/prompt")))
    finally:
        await _stop_all(b)


async def test_reload_keeps_running_service_as_ghost(tmp_path):
    proj = tmp_path / "proj"
    proj.mkdir()
    pf = proj / "limousine.proj"
    pf.write_text(json.dumps({"modules": {"m": {"services": {
        "keep": {"commands": {"start": "sleep 30"}},
        "gone": {"commands": {"start": "sleep 30"}}}}}}))
    (tmp_path / "w.wksp").write_text(json.dumps({"name": "W", "projects": {"p": {"path-on-disk": "proj"}}}))
    b = LocalBackend()
    await b.open_workspace(str(tmp_path / "w.wksp"))
    try:
        b.start_service("m/gone")
        assert await _poll(lambda: b.service_states().get("m/gone")
                           and b.service_states()["m/gone"].status == ProcessStatus.running)
        # drop 'gone' from the definition, reload — must NOT raise, ghost stays
        pf.write_text(json.dumps({"modules": {"m": {"services": {"keep": {"commands": {"start": "sleep 30"}}}}}}))
        await b.reload_project("p")
        assert {s.id for s in b.list_services()} == {"m/keep", "m/gone"}
        assert b.service_states()["m/gone"].status == ProcessStatus.running
        # once stopped + reloaded, the ghost is gone
        await b.stop_service("m/gone")
        await b.reload_project("p")
        assert {s.id for s in b.list_services()} == {"m/keep"}
    finally:
        await _stop_all(b)


def test_clean_line_handles_nested_tty_cr():
    from limousine.backend.manager import ServiceManager as M

    assert M._clean_line("ready-to-accept\r\r") == "ready-to-accept"  # docker run -t double-CR
    assert M._clean_line("plain\r") == "plain"                        # normal CRLF
    assert M._clean_line("a\rb") == "b"                               # in-line progress redraw


async def test_start_named_command(tmp_path):
    proj = tmp_path / "proj"
    proj.mkdir()
    proj.joinpath("limousine.proj").write_text(
        json.dumps({"modules": {"m": {"services": {"svc": {"commands": {
            "start": "echo from-start; sleep 5",
            "other": "echo from-other; sleep 5",
        }}}}}})
    )
    wksp = tmp_path / "w.wksp"
    wksp.write_text(json.dumps({"name": "W", "projects": {"p": {"path-on-disk": "proj"}}}))
    b = LocalBackend()
    await b.open_workspace(str(wksp))
    try:
        b.start_service("m/svc", "other")  # not the default
        await asyncio.sleep(1.0)
        lines = list(b.buffer("m/svc"))
        assert any("from-other" in l for l in lines)
        assert not any("from-start" in l for l in lines)
    finally:
        await _stop_all(b)


async def test_start_raw_command(tmp_path):
    proj = tmp_path / "proj"
    proj.mkdir()
    proj.joinpath("limousine.proj").write_text(
        json.dumps({"modules": {"m": {"services": {"svc": {"commands": {"start": "echo ORIG; sleep 30"}}}}}})
    )
    (tmp_path / "w.wksp").write_text(json.dumps({"name": "W", "projects": {"p": {"path-on-disk": "proj"}}}))
    b = LocalBackend()
    await b.open_workspace(str(tmp_path / "w.wksp"))
    try:
        b.start_service("m/svc", raw="echo RAWRUN; sleep 30")  # a one-off edited command
        assert await _poll(lambda: any("RAWRUN" in l for l in b.buffer("m/svc")))
        assert not any("ORIG" in l for l in b.buffer("m/svc"))  # the named command didn't run
    finally:
        await _stop_all(b)


async def test_project_info():
    b = await _open()
    try:
        info = b.project_info("demo")
        assert info["name"] == "demo" and info["existsOnDisk"] is True
        mods = {m["name"]: m for m in info["modules"]}
        assert "demo" in mods
        assert {s["name"] for s in mods["demo"]["services"]} == {"ticker", "prompt"}
    finally:
        await _stop_all(b)
