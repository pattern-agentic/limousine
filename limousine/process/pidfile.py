from pathlib import Path
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)


def create_pidfile(
    pids_dir: Path, service_name: str, command_name: str, pid: int
) -> Path:
    pids_dir.mkdir(parents=True, exist_ok=True)
    pidfile_path = pids_dir / f"{service_name}_{command_name}.pid"

    try:
        with open(pidfile_path, "w") as f:
            f.write(str(pid))
        logger.info(f"Created pidfile for {service_name}:{command_name} at {pidfile_path}")
        return pidfile_path
    except Exception as e:
        logger.error(f"Failed to create pidfile: {e}", exc_info=True)
        raise


def remove_pidfile(path: Path) -> None:
    try:
        if path.exists():
            path.unlink()
            logger.info(f"Removed pidfile at {path}")
    except Exception as e:
        logger.error(f"Failed to remove pidfile at {path}: {e}", exc_info=True)


def read_pidfile(path: Path) -> int | None:
    try:
        if not path.exists():
            return None
        with open(path, "r") as f:
            content = f.read().strip()
            return int(content) if content else None
    except Exception as e:
        logger.error(f"Failed to read pidfile at {path}: {e}", exc_info=True)
        return None
