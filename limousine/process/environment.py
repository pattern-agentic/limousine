import os
from pathlib import Path
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)


def load_env_file(path: Path) -> dict[str, str]:
    env_vars = {}

    if not path.exists():
        logger.warning(f"Env file not found: {path}")
        return env_vars

    try:
        with open(path, "r") as f:
            for line_num, line in enumerate(f, 1):
                line = line.strip()

                if not line or line.startswith("#"):
                    continue

                if "=" not in line:
                    logger.warning(f"Invalid line {line_num} in {path}: {line}")
                    continue

                key, _, value = line.partition("=")
                key = key.strip()
                value = value.strip()

                if value.startswith('"') and value.endswith('"'):
                    value = value[1:-1]
                elif value.startswith("'") and value.endswith("'"):
                    value = value[1:-1]

                env_vars[key] = value

        logger.info(f"Loaded {len(env_vars)} env vars from {path}")
        return env_vars

    except Exception as e:
        logger.error(f"Failed to load env file {path}: {e}", exc_info=True)
        return {}


def merge_env_vars(
    system_env: dict[str, str],
    env_file: Path | None = None,
    secrets_file: Path | None = None,
) -> dict[str, str]:
    merged = system_env.copy()

    if env_file:
        env_vars = load_env_file(env_file)
        merged.update(env_vars)

    if secrets_file:
        secrets = load_env_file(secrets_file)
        merged.update(secrets)

    return merged


def check_secrets_mismatch(
    secrets_file: Path, secrets_example_file: Path
) -> list[str]:
    warnings = []

    if not secrets_file.exists() or not secrets_example_file.exists():
        return warnings

    secrets = load_env_file(secrets_file)
    example = load_env_file(secrets_example_file)

    secrets_keys = set(secrets.keys())
    example_keys = set(example.keys())

    missing_keys = example_keys - secrets_keys
    extra_keys = secrets_keys - example_keys

    if missing_keys:
        warnings.append(
            f"Missing keys in secrets file: {', '.join(sorted(missing_keys))}"
        )

    if extra_keys:
        warnings.append(
            f"Extra keys in secrets file: {', '.join(sorted(extra_keys))}"
        )

    return warnings
