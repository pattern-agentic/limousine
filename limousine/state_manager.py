from pathlib import Path
from typing import Callable
from limousine.models.config import ProjectConfig
from limousine.models.state import AppState, ModuleState, ServiceState, ProcessState
from limousine.storage.project_config import load_project_config
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)


class StateManager:
    def __init__(self):
        self.app_state: AppState = AppState()
        self.project_config: ProjectConfig | None = None
        self.subscribers: list[Callable] = []

    def load_project(self, project_path: Path) -> None:
        logger.info(f"Loading project from {project_path}")
        self.project_config = load_project_config(project_path)
        self.app_state.current_project_file = project_path

        self.app_state.modules = {}
        for module_name, module in self.project_config.modules.items():
            services = {}
            for service_name in module.services.keys():
                services[service_name] = ServiceState()
            self.app_state.modules[module_name] = ModuleState(services=services)

        self.app_state.docker_services = {}
        for docker_service_name in self.project_config.docker_services.keys():
            self.app_state.docker_services[docker_service_name] = ServiceState()

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

    def subscribe_to_changes(self, callback: Callable) -> None:
        self.subscribers.append(callback)

    def _notify_subscribers(self) -> None:
        for callback in self.subscribers:
            try:
                callback()
            except Exception as e:
                logger.error(f"Error notifying subscriber: {e}", exc_info=True)
