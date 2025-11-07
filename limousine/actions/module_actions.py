import subprocess
from pathlib import Path
from limousine.models.config import Module
from limousine.utils.path_utils import resolve_path, get_project_root
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)


def clone_repository(module: Module, project_root: Path) -> tuple[bool, str]:
    clone_path = resolve_path(module.clone_path, project_root)

    if clone_path.exists():
        return False, f"Directory {clone_path} already exists"

    try:
        clone_path.parent.mkdir(parents=True, exist_ok=True)

        logger.info(f"Cloning {module.git_repo_url} to {clone_path}")
        result = subprocess.run(
            ["git", "clone", module.git_repo_url, str(clone_path)],
            capture_output=True,
            text=True,
            timeout=300,
        )

        if result.returncode == 0:
            logger.info(f"Successfully cloned {module.name}")
            return True, "Clone successful"
        else:
            error_msg = result.stderr or result.stdout
            logger.error(f"Failed to clone {module.name}: {error_msg}")
            return False, error_msg

    except subprocess.TimeoutExpired:
        error_msg = "Clone operation timed out"
        logger.error(error_msg)
        return False, error_msg
    except Exception as e:
        error_msg = str(e)
        logger.error(f"Error cloning {module.name}: {e}", exc_info=True)
        return False, error_msg


def check_module_cloned(module: Module, project_root: Path) -> bool:
    clone_path = resolve_path(module.clone_path, project_root)
    is_cloned = clone_path.exists() and clone_path.is_dir()

    if is_cloned and (clone_path / ".git").exists():
        return True

    return is_cloned
