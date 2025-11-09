from pathlib import Path
import shutil
from limousine.models.config import Module
from limousine.process.environment import load_env_file, check_secrets_mismatch
from limousine.utils.path_utils import resolve_path
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)


def update_env_files(module: Module, project_path: Path) -> dict:
    if not module.config:
        return {"success": False, "error": "Module has no env configuration"}

    if not project_path.exists():
        return {"success": False, "error": "Project not found"}

    source_file = module.config.source_env_file
    active_file = module.config.active_env_file

    if not source_file or not active_file:
        return {"success": False, "error": "Env file paths not configured"}

    source_path = project_path / source_file
    active_path = project_path / active_file

    if not source_path.exists():
        return {"success": False, "error": f"Source file not found: {source_file}"}

    result = merge_env_files(source_path, active_path)

    if module.config.secrets_file and module.config.secrets_example_file:
        secrets_path = project_path / module.config.secrets_file
        secrets_example_path = project_path / module.config.secrets_example_file

        warnings = check_secrets_mismatch(secrets_path, secrets_example_path)
        result["secrets_warnings"] = warnings

    return result


def copy_source_to_active(source: Path, target: Path) -> bool:
    try:
        shutil.copy2(source, target)
        logger.info(f"Copied {source} to {target}")
        return True
    except Exception as e:
        logger.error(f"Failed to copy {source} to {target}: {e}", exc_info=True)
        return False


def merge_env_files(source: Path, active: Path) -> dict:
    source_vars = load_env_file(source)

    active_vars = {}
    if active.exists():
        active_vars = load_env_file(active)

    source_keys = set(source_vars.keys())
    active_keys = set(active_vars.keys())

    added_keys = source_keys - active_keys
    removed_keys = active_keys - source_keys
    common_keys = source_keys & active_keys

    changed_keys = []
    for key in common_keys:
        if source_vars[key] != active_vars[key]:
            changed_keys.append(key)

    result = {
        "success": True,
        "added": list(added_keys),
        "removed": list(removed_keys),
        "changed": changed_keys,
        "total_source": len(source_keys),
        "total_active": len(active_keys),
    }

    return result


def apply_env_update(source: Path, active: Path, mode: str = "merge") -> bool:
    try:
        if mode == "replace":
            return copy_source_to_active(source, active)

        source_vars = load_env_file(source)
        active_vars = {}
        if active.exists():
            active_vars = load_env_file(active)

        merged_vars = active_vars.copy()
        merged_vars.update(source_vars)

        lines = []
        for key, value in merged_vars.items():
            if '"' in value or ' ' in value:
                lines.append(f'{key}="{value}"\n')
            else:
                lines.append(f"{key}={value}\n")

        with open(active, "w") as f:
            f.writelines(lines)

        logger.info(f"Merged {source} into {active}")
        return True

    except Exception as e:
        logger.error(f"Failed to merge env files: {e}", exc_info=True)
        return False
