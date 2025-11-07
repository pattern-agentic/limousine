import tkinter as tk
from tkinter import ttk, messagebox
from pathlib import Path
from limousine.models.config import ProjectConfig
from limousine.state_manager import StateManager
from limousine.ui.dashboard.dashboard import DashboardTab
from limousine.ui.startup import load_or_select_project
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)


class MainWindow(ttk.Frame):
    def __init__(
        self,
        parent,
        project_config: ProjectConfig,
        project_path: Path,
        state_manager: StateManager,
    ):
        super().__init__(parent)
        self.parent = parent
        self.project_config = project_config
        self.project_path = project_path
        self.project_root = project_path.parent
        self.state_manager = state_manager

        self.pack(fill=tk.BOTH, expand=True)

        self.create_menu_bar()
        self.create_tab_container()

    def create_menu_bar(self):
        menubar = tk.Menu(self.parent)
        self.parent.config(menu=menubar)

        file_menu = tk.Menu(menubar, tearoff=0)
        menubar.add_cascade(label="File", menu=file_menu)
        file_menu.add_command(label="Switch Project", command=self.switch_project)
        file_menu.add_separator()
        file_menu.add_command(label="Exit", command=self.parent.quit)

        help_menu = tk.Menu(menubar, tearoff=0)
        menubar.add_cascade(label="Help", menu=help_menu)
        help_menu.add_command(label="About", command=self.show_about_dialog)

    def create_tab_container(self):
        self.notebook = ttk.Notebook(self)
        self.notebook.pack(fill=tk.BOTH, expand=True)

        dashboard_tab = DashboardTab(
            self.notebook,
            self.project_config,
            self.project_root,
            self.state_manager,
        )
        self.notebook.add(dashboard_tab, text="Dashboard")

    def switch_project(self):
        new_project_path = load_or_select_project(self.parent)

        if new_project_path and new_project_path != self.project_path:
            self.parent.destroy()
            from limousine.ui.app import LimousineApp

            app = LimousineApp(new_project_path)
            app.run()

    def show_about_dialog(self):
        try:
            from importlib.metadata import version

            app_version = version("limousine")
        except Exception:
            app_version = "0.1.0"

        log_file_path = Path.home() / ".limousine" / "logs" / "limousine.log"

        about_text = f"""Limousine v{app_version}

Microservice Development Environment Manager

Log file: {log_file_path}
Project: {self.project_path.name}
"""

        messagebox.showinfo("About Limousine", about_text)
