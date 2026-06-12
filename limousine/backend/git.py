"""Git plumbing — port of lib/server/git.dart. Local-only status(), networked
refresh()/clone(), and lock-file-aware pull_ff_only(). Every git invocation has
a 30s timeout so a wedged ssh-agent prompt can't hang the process."""

from __future__ import annotations

import asyncio
import logging
import os
from dataclasses import dataclass
from datetime import datetime
from urllib.parse import urlsplit

from ..core.dtos import GitStatus, DirtyFile, GitPullResult

_log = logging.getLogger("git")

_TIMEOUT = 30.0
_CLONE_TIMEOUT = 600.0  # clones can be slow / large; per-read for the streaming path

# Hosts whose URLs we coerce to `ssh://git@<host>/<path>` regardless of the
# scheme used in the workspace file. SSH is the only auth path we support —
# whoever starts the server brings the keys / agent.
_SSH_HOSTS = {"github.com", "gitlab.com", "bitbucket.org"}

# Lock files: basename-matched. Same set across ecosystems.
_LOCK_FILE_NAMES = {
    "uv.lock",
    "package-lock.json",
    "yarn.lock",
    "pnpm-lock.yaml",
    "Cargo.lock",
    "Pipfile.lock",
    "poetry.lock",
    "composer.lock",
    "Gemfile.lock",
}

# BatchMode + ConnectTimeout: never prompt the terminal for credentials, return
# a real error fast.
_SSH_OPTS = "-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"

_GIT_ENV = {
    "GIT_TERMINAL_PROMPT": "0",
    "SSH_ASKPASS": "/bin/false",
    "SSH_ASKPASS_REQUIRE": "never",
}


@dataclass
class GitCloneResult:
    success: bool
    stdout: str
    stderr: str
    exit_code: int


@dataclass
class _ProcResult:
    exit_code: int
    stdout: str
    stderr: str


def normalize_url(url: str) -> str:
    """Normalize a workspace URL into something a stock `git clone` will accept.
    - Strips the pip-style `git+` prefix.
    - Rewrites `https://<host>/…` to `ssh://git@<host>/…` for known providers.
    - Adds the `git@` user when the SSH form is missing it."""
    u = url[4:] if url.startswith("git+") else url
    try:
        uri = urlsplit(u)
    except ValueError:
        return u

    if uri.scheme == "https" and uri.hostname in _SSH_HOSTS:
        return f"ssh://git@{uri.hostname}{uri.path}"
    if uri.scheme == "ssh" and not uri.username and uri.hostname in _SSH_HOSTS:
        return f"ssh://git@{uri.hostname}{uri.path}"
    return u


async def _run(args: list[str], cwd: str, timeout: float = _TIMEOUT) -> _ProcResult:
    """Run `git <args>` in cwd, return result. Captures stderr for diagnostics.
    Times out after 30s so a wedged ssh-agent prompt can't hang the server."""
    proc = await asyncio.create_subprocess_exec(
        "git",
        "-c",
        "core.askpass=",
        "-c",
        f"core.sshCommand=ssh {_SSH_OPTS}",
        *args,
        cwd=cwd,
        env={**os.environ, **_GIT_ENV},
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        raise
    return _ProcResult(
        proc.returncode if proc.returncode is not None else -1,
        out.decode(errors="replace"),
        err.decode(errors="replace"),
    )


async def _rescue_partial_target(target_path: str) -> str | None:
    """If target_path exists but contains only a `.git/` (or is empty), move it
    to `<target_path>.failed-<ISO timestamp>` so the next clone has a clean
    slate. Backup keeps anything `git fetch` may have salvaged. Real content
    (non-`.git` entries) is never touched."""
    if not os.path.isdir(target_path):
        return None

    for entry in os.listdir(target_path):
        if entry != ".git":
            # Real content — leave it alone. Caller decides what to do.
            return None

    timestamp = datetime.now().isoformat().replace(":", "-").split(".")[0]
    backup = f"{target_path}.failed-{timestamp}"
    _log.info("Moving partial clone target %s → %s", target_path, backup)
    os.rename(target_path, backup)
    return backup


async def clone(
    repo_url: str,
    target_path: str,
    ssh_key_path: str | None = None,
    on_line=None,
) -> GitCloneResult:
    """Clone repo_url into target_path. Always normalizes to SSH for known
    providers (see normalize_url). Optionally uses a specific SSH key. When
    `on_line` is given, output is streamed line-by-line to it (for a live log)."""
    rescued = await _rescue_partial_target(target_path)
    if rescued is not None:
        _log.info("Previous partial clone preserved at %s", rescued)
    url = normalize_url(repo_url)

    args: list[str] = []
    # Belt-and-suspenders: never prompt the terminal for credentials. If auth
    # fails we want a clean error in the snackbar, not a hung server.
    args += ["-c", "core.askpass="]
    # Force BatchMode + a short ConnectTimeout so ssh never tries to
    # interactively prompt for a passphrase (would deadlock the server) and
    # returns a real error if the agent isn't reachable.
    if ssh_key_path:
        args += [
            "-c",
            f"core.sshCommand=ssh -i {ssh_key_path} -o IdentitiesOnly=yes {_SSH_OPTS}",
        ]
    else:
        args += ["-c", f"core.sshCommand=ssh {_SSH_OPTS}"]
    args += ["clone", "--progress", url, target_path]

    _log.info("git %s", " ".join(args))
    if on_line is None:
        proc = await asyncio.create_subprocess_exec(
            "git", *args, env={**os.environ, **_GIT_ENV},
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        )
        try:
            out, err = await asyncio.wait_for(proc.communicate(), timeout=_CLONE_TIMEOUT)
        except asyncio.TimeoutError:
            proc.kill()
            await proc.wait()
            raise
        exit_code = proc.returncode if proc.returncode is not None else -1
        return GitCloneResult(exit_code == 0, out.decode(errors="replace").strip(),
                              err.decode(errors="replace").strip(), exit_code)

    # streaming: merge stderr into stdout, emit each line (progress phases land
    # as one \r-laden line per stage — collapse to the final visible state).
    proc = await asyncio.create_subprocess_exec(
        "git", *args, env={**os.environ, **_GIT_ENV},
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
    )
    collected: list[str] = []
    try:
        while True:
            raw = await asyncio.wait_for(proc.stdout.readline(), timeout=_CLONE_TIMEOUT)
            if not raw:
                break
            line = raw.decode(errors="replace").rstrip("\r\n")
            if "\r" in line:
                line = line.rsplit("\r", 1)[-1]
            collected.append(line)
            on_line(line)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        raise
    await proc.wait()
    exit_code = proc.returncode if proc.returncode is not None else -1
    return GitCloneResult(exit_code == 0, "\n".join(collected), "", exit_code)


def _is_lock_file(path: str) -> bool:
    return path.rsplit("/", 1)[-1] in _LOCK_FILE_NAMES


async def _resolve_main_branch(project_path: str) -> str | None:
    sym = await _run(
        ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], project_path
    )
    if sym.exit_code == 0:
        v = sym.stdout.strip()
        # Returns "origin/main" — strip the "origin/" prefix.
        if v.startswith("origin/"):
            return v[len("origin/"):]
        return v
    # Fallbacks if origin/HEAD isn't set locally.
    for candidate in ("main", "master"):
        r = await _run(
            ["show-ref", "--verify", "--quiet", f"refs/remotes/origin/{candidate}"],
            project_path,
        )
        if r.exit_code == 0:
            return candidate
    return None


