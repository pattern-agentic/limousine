from pathlib import Path


def resolve_path(path: str | Path, relative_to: Path | None = None) -> Path:
    path_obj = Path(path)

    if path_obj.is_absolute():
        return path_obj.resolve()

    if relative_to is not None:
        return (relative_to / path_obj).resolve()

    return path_obj.resolve()


def get_project_root(project_file: Path) -> Path:
    return project_file.parent.resolve()


def get_limousine_dir(project_root: Path) -> Path:
    return project_root / ".limousine"


def ensure_dir_exists(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    return path
