"""Git state + per-module env/secrets drift, in one shape shared by the TUI and
the MCP server. Port of lib/server/project_status.dart. Local-file + git CLI
only; no extra processes."""

from __future__ import annotations

import asyncio
import os

from ..core.dtos import ConfigDelta, GitStatus, LoadedProject
from . import env as env_mod
from . import git


def _with_config_deltas(status: GitStatus, loaded: LoadedProject) -> GitStatus:
    data = loaded.project_data
    if data is None:
        return status
    deltas: list[ConfigDelta] = []
    for module in data.modules:
        cfg = module.config
        if not cfg.declared:  # module opted out of env management
            continue
        env_active = os.path.join(loaded.resolved_path, cfg.active_env_file)
        env_source = os.path.join(loaded.resolved_path, cfg.source_env_file)
        sec_active = os.path.join(loaded.resolved_path, cfg.active_secrets_env_file)
        sec_source = os.path.join(loaded.resolved_path, cfg.source_secrets_file)

        env_cmp = env_mod.compare_env_files(env_active, env_source)
        sec_cmp = env_mod.compare_env_files(sec_active, sec_source)

        # The active secrets file is sops-encrypted dotenv: its keys include sops'
        # own metadata (sops_mac, sops_version, sops_age__*, …) which aren't in
        # the template. Strip them so they don't read as "extra in active".
        sec_active_keys = {k for k in sec_cmp.active_keys if not k.startswith("sops_")}
        sec_source_keys = sec_cmp.source_keys

        deltas.append(
            ConfigDelta(
                module=module.name,
                env_active_exists=env_cmp.active_exists,
                env_source_exists=env_cmp.source_exists,
                env_missing_in_active=len(env_cmp.missing_in_active),
                env_extra_in_active=len(env_cmp.extra_in_active),
                secrets_active_exists=sec_cmp.active_exists,
                secrets_source_exists=sec_cmp.source_exists,
                secrets_missing_in_active=len(sec_source_keys - sec_active_keys),
                secrets_extra_in_active=len(sec_active_keys - sec_source_keys),
            )
        )
    status.config_deltas = deltas
    return status


async def read(name: str, loaded: LoadedProject) -> GitStatus:
    status = await git.status(name, loaded.resolved_path)
    return _with_config_deltas(status, loaded)


async def refresh(name: str, loaded: LoadedProject) -> GitStatus:
    status = await git.refresh(name, loaded.resolved_path)
    return _with_config_deltas(status, loaded)


async def read_all(wsm) -> list[dict]:
    """Parallel fan-out over every project; failures land in per-project `error`."""

    async def one(name: str, loaded: LoadedProject) -> dict:
        if not loaded.exists_on_disk:
            return _not_cloned_summary(name, loaded)
        try:
            return to_agent_summary(await read(name, loaded), loaded)
        except Exception as e:
            return {"name": name, "existsOnDisk": True, "path": loaded.resolved_path, "error": str(e)}

    items = list(wsm.projects.items())
    return list(await asyncio.gather(*(one(n, l) for n, l in items)))


def _not_cloned_summary(name: str, loaded: LoadedProject) -> dict:
    out = {"name": name, "existsOnDisk": False, "path": loaded.resolved_path}
    if loaded.git_repo_url:
        out["gitRepoUrl"] = loaded.git_repo_url
        out["note"] = (
            f"Not cloned. Use the dashboard Clone action, or "
            f"`git clone {loaded.git_repo_url} {loaded.resolved_path}`."
        )
    return out


def to_agent_summary(s: GitStatus, loaded: LoadedProject) -> dict:
    """Compact, no-nulls flattening with a derived one-line `summary`."""
    if not s.exists:
        return _not_cloned_summary(s.project, loaded)
    flags: list[str] = []
    if s.dirty_code > 0:
        flags.append(f"{s.dirty_code} code dirty")
    if s.dirty_lock > 0:
        flags.append(f"{s.dirty_lock} lock dirty")
    if s.upstream is None:
        flags.append("no upstream")
    if (s.behind_upstream or 0) > 0:
        flags.append(f"↓{s.behind_upstream} upstream")
    if (s.ahead_upstream or 0) > 0:
        flags.append(f"↑{s.ahead_upstream} upstream")
    if (s.behind_main or 0) > 0:
        flags.append(f"↓{s.behind_main} {s.main_branch or 'main'}")
    drifted = [d.module for d in s.config_deltas if d.has_any]
    if drifted:
        flags.append(f"config drift: {', '.join(drifted)}")

    head = f"{s.branch or '?'} @ {s.short_sha or '?'}"
    summary = f"{head} — clean" if not flags else f"{head} — {'; '.join(flags)}"

    out: dict = {
        "name": s.project,
        "existsOnDisk": True,
        "path": loaded.resolved_path,
        "summary": summary,
        "branch": s.branch,
        "shortSha": s.short_sha,
        "dirty": {
            "total": s.dirty,
            "code": s.dirty_code,
            "lock": s.dirty_lock,
            "files": [{"path": f.path, "status": f.status, "isLockFile": f.is_lock_file} for f in s.dirty_files],
        },
        "configDeltas": [
            {
                "module": d.module,
                "envDrift": d.has_env_delta,
                "secretsDrift": d.has_secrets_delta,
                **({"envMissingInActive": d.env_missing_in_active} if d.env_missing_in_active else {}),
                **({"envExtraInActive": d.env_extra_in_active} if d.env_extra_in_active else {}),
                **({"secretsMissingInActive": d.secrets_missing_in_active} if d.secrets_missing_in_active else {}),
                **({"secretsExtraInActive": d.secrets_extra_in_active} if d.secrets_extra_in_active else {}),
            }
            for d in s.config_deltas
        ],
    }
    if s.subject:
        out["lastCommit"] = s.subject
    if s.upstream:
        out["upstream"] = s.upstream
    if s.behind_upstream is not None:
        out["behindUpstream"] = s.behind_upstream
    if s.ahead_upstream is not None:
        out["aheadUpstream"] = s.ahead_upstream
    if s.main_branch:
        out["mainBranch"] = s.main_branch
    if s.behind_main is not None:
        out["behindMain"] = s.behind_main
    if s.error:
        out["error"] = s.error
    return out
