from tkinter import ttk
from pathlib import Path
from limousine.models.config import ProjectConfig
from limousine.state_manager import StateManager
from limousine.ui.service_tab.service_tab import ServiceTab
from limousine.ui.service_tab.docker_service_tab import DockerServiceTab
from limousine.ui.dialogs.progress_dialog import ProgressDialog
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)


class TabManager:
    def __init__(
        self,
        notebook: ttk.Notebook,
        project_config: ProjectConfig,
        project_root: Path,
        state_manager: StateManager,
    ):
        self.notebook = notebook
        self.project_config = project_config
        self.project_root = project_root
        self.state_manager = state_manager
        self.service_tabs: dict[str, ttk.Frame] = {}

    def add_service_tab(
        self, module_name: str, service_name: str, show_spinner: bool = True
    ) -> None:
        tab_id = f"{module_name}:{service_name}"

        if tab_id in self.service_tabs:
            self.switch_to_tab(tab_id)
            return

        module = self.project_config.modules.get(module_name)
        if not module:
            logger.error(f"Module {module_name} not found")
            return

        service = module.services.get(service_name)
        if not service:
            logger.error(f"Service {service_name} not found in module {module_name}")
            return

        progress = None
        if show_spinner:
            progress = ProgressDialog(
                self.notebook,
                "Loading",
                f"Creating tab for {module_name}:{service_name}...",
                cancelable=False,
            )

        def create_tab():
            try:
                service_tab = ServiceTab(
                    self.notebook,
                    module,
                    service_name,
                    service,
                    self.project_root,
                    self.state_manager,
                )

                self.service_tabs[tab_id] = service_tab
                self.notebook.add(service_tab, text=f"{module_name}:{service_name}")
                self.switch_to_tab(tab_id)

            finally:
                if progress:
                    progress.close()

        self.notebook.after(100, create_tab)

    def add_docker_service_tab(self, service_name: str) -> None:
        tab_id = f"docker:{service_name}"

        if tab_id in self.service_tabs:
            self.switch_to_tab(tab_id)
            return

        docker_service = self.project_config.docker_services.get(service_name)
        if not docker_service:
            logger.error(f"Docker service {service_name} not found")
            return

        docker_service_tab = DockerServiceTab(
            self.notebook,
            docker_service,
            service_name,
            self.project_root,
            self.state_manager,
        )

        self.service_tabs[tab_id] = docker_service_tab
        self.notebook.add(docker_service_tab, text=f"docker:{service_name}")

        logger.info(f"Created docker service tab: {service_name}")

    def remove_tab(self, tab_id: str) -> None:
        if tab_id not in self.service_tabs:
            return

        tab = self.service_tabs[tab_id]
        tab_index = self.notebook.index(tab)
        self.notebook.forget(tab_index)

        del self.service_tabs[tab_id]

        logger.info(f"Removed tab {tab_id}")

    def switch_to_tab(self, tab_id: str) -> None:
        if tab_id not in self.service_tabs:
            return

        tab = self.service_tabs[tab_id]
        tab_index = self.notebook.index(tab)
        self.notebook.select(tab_index)

    def get_tab_count(self) -> int:
        return len(self.service_tabs)
