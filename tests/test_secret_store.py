"""Live sops+age integration — skipped if the binaries aren't installed."""

import json
import shutil
import subprocess

import pytest

from limousine.backend.backend import LocalBackend
from limousine.backend.secret_store import SecretStoreStatus

pytestmark = pytest.mark.skipif(
    not all(shutil.which(b) for b in ("age", "age-keygen", "sops")),
    reason="age/sops not installed",
)


def _gen_key() -> str:
    out = subprocess.run(["age-keygen"], capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        if line.startswith("AGE-SECRET-KEY"):
            return line.strip()
    raise RuntimeError("no key in age-keygen output")


def _ws(tmp_path) -> tuple[str, "Path"]:
    proj = tmp_path / "proj"
    proj.mkdir()
    proj.joinpath("limousine.proj").write_text(
        json.dumps({"modules": {"m": {"services": {"svc": {"commands": {"start": "true"}}},
                                      "config": {"active-secrets-env-file": "secrets.env"}}}})
    )
    wksp = tmp_path / "w.wksp"
    wksp.write_text(json.dumps({"name": "W", "projects": {"p": {"path-on-disk": "proj"}}}))
    return str(wksp), proj


async def test_stamp_lifecycle_and_secret_roundtrip(tmp_path, monkeypatch):
    key = _gen_key()
    monkeypatch.setenv("LIMOUSINE_AGE_KEY", key)
    wksp, proj = _ws(tmp_path)

    b = LocalBackend()
    await b.open_workspace(wksp)
    assert b.secret_store_status() == SecretStoreStatus.NEW_STAMP
    assert (tmp_path / ".limousine" / "secret-store-stamp").exists()

    # same key on reopen → VERIFIED
    b2 = LocalBackend()
    await b2.open_workspace(wksp)
    assert b2.secret_store_status() == SecretStoreStatus.VERIFIED

    # encrypt → decrypt round-trip through real sops
    await b2.save_secrets("m/svc", {"TOKEN": "s3cr3t", "NUM": "42"})
    encrypted = proj.joinpath("secrets.env").read_text()
    assert "ENC[" in encrypted  # values actually encrypted on disk
    assert "s3cr3t" not in encrypted
    assert await b2.get_secrets("m/svc") == {"TOKEN": "s3cr3t", "NUM": "42"}

    # wrong key → MISMATCH (fatal contract)
    monkeypatch.setenv("LIMOUSINE_AGE_KEY", _gen_key())
    b3 = LocalBackend()
    await b3.open_workspace(wksp)
    assert b3.secret_store_status() == SecretStoreStatus.MISMATCH


async def test_runtime_unlock(tmp_path, monkeypatch):
    key = _gen_key()
    monkeypatch.setenv("LIMOUSINE_AGE_KEY", key)
    wksp, _ = _ws(tmp_path)
    b = LocalBackend()
    await b.open_workspace(wksp)  # creates the stamp

    # reopen with no key → locked
    monkeypatch.delenv("LIMOUSINE_AGE_KEY")
    b2 = LocalBackend()
    await b2.open_workspace(wksp)
    assert b2.secret_store_status() == SecretStoreStatus.MISSING_KEY

    # paste the key at runtime → VERIFIED
    assert await b2.unlock_secrets(key) == SecretStoreStatus.VERIFIED
