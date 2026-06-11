from pathlib import Path

import pytest

from limousine.backend import git

REPO = Path(__file__).resolve().parents[2]  # the limousine git repo root


@pytest.mark.skipif(not (REPO / ".git").exists(), reason="not a git checkout")
async def test_status_reads_real_repo():
    s = await git.status("limousine", str(REPO))
    assert s.exists is True
    assert s.branch and s.short_sha
    assert s.error is None


async def test_status_missing_repo(tmp_path):
    s = await git.status("nope", str(tmp_path))
    assert s.exists is False


def test_normalize_url_rewrites_known_hosts():
    out = git.normalize_url("https://github.com/o/r.git")
    assert out.startswith("ssh://git@github.com/") and out.endswith("r.git")


async def test_clone_streams_and_reports_failure(tmp_path):
    lines = []
    res = await git.clone("file:///definitely-nonexistent-repo-xyz.git", str(tmp_path / "t"), on_line=lines.append)
    assert res.success is False
    assert lines  # streamed line-by-line
    assert any("not appear to be a git repository" in l or "Could not read" in l for l in lines)


def test_lock_file_classification():
    assert git._is_lock_file("uv.lock") is True
    assert git._is_lock_file("sub/dir/package-lock.json") is True
    assert git._is_lock_file("src/main.py") is False
