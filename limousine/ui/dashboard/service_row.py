import tkinter as tk
from tkinter import ttk
from pathlib import Path
from limousine.models.config import Module, Service
from limousine.state_manager import StateManager
from limousine.actions.service_actions import start_service, stop_service, get_service_status
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)


class ServiceRow(ttk.Frame):
    def __init__(
        self,
        parent,
        module: Module,
        service_name: str,
        service: Service,
        project_path: Path,
        state_manager: StateManager,
        tab_manager=None,
    ):
        super().__init__(parent)
        self.module = module
        self.service_name = service_name
        self.service = service
        self.project_path = project_path
        self.state_manager = state_manager
        self.tab_manager = tab_manager

        self.command_names = list(service.commands.keys())
        self.current_command = self.command_names[0] if self.command_names else None

        self.create_widgets()

    def create_widgets(self):
        service_label = ttk.Label(self, text=self.service_name, width=20)
        service_label.pack(side=tk.LEFT, padx=5)
