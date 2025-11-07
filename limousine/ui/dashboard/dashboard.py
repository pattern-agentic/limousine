import tkinter as tk
from tkinter import ttk
from pathlib import Path
from limousine.models.config import ProjectConfig
from limousine.state_manager import StateManager
from limousine.ui.dashboard.module_widget import ModuleWidget
from limousine.ui.dashboard.service_row import ServiceRow
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)


class DashboardTab(ttk.Frame):
    def __init__(
        self,
        parent,
        project_config: ProjectConfig,
        project_root: Path,
        state_manager: StateManager,
    ):
        super().__init__(parent, padding=10)
        self.project_config = project_config
        self.project_root = project_root
        self.state_manager = state_manager

        self.create_widgets()

    def create_widgets(self):
        canvas = tk.Canvas(self, highlightthickness=0)
        scrollbar = ttk.Scrollbar(self, orient=tk.VERTICAL, command=canvas.yview)
        scrollable_frame = ttk.Frame(canvas)

        scrollable_frame.bind(
            "<Configure>", lambda e: canvas.configure(scrollregion=canvas.bbox("all"))
        )

        canvas.create_window((0, 0), window=scrollable_frame, anchor="nw")
        canvas.configure(yscrollcommand=scrollbar.set)

        if self.project_config.modules:
            modules_label = ttk.Label(
                scrollable_frame, text="Modules", font=("", 14, "bold")
            )
            modules_label.pack(anchor="w", pady=(0, 10))

            self.render_modules(scrollable_frame)

        if self.project_config.docker_services:
            docker_label = ttk.Label(
                scrollable_frame, text="Docker Services", font=("", 14, "bold")
            )
            docker_label.pack(anchor="w", pady=(20, 10))

            self.render_docker_services(scrollable_frame)

        canvas.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        scrollbar.pack(side=tk.RIGHT, fill=tk.Y)

    def render_modules(self, parent):
        for module_name, module in self.project_config.modules.items():
            module_widget = ModuleWidget(
                parent, module, self.project_root, self.state_manager
            )
            module_widget.pack(fill=tk.X, pady=5, padx=5)

    def render_docker_services(self, parent):
        docker_frame = ttk.LabelFrame(parent, text="Docker Services", padding=10)
        docker_frame.pack(fill=tk.X, pady=5, padx=5)

        for service_name, service in self.project_config.docker_services.items():
            row_frame = ttk.Frame(docker_frame)
            row_frame.pack(fill=tk.X, pady=2)

            service_label = ttk.Label(row_frame, text=service_name, width=20)
            service_label.pack(side=tk.LEFT, padx=5)

            commands = list(service.commands.keys())
            if commands:
                command_label = ttk.Label(row_frame, text=commands[0], width=15)
                command_label.pack(side=tk.LEFT, padx=5)

                status_label = ttk.Label(row_frame, text="stopped", width=12)
                status_label.pack(side=tk.LEFT, padx=5)

                start_button = ttk.Button(row_frame, text="Start", width=10)
                start_button.pack(side=tk.LEFT, padx=5)
