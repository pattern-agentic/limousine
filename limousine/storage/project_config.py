import json
from pathlib import Path
from limousine.models.config import (
    ProjectConfig,
    Module,
    Service,
    DockerService,
    ModuleConfig,
)
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)


def load_project_config(path: Path) -> ProjectConfig:
    try:
        with open(path, "r") as f:
            data = json.load(f)

        modules = {}
        for name, mod_data in data.get("modules", {}).items():
            services = {}
            for svc_name, svc_data in mod_data.get("services", {}).items():
                services[svc_name] = Service(commands=svc_data.get("commands", {}))

            config_data = mod_data.get("config")
            module_config = None
            if config_data:
                module_config = ModuleConfig(
                    active_env_file=config_data.get("active-env-file"),
                    source_env_file=config_data.get("source-env-file"),
                    secrets_file=config_data.get("secrets-file"),
                    secrets_example_file=config_data.get("secrets-example-file"),
                )

            modules[name] = Module(
                name=name,
                services=services,
                config=module_config,
            )

        docker_services = {}
        for name, svc_data in data.get("docker-services", {}).items():
            docker_services[name] = DockerService(
                commands=svc_data.get("commands", {})
            )

        return ProjectConfig(modules=modules, docker_services=docker_services)

    except Exception as e:
        logger.error(f"Failed to load project config from {path}: {e}", exc_info=True)
        raise


def save_project_config(config: ProjectConfig, path: Path) -> None:
    try:
        modules_data = {}
        for name, module in config.modules.items():
            services_data = {}
            for svc_name, service in module.services.items():
                services_data[svc_name] = {"commands": service.commands}

            mod_dict = {
                "services": services_data,
            }

            if module.config:
                mod_dict["config"] = {
                    "active-env-file": module.config.active_env_file,
                    "source-env-file": module.config.source_env_file,
                    "secrets-file": module.config.secrets_file,
                    "secrets-example-file": module.config.secrets_example_file,
                }

            modules_data[name] = mod_dict

        docker_services_data = {}
        for name, service in config.docker_services.items():
            docker_services_data[name] = {"commands": service.commands}

        data = {"modules": modules_data, "docker-services": docker_services_data}

        with open(path, "w") as f:
            json.dump(data, f, indent=2)

        logger.info(f"Saved project config to {path}")

    except Exception as e:
        logger.error(f"Failed to save project config to {path}: {e}", exc_info=True)
        raise


def validate_project_config(config: ProjectConfig) -> bool:
    try:
        if not config.modules and not config.docker_services:
            logger.warning("Project config has no modules or docker services")
            return False

        return True

    except Exception as e:
        logger.error(f"Error validating project config: {e}", exc_info=True)
        return False
