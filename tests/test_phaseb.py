import json

import pytest

from limousine.backend.backend import LocalBackend


def _make_workspace(tmp_path, with_secrets=False):
    proj = tmp_path / "proj"
    proj.mkdir()
    config = {"active-env-file": ".env", "source-env-file": ".env.example"}
    if with_secrets:
        config["active-secrets-env-file"] = "secrets.env"
        config["source-secrets-file"] = "secrets.env.example"
    proj.joinpath("limousine.proj").write_text(
        json.dumps({"modules": {"m": {"services": {"svc": {"commands": {"start": "true"}}}, "config": config}}})
    )
    proj.joinpath(".env").write_text("A=1\n")
    proj.joinpath(".env.example").write_text("A=1\nB=2\n")
    if with_secrets:
        proj.joinpath("secrets.env.example").write_text("TOKEN=changeme\n")
        proj.joinpath("secrets.env").write_text("TOKEN=ENC[...]\n")  # dummy; locked store won't decrypt
    wksp = tmp_path / "w.wksp"
    wksp.write_text(json.dumps({"name": "W", "projects": {"p": {"path-on-disk": "proj"}}}))
    return str(wksp), proj


async def test_env_get_and_save(tmp_path):
    wksp, proj = _make_workspace(tmp_path)
    b = LocalBackend()
    await b.open_workspace(wksp)
    cmp = await b.get_env("m/svc")
    assert cmp.active_content == {"A": "1"}
    assert cmp.missing_in_active == {"B"}
    b.save_env("m/svc", {"A": "9", "B": "2"})
    assert proj.joinpath(".env").read_text().split() == ["A=9", "B=2"]
    assert (await b.get_env("m/svc")).missing_in_active == set()


async def test_secrets_keys_locked(tmp_path, monkeypatch):
    monkeypatch.delenv("LIMOUSINE_AGE_KEY", raising=False)
    wksp, _ = _make_workspace(tmp_path, with_secrets=True)
    b = LocalBackend()
    await b.open_workspace(wksp)
    keys = await b.secrets_keys("m/svc")
    assert keys.active_exists is True
    assert keys.source_content == {"TOKEN": "changeme"}
    assert keys.read_error == "secret store locked"


async def test_update_settings_persists(tmp_path):
    wksp, _ = _make_workspace(tmp_path)
    b = LocalBackend()
    await b.open_workspace(wksp)
    b.update_settings(mcp_enabled=False, mcp_port=7777, git_ssh_key_path="/k")
    b2 = LocalBackend()
    await b2.open_workspace(wksp)
    assert b2.workspace.mcp_config.enabled is False
    assert b2.workspace.mcp_config.port == 7777
    assert b2.workspace.git_ssh_key_path == "/k"


async def test_secret_status_callback(tmp_path, monkeypatch):
    from limousine.backend.secret_store import SecretStoreStatus

    monkeypatch.delenv("LIMOUSINE_AGE_KEY", raising=False)
    wksp, _ = _make_workspace(tmp_path)
    b = LocalBackend()
    seen = []
    b.on_secret_status = lambda s: seen.append(s)
    await b.open_workspace(wksp)
    assert SecretStoreStatus.MISSING_KEY in seen  # status pushed via the callback


def test_recents_dedup_and_order(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    b = LocalBackend()
    b.add_recent("/a.wksp")
    b.add_recent("/b.wksp")
    b.add_recent("/a.wksp")  # re-add moves to front, no dupe
    assert b.recent_workspaces() == ["/a.wksp", "/b.wksp"]
    b.remove_recent("/a.wksp")
    assert b.recent_workspaces() == ["/b.wksp"]
