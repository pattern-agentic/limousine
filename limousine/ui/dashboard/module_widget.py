import tkinter as tk
from tkinter import ttk, messagebox
from pathlib import Path
from limousine.models.config import Module
from limousine.state_manager import StateManager
from limousine.ui.dashboard.service_row import ServiceRow
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)


class ModuleWidget(ttk.LabelFrame):
    def __init__(
        self,
        parent,
        module: Module,
        project_path: Path,
        state_manager: StateManager,
        tab_manager=None,
    ):
        super().__init__(parent, text=module.name, padding=10)
        self.module = module
        self.project_path = project_path
        self.state_manager = state_manager
        self.tab_manager = tab_manager

        self.create_widgets()

    def create_widgets(self):
        header_frame = ttk.Frame(self)
        header_frame.pack(fill=tk.X, pady=(0, 10))

        if self.module.services:
            services_frame = ttk.Frame(self)
            services_frame.pack(fill=tk.BOTH, expand=True)

            for service_name, service in self.module.services.items():
                service_row = ServiceRow(
                    services_frame,
                    self.module,
                    service_name,
                    service,
                    self.project_path,
                    self.state_manager,
                    self.tab_manager,
                )
                service_row.pack(fill=tk.X, pady=2)


