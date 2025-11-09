from tkinter import ttk
from pathlib import Path
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
        state_manager: StateManager,
    ):
        self.notebook = notebook
        self.state_manager = state_manager
        self.service_tabs: dict[str, ttk.Frame] = {}

    def add_service_tab(
        self, module_name: str, service_name: str, show_spinner: bool = True
    ) -> None:
        tab_id = f"{module_name}:{service_name}"

        if tab_id in self.service_tabs:
            self.switch_to_tab(tab_id)
            return

        project_config = self.state_manager.get_project_config_for_module(module_name)
        if not project_config:
            logger.error(f"Project config not found for module {module_name}")
            return

        module = project_config.modules.get(module_name)
        if not module:
            logger.error(f"Module {module_name} not found")
            return

        service = module.services.get(service_name)
        if not service:
            logger.error(f"Service {service_name} not found in module {module_name}")
            return

        project_path = self.state_manager.get_project_path_for_module(module_name)
        if not project_path:
            logger.error(f"Project path not found for module {module_name}")
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
                    project_path,
                    self.state_manager,
                    self,
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

        for project_config in self.state_manager.project_configs.values():
            docker_service = project_config.docker_services.get(service_name)
            if docker_service:
                for project_state in self.state_manager.app_state.projects.values():
                    if service_name in project_state.docker_services:
                        project_path = Path(project_state.path_on_disk)

                        docker_service_tab = DockerServiceTab(
                            self.notebook,
                            docker_service,
                            service_name,
                            project_path,
                            self.state_manager,
                            self
                        )

                        self.service_tabs[tab_id] = docker_service_tab
                        self.notebook.add(docker_service_tab, text=f"docker:{service_name}")

                        logger.info(f"Created docker service tab: {service_name}")
                        return

        logger.error(f"Docker service {service_name} not found")

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

    def update_tab_label(self, tab_id: str, is_running: bool) -> None:
        if tab_id not in self.service_tabs:
            return

        tab = self.service_tabs[tab_id]
        tab_index = self.notebook.index(tab)

        base_text = tab_id
        if is_running:
            new_text = f"▶ {base_text}"
        else:
            new_text = base_text

        self.notebook.tab(tab_index, text=new_text)
