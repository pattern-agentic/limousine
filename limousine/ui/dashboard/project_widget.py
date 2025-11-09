import tkinter as tk
from tkinter import ttk, messagebox
from pathlib import Path
from limousine.models.config import Project
from limousine.state_manager import StateManager
from limousine.actions.project_actions import clone_project, check_project_exists
from limousine.ui.dashboard.module_widget import ModuleWidget
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)


class ProjectWidget(ttk.LabelFrame):
    def __init__(
        self,
        parent,
        project_name: str,
        project: Project,
        state_manager: StateManager,
        tab_manager=None,
    ):
        super().__init__(parent, text=project_name, padding=10)
        self.project_name = project_name
        self.project = project
        self.state_manager = state_manager
        self.tab_manager = tab_manager
        self.expanded = True

        self.create_widgets()

    def create_widgets(self):
        header_frame = ttk.Frame(self)
        header_frame.pack(fill=tk.X, pady=(0, 10))

        expand_button = ttk.Button(
            header_frame, text="▼", width=3, command=self.toggle_expand
        )
        expand_button.pack(side=tk.LEFT, padx=5)
        self.expand_button = expand_button

        path_label = ttk.Label(header_frame, text=self.project.path_on_disk, foreground="gray")
        path_label.pack(side=tk.LEFT, padx=5)

        status_text = "Exists" if self.project.exists_on_disk else "Not found"
        status_color = "green" if self.project.exists_on_disk else "red"
        status_label = ttk.Label(header_frame, text=status_text, foreground=status_color)
        status_label.pack(side=tk.LEFT, padx=5)

        if not self.project.exists_on_disk and self.project.optional_git_repo_url:
            clone_button = ttk.Button(
                header_frame, text="Clone", command=self.on_clone_clicked
            )
            clone_button.pack(side=tk.RIGHT, padx=5)

        self.modules_frame = ttk.Frame(self)
        self.modules_frame.pack(fill=tk.BOTH, expand=True)

        if self.project.exists_on_disk:
            self.render_modules()

    def render_modules(self):
        for widget in self.modules_frame.winfo_children():
            widget.destroy()

        project_state = self.state_manager.app_state.projects.get(self.project_name)
        if not project_state:
            return

        project_config = self.state_manager.project_configs.get(self.project_name)
        if not project_config:
            return

        project_path = Path(self.project.path_on_disk)

        for module_name, module in project_config.modules.items():
            module_widget = ModuleWidget(
                self.modules_frame,
                module,
                project_path,
                self.state_manager,
                self.tab_manager,
            )
            module_widget.pack(fill=tk.X, pady=5, padx=10)

    def toggle_expand(self):
        self.expanded = not self.expanded
        if self.expanded:
            self.expand_button.config(text="▼")
            self.modules_frame.pack(fill=tk.BOTH, expand=True)
        else:
            self.expand_button.config(text="▶")
            self.modules_frame.pack_forget()

    def on_clone_clicked(self):
        logger.info(f"Cloning project {self.project_name}")

        success, message = clone_project(self.project)

        if success:
            messagebox.showinfo(
                "Clone Successful", f"Successfully cloned {self.project_name}"
            )
            self.project.exists_on_disk = True

            project_state = self.state_manager.app_state.projects.get(self.project_name)
            if project_state:
                project_state.exists_on_disk = True

            for widget in self.winfo_children():
                widget.destroy()
            self.create_widgets()
        else:
            messagebox.showerror(
                "Clone Failed", f"Failed to clone {self.project_name}:\n{message}"
            )
