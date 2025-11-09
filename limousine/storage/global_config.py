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
            workspaces = [Path(p) for p in data.get("limousine-workspaces", [])]
            return GlobalConfig(workspaces=workspaces)
    except Exception as e:
        logger.error(f"Failed to load global config: {e}", exc_info=True)
        return GlobalConfig()


def save_global_config(config: GlobalConfig) -> None:
    config_path = get_global_config_path()
    config_path.parent.mkdir(parents=True, exist_ok=True)

    try:
        data = {"limousine-workspaces": [str(p) for p in config.workspaces]}
        with open(config_path, "w") as f:
            json.dump(data, f, indent=2)
        logger.info(f"Saved global config to {config_path}")
    except Exception as e:
        logger.error(f"Failed to save global config: {e}", exc_info=True)
        raise
