from pathlib import Path
from limousine.utils.logging_config import setup_logging
from limousine.storage.global_config import load_global_config
from limousine.utils.path_utils import get_limousine_dir


def main():
    global_config = load_global_config()
    limousine_home = Path.home() / ".limousine"
    log_file = limousine_home / "logs" / "limousine.log"

    setup_logging(log_file=log_file)

    print("Limousine - Stage 1 Infrastructure Complete")
    print(f"Global config: {len(global_config.projects)} projects")


if __name__ == "__main__":
    main()
