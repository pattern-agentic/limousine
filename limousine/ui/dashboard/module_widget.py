import tkinter as tk
from tkinter import ttk, messagebox
from pathlib import Path
from limousine.models.config import Module
from limousine.state_manager import StateManager
from limousine.actions.module_actions import clone_repository, check_module_cloned
from limousine.ui.dashboard.service_row import ServiceRow
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)


class ModuleWidget(ttk.LabelFrame):
    def __init__(
        self,
        parent,
        module: Module,
        project_root: Path,
        state_manager: StateManager,
        tab_manager=None,
    ):
        super().__init__(parent, text=module.name, padding=10)
        self.module = module
        self.project_root = project_root
        self.state_manager = state_manager
        self.tab_manager = tab_manager

        self.is_cloned = check_module_cloned(module, project_root)

        self.create_widgets()

    def create_widgets(self):
        header_frame = ttk.Frame(self)
        header_frame.pack(fill=tk.X, pady=(0, 10))

        status_text = "Cloned" if self.is_cloned else "Not cloned"
        status_label = ttk.Label(header_frame, text=status_text)
        status_label.pack(side=tk.LEFT, padx=5)

        if not self.is_cloned:
            clone_button = ttk.Button(
                header_frame, text="Clone", command=self.on_clone_clicked
            )
            clone_button.pack(side=tk.LEFT, padx=5)

        menu_button = ttk.Button(
            header_frame, text="⋮", width=3, command=self.show_module_menu
        )
        menu_button.pack(side=tk.RIGHT, padx=5)

        if self.is_cloned and self.module.services:
            services_frame = ttk.Frame(self)
            services_frame.pack(fill=tk.BOTH, expand=True)

            for service_name, service in self.module.services.items():
                service_row = ServiceRow(
                    services_frame,
                    self.module,
                    service_name,
                    service,
                    self.project_root,
                    self.state_manager,
                    self.tab_manager,
                )
                service_row.pack(fill=tk.X, pady=2)

    def show_module_menu(self):
        menu = tk.Menu(self, tearoff=0)

        if not self.is_cloned:
            menu.add_command(label="Clone Repository", command=self.on_clone_clicked)
        else:
            menu.add_command(label="Update Env Files", command=self.on_update_env_clicked)
            menu.add_command(label="Check Secrets", command=self.on_check_secrets_clicked)

        try:
            menu.tk_popup(self.winfo_pointerx(), self.winfo_pointery())
        finally:
            menu.grab_release()

    def on_clone_clicked(self):
        logger.info(f"Cloning {self.module.name}")

        success, message = clone_repository(self.module, self.project_root)

        if success:
            messagebox.showinfo("Clone Successful", f"Successfully cloned {self.module.name}")
            self.is_cloned = True
            for widget in self.winfo_children():
                widget.destroy()
            self.create_widgets()
        else:
            messagebox.showerror("Clone Failed", f"Failed to clone {self.module.name}:\n{message}")

    def on_update_env_clicked(self):
        from limousine.ui.dialogs.env_dialog import EnvUpdateDialog

        EnvUpdateDialog(self.winfo_toplevel(), self.module, self.project_root)

    def on_check_secrets_clicked(self):
        if not self.module.config:
            messagebox.showinfo("No Config", "This module has no env configuration")
            return

        from limousine.process.environment import check_secrets_mismatch
        from limousine.utils.path_utils import resolve_path

        if not self.module.config.secrets_file or not self.module.config.secrets_example_file:
            messagebox.showinfo("No Secrets Config", "This module has no secrets configuration")
            return

        clone_path = resolve_path(self.module.clone_path, self.project_root)
        secrets_file = clone_path / self.module.config.secrets_file
        secrets_example = clone_path / self.module.config.secrets_example_file

        warnings = check_secrets_mismatch(secrets_file, secrets_example)

        if warnings:
            message = "\n".join(warnings)
            messagebox.showwarning("Secrets Mismatch", message)
        else:
            messagebox.showinfo("Secrets OK", "Secrets file matches example")
