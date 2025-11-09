import tkinter as tk
from tkinter import ttk, messagebox, filedialog
from pathlib import Path
from limousine.state_manager import StateManager
from limousine.ui.dashboard.dashboard import DashboardTab
from limousine.ui.tab_manager import TabManager
from limousine.ui.dialogs.about_dialog import AboutDialog
from limousine.ui.dialogs.settings_dialog import SettingsDialog
from limousine.storage.global_config import load_global_config, save_global_config
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)


class MainWindow(ttk.Frame):
    def __init__(
        self,
        parent,
        workspace_path: Path,
        state_manager: StateManager,
    ):
        super().__init__(parent)
        self.parent = parent
        self.workspace_path = workspace_path
        self.state_manager = state_manager

        self.pack(fill=tk.BOTH, expand=True)

        self.create_menu_bar()
        self.create_tab_container()

    def create_menu_bar(self):
        menubar = tk.Menu(self.parent)
        self.parent.config(menu=menubar)

        file_menu = tk.Menu(menubar, tearoff=0)
        menubar.add_cascade(label="File", menu=file_menu)
        file_menu.add_command(label="Switch Workspace", command=self.switch_workspace)
        file_menu.add_separator()
        file_menu.add_command(label="Settings", command=self.show_settings_dialog)
        file_menu.add_separator()
        file_menu.add_command(label="Exit", command=self.parent.quit)

        help_menu = tk.Menu(menubar, tearoff=0)
        menubar.add_cascade(label="Help", menu=help_menu)
        help_menu.add_command(label="About", command=self.show_about_dialog)

    def create_tab_container(self):
        self.notebook = ttk.Notebook(self)
        self.notebook.pack(fill=tk.BOTH, expand=True)

        self.tab_manager = TabManager(
            self.notebook,
            self.state_manager,
        )

        dashboard_tab = DashboardTab(
            self.notebook,
            self.state_manager,
            self.tab_manager,
        )
        self.notebook.add(dashboard_tab, text="Dashboard")

        for module_name in self.state_manager.app_state.modules.keys():
            for service_name in self.state_manager.app_state.modules[module_name].services.keys():
                self.tab_manager.add_service_tab(
                    module_name, service_name, show_spinner=False
                )

        for docker_service_name in self.state_manager.app_state.docker_services.keys():
            self.tab_manager.add_docker_service_tab(docker_service_name)

    def switch_workspace(self):
        file_path = filedialog.askopenfilename(
            title="Select limousine.wksp file",
            filetypes=[("Limousine Workspace", "*limousine.wksp"), ("All files", "*.*")],
        )

        if file_path:
            new_workspace_path = Path(file_path)

            if new_workspace_path != self.workspace_path:
                global_config = load_global_config()
                if new_workspace_path not in global_config.workspaces:
                    global_config.workspaces.append(new_workspace_path)
                    save_global_config(global_config)

                def do_switch():
                    self.destroy()
                    self.parent.load_workspace(new_workspace_path)

                self.after(0, do_switch)

    def show_about_dialog(self):
        AboutDialog(self.parent, self.workspace_path)

    def show_settings_dialog(self):
        SettingsDialog(self.parent)
