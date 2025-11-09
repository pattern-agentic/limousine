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

        menu_button = ttk.Button(
            header_frame, text="⋮", width=3, command=self.show_module_menu
        )
        menu_button.pack(side=tk.RIGHT, padx=5)

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

    def show_module_menu(self):
        menu = tk.Menu(self, tearoff=0)
        menu.add_command(label="Update Env Files", command=self.on_update_env_clicked)
        menu.add_command(label="Check Secrets", command=self.on_check_secrets_clicked)

        try:
            menu.tk_popup(self.winfo_pointerx(), self.winfo_pointery())
        finally:
            menu.grab_release()

    def on_update_env_clicked(self):
        from limousine.ui.dialogs.env_dialog import EnvUpdateDialog

        EnvUpdateDialog(self.winfo_toplevel(), self.module, self.project_path)

    def on_check_secrets_clicked(self):
        if not self.module.config:
            messagebox.showinfo("No Config", "This module has no env configuration")
            return

        from limousine.process.environment import check_secrets_mismatch

        if not self.module.config.secrets_file or not self.module.config.secrets_example_file:
            messagebox.showinfo("No Secrets Config", "This module has no secrets configuration")
            return

        secrets_file = self.project_path / self.module.config.secrets_file
        secrets_example = self.project_path / self.module.config.secrets_example_file

        warnings = check_secrets_mismatch(secrets_file, secrets_example)

        if warnings:
            message = "\n".join(warnings)
            messagebox.showwarning("Secrets Mismatch", message)
        else:
            messagebox.showinfo("Secrets OK", "Secrets file matches example")
