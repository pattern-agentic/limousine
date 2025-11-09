import json
from pathlib import Path
from limousine.models.config import WorkspaceConfig, Project
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)


def load_workspace_config(path: Path) -> WorkspaceConfig:
    try:
        with open(path, "r") as f:
            data = json.load(f)

        projects = {}
        for name, proj_data in data.get("projects", {}).items():
            path_on_disk = proj_data["path-on-disk"]
            git_url = proj_data.get("optional-git-repo-url")

            project_path = Path(path_on_disk)
            if not project_path.is_absolute():
                project_path = path.parent / project_path

            exists_on_disk = project_path.exists()

            projects[name] = Project(
                name=name,
                path_on_disk=str(project_path),
                optional_git_repo_url=git_url,
                exists_on_disk=exists_on_disk,
            )

        workspace_name = data.get("name", "Unnamed Workspace")
        return WorkspaceConfig(name=workspace_name, projects=projects)

    except Exception as e:
        logger.error(f"Failed to load workspace config from {path}: {e}", exc_info=True)
        raise


def save_workspace_config(config: WorkspaceConfig, path: Path) -> None:
    try:
        projects_data = {}
        for name, project in config.projects.items():
            proj_dict = {
                "path-on-disk": project.path_on_disk,
            }
            if project.optional_git_repo_url:
                proj_dict["optional-git-repo-url"] = project.optional_git_repo_url
            projects_data[name] = proj_dict

        data = {
            "name": config.name,
            "projects": projects_data,
        }

        with open(path, "w") as f:
            json.dump(data, f, indent=2)

        logger.info(f"Saved workspace config to {path}")

    except Exception as e:
        logger.error(f"Failed to save workspace config to {path}: {e}", exc_info=True)
        raise


def validate_workspace_config(config: WorkspaceConfig) -> bool:
    try:
        if not config.projects:
            logger.warning("Workspace config has no projects")
            return False

        for name, project in config.projects.items():
            if not project.path_on_disk:
                logger.error(f"Project {name} missing path-on-disk")
                return False

        return True

    except Exception as e:
        logger.error(f"Error validating workspace config: {e}", exc_info=True)
        return False
