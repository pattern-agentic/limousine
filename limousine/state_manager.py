from pathlib import Path
from typing import Callable
from limousine.models.config import ProjectConfig, WorkspaceConfig
from limousine.models.state import (
    AppState,
    ModuleState,
    ServiceState,
    ProcessState,
    ProjectState,
)
from limousine.storage.project_config import load_project_config
from limousine.storage.workspace_config import load_workspace_config
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)


class StateManager:
    def __init__(self):
        self.app_state: AppState = AppState()
        self.workspace_config: WorkspaceConfig | None = None
        self.project_configs: dict[str, ProjectConfig] = {}
        self.subscribers: list[Callable] = []

    def load_workspace(self, workspace_path: Path) -> None:
        logger.info(f"Loading workspace from {workspace_path}")
        self.workspace_config = load_workspace_config(workspace_path)
        self.app_state.current_workspace_file = workspace_path

        self.app_state.projects = {}
        self.app_state.modules = {}
        self.app_state.docker_services = {}

        for project_name, project in self.workspace_config.projects.items():
            project_state = ProjectState(
                path_on_disk=project.path_on_disk,
                optional_git_repo_url=project.optional_git_repo_url,
                exists_on_disk=project.exists_on_disk,
            )

            if project.exists_on_disk:
                proj_config_path = Path(project.path_on_disk) / ".limousine-proj"
                if proj_config_path.exists():
                    try:
                        proj_config = load_project_config(proj_config_path)
                        self.project_configs[project_name] = proj_config

                        for module_name, module in proj_config.modules.items():
                            services = {}
                            for service_name in module.services.keys():
                                services[service_name] = ServiceState()
                            module_state = ModuleState(
                                services=services, project_name=project_name
                            )
                            self.app_state.modules[module_name] = module_state
                            project_state.modules[module_name] = module_state

                        for docker_service_name in proj_config.docker_services.keys():
                            docker_service_state = ServiceState()
                            self.app_state.docker_services[
                                docker_service_name
                            ] = docker_service_state
                            project_state.docker_services[
                                docker_service_name
                            ] = docker_service_state

                    except Exception as e:
                        logger.error(
                            f"Failed to load project config from {proj_config_path}: {e}",
                            exc_info=True,
                        )

            self.app_state.projects[project_name] = project_state

        self._notify_subscribers()

    def get_service_state(
        self, module_name: str, service_name: str, command_name: str
    ) -> ProcessState | None:
        module_state = self.app_state.modules.get(module_name)
        if not module_state:
            return None

        service_state = module_state.services.get(service_name)
        if not service_state:
            return None

        return service_state.command_states.get(command_name)

    def update_service_state(
        self, module_name: str, service_name: str, command_name: str, state: ProcessState
    ) -> None:
        module_state = self.app_state.modules.get(module_name)
        if not module_state:
            logger.warning(f"Module {module_name} not found in state")
            return

        service_state = module_state.services.get(service_name)
        if not service_state:
            logger.warning(f"Service {service_name} not found in module {module_name}")
            return

        service_state.command_states[command_name] = state
        self._notify_subscribers()

    def get_docker_service_state(
        self, service_name: str, command_name: str
    ) -> ProcessState | None:
        service_state = self.app_state.docker_services.get(service_name)
        if not service_state:
            return None
        return service_state.command_states.get(command_name)

    def update_docker_service_state(
        self, service_name: str, command_name: str, state: ProcessState
    ) -> None:
        service_state = self.app_state.docker_services.get(service_name)
        if not service_state:
            logger.warning(f"Docker service {service_name} not found in state")
            return

        service_state.command_states[command_name] = state
        self._notify_subscribers()

    def get_project_path_for_module(self, module_name: str) -> Path | None:
        module_state = self.app_state.modules.get(module_name)
        if not module_state or not module_state.project_name:
            return None

        project_state = self.app_state.projects.get(module_state.project_name)
        if not project_state:
            return None

        return Path(project_state.path_on_disk)

    def get_project_config_for_module(self, module_name: str) -> ProjectConfig | None:
        module_state = self.app_state.modules.get(module_name)
        if not module_state or not module_state.project_name:
            return None
        return self.project_configs.get(module_state.project_name)

    def subscribe_to_changes(self, callback: Callable) -> None:
        self.subscribers.append(callback)

    def _notify_subscribers(self) -> None:
        for callback in self.subscribers:
            try:
                callback()
            except Exception as e:
                logger.error(f"Error notifying subscriber: {e}", exc_info=True)