def _try_int(s: str) -> int | None:
    try:
        return int(s)
    except ValueError:
        return None


async def status(project_name: str, project_path: str) -> GitStatus:
    """Compute a GitStatus for the repo at project_path without any network
    calls. Safe to invoke from the hot path of the dashboard load."""
    git_dir = os.path.join(project_path, ".git")
    if not os.path.isdir(project_path) or not os.path.isdir(git_dir):
        return GitStatus(project=project_name, exists=False)

    try:
        # Branch (or "HEAD" for detached).
        branch_res = await _run(["rev-parse", "--abbrev-ref", "HEAD"], project_path)
        branch = branch_res.stdout.strip() if branch_res.exit_code == 0 else None

        # Short SHA + last commit subject.
        sha_res = await _run(["rev-parse", "--short", "HEAD"], project_path)
        short_sha = sha_res.stdout.strip() if sha_res.exit_code == 0 else None

        subj_res = await _run(["log", "-1", "--format=%s", "HEAD"], project_path)
        subject = subj_res.stdout.strip() if subj_res.exit_code == 0 else None

        # Dirty files. Parse porcelain output: first two chars are status
        # (e.g. " M", "??", "MM"), then a space, then the path.
        dirty_res = await _run(["status", "--porcelain"], project_path)
        dirty_files: list[DirtyFile] = []
        if dirty_res.exit_code == 0:
            for line in dirty_res.stdout.split("\n"):
                if len(line) < 4:
                    continue
                code = line[0:2]
                path = line[3:]
                dirty_files.append(
                    DirtyFile(path=path, status=code, is_lock_file=_is_lock_file(path))
                )

        # Upstream + behind/ahead vs upstream (local refs only).
        upstream_res = await _run(
            ["rev-parse", "--abbrev-ref", "@{upstream}"], project_path
        )
        upstream: str | None = None
        behind_upstream: int | None = None
        ahead_upstream: int | None = None
        if upstream_res.exit_code == 0:
            upstream = upstream_res.stdout.strip()
            counts_res = await _run(
                ["rev-list", "--left-right", "--count", f"{upstream}...HEAD"],
                project_path,
            )
            if counts_res.exit_code == 0:
                parts = counts_res.stdout.strip().split()
                if len(parts) == 2:
                    behind_upstream = _try_int(parts[0])
                    ahead_upstream = _try_int(parts[1])

        # Resolve default branch — `origin/HEAD` if set, fall back to main/master.
        main_branch = await _resolve_main_branch(project_path)

        # Commits behind main (only when current branch isn't main).
        behind_main: int | None = None
        if main_branch is not None and branch != main_branch:
            main_ref_res = await _run(
                ["rev-list", "--count", f"HEAD..origin/{main_branch}"], project_path
            )
            if main_ref_res.exit_code == 0:
                behind_main = _try_int(main_ref_res.stdout.strip())

        # Most recent tag reachable from origin/<main>, plus the number of
        # commits between that tag and HEAD. Matches `git describe HEAD`
        # semantics — "how far past the last release am I" — so on a feature
        # branch with 2 unmerged commits the dashboard shows `v1.31.1 +2`.
        # Tags are restricted to main (the team only tags on main); the count
        # is from HEAD so unmerged work on your branch is visible.
        latest_tag: str | None = None
        commits_since_tag: int | None = None
        if main_branch is not None:
            tag_res = await _run(
                ["describe", "--tags", "--abbrev=0", f"origin/{main_branch}"],
                project_path,
            )
            if tag_res.exit_code == 0:
                tag = tag_res.stdout.strip()
                if tag:
                    latest_tag = tag
                    count_res = await _run(
                        ["rev-list", "--count", f"{tag}..HEAD"], project_path
                    )
                    if count_res.exit_code == 0:
                        commits_since_tag = _try_int(count_res.stdout.strip())

        # FETCH_HEAD mtime as proxy for "last fetched".
        last_fetched: float | None = None
        fetch_head = os.path.join(project_path, ".git", "FETCH_HEAD")
        if os.path.exists(fetch_head):
            last_fetched = os.path.getmtime(fetch_head)

        return GitStatus(
            project=project_name,
            exists=True,
            branch=branch,
            short_sha=short_sha,
            subject=subject,
            dirty_files=dirty_files,
            upstream=upstream,
            behind_upstream=behind_upstream,
            ahead_upstream=ahead_upstream,
            main_branch=main_branch,
            behind_main=behind_main,
            latest_tag=latest_tag,
            commits_since_tag=commits_since_tag,
            last_fetched=last_fetched,
        )
    except Exception as e:
        _log.warning(
            "git status failed for %s at %s", project_name, project_path, exc_info=e
        )
        return GitStatus(project=project_name, exists=True, error=str(e))


