import json
from pathlib import Path
from limousine.models.config import GlobalConfig
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)


def get_global_config_path() -> Path:
    return Path.home() / ".limousine" / "config.json"


def load_global_config() -> GlobalConfig:
    config_path = get_global_config_path()

    if not config_path.exists():
        logger.info(f"Global config not found at {config_path}, creating default")
        config = GlobalConfig()
        save_global_config(config)
        return config

    try:
        with open(config_path, "r") as f:
            data = json.load(f)
            projects = [Path(p) for p in data.get("projects", [])]
            return GlobalConfig(projects=projects)
    except Exception as e:
        logger.error(f"Failed to load global config: {e}", exc_info=True)
        return GlobalConfig()


def save_global_config(config: GlobalConfig) -> None:
    config_path = get_global_config_path()
    config_path.parent.mkdir(parents=True, exist_ok=True)

    try:
        data = {"projects": [str(p) for p in config.projects]}
        with open(config_path, "w") as f:
            json.dump(data, f, indent=2)
        logger.info(f"Saved global config to {config_path}")
    except Exception as e:
        logger.error(f"Failed to save global config: {e}", exc_info=True)
        raise
