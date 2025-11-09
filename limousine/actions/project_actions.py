import subprocess
from pathlib import Path
from limousine.models.config import Project
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)


def clone_project(project: Project) -> tuple[bool, str]:
    if not project.optional_git_repo_url:
        return False, "No git repository URL provided"

    project_path = Path(project.path_on_disk)

    if project_path.exists():
        return False, f"Directory {project_path} already exists"

    try:
        project_path.parent.mkdir(parents=True, exist_ok=True)

        logger.info(f"Cloning {project.optional_git_repo_url} to {project_path}")
        result = subprocess.run(
            ["git", "clone", project.optional_git_repo_url, str(project_path)],
            capture_output=True,
            text=True,
            timeout=300,
        )

        if result.returncode == 0:
            logger.info(f"Successfully cloned {project.name}")
            return True, "Clone successful"
        else:
            error_msg = result.stderr or result.stdout
            logger.error(f"Failed to clone {project.name}: {error_msg}")
            return False, error_msg

    except subprocess.TimeoutExpired:
        error_msg = "Clone operation timed out"
        logger.error(error_msg)
        return False, error_msg
    except Exception as e:
        error_msg = str(e)
        logger.error(f"Error cloning {project.name}: {e}", exc_info=True)
        return False, error_msg


def check_project_exists(project: Project) -> bool:
    project_path = Path(project.path_on_disk)
    exists = project_path.exists() and project_path.is_dir()

    if exists and (project_path / ".limousine-proj").exists():
        return True

    return exists