async def refresh(project_name: str, project_path: str) -> GitStatus:
    """`git fetch --prune --tags --quiet origin` then return fresh status."""
    if not os.path.isdir(project_path):
        return GitStatus(project=project_name, exists=False)
    # `--tags` belt-and-suspenders: tags reachable from fetched branches come
    # along automatically, but a tag pointing at a commit that's no longer in
    # the default-fetched set would otherwise be missed.
    fetch_res = await _run(
        ["fetch", "--prune", "--tags", "--quiet", "origin"], project_path
    )
    if fetch_res.exit_code != 0:
        _log.warning(
            "git fetch failed for %s: %s", project_name, fetch_res.stderr.strip()
        )
    return await status(project_name, project_path)


async def pull_ff_only(project_name: str, project_path: str) -> GitPullResult:
    """`git pull --ff-only` with lock-file auto-stash. Pre-flight: refuses if
    any non-lock files are dirty (caller should gate the button anyway). When
    lock files are dirty, stashes just those paths, pulls, then pops. If pop
    conflicts (rare — only when remote also modified those exact lines), the
    stash is left in place and the failure is surfaced."""
    if not os.path.isdir(project_path):
        return GitPullResult(
            ok=False,
            message="project directory missing",
            status=GitStatus(project=project_name, exists=False),
        )

    pre = await status(project_name, project_path)
    if pre.dirty_code > 0:
        return GitPullResult(
            ok=False,
            message=f"refused: {pre.dirty_code} code file(s) dirty. Commit or stash them first.",
            status=pre,
        )

    stashed = False
    if pre.dirty_lock > 0:
        lock_paths = [f.path for f in pre.lock_files]
        stash_res = await _run(
            [
                "stash",
                "push",
                "--quiet",
                "-m",
                "limousine: auto-stash lock files",
                "--",
                *lock_paths,
            ],
            project_path,
        )
        if stash_res.exit_code != 0:
            err = stash_res.stderr.strip()
            return GitPullResult(
                ok=False,
                message=f"failed to stash lock files: {err}",
                status=await status(project_name, project_path),
            )
        stashed = True

    pull_res = await _run(["pull", "--ff-only", "--quiet"], project_path)
    pull_stderr = pull_res.stderr.strip()
    pull_ok = pull_res.exit_code == 0

    pop_message = ""
    if stashed:
        pop_res = await _run(["stash", "pop", "--quiet"], project_path)
        if pop_res.exit_code != 0:
            pop_err = pop_res.stderr.strip()
            # Pop failed → stash still in place. Tell the user.
            pop_message = (
                " Lock-file stash kept (conflict on pop) — run `git stash list` "
                f"then resolve manually. {pop_err if pop_err else ''}"
            )
        elif pull_ok:
            pop_message = " Auto-stashed and restored lock files."

    final_status = await status(project_name, project_path)
    return GitPullResult(
        ok=pull_ok and (("conflict" not in pop_message) if stashed else True),
        message=(
            f"fast-forwarded.{pop_message}"
            if pull_ok
            else (pull_stderr if pull_stderr else "pull failed")
        ),
        status=final_status,
    )
