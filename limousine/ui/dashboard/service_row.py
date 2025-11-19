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
        self.update_status()
        self.start_status_polling()

    def create_widgets(self):
        service_label = ttk.Label(self, text=self.service_name, width=20)
        service_label.pack(side=tk.LEFT, padx=5)

        if len(self.command_names) > 1:
            self.command_var = tk.StringVar(value=self.current_command)
            command_dropdown = ttk.Combobox(
                self,
                textvariable=self.command_var,
                values=self.command_names,
                state="readonly",
                width=15,
            )
            command_dropdown.pack(side=tk.LEFT, padx=5)
            command_dropdown.bind("<<ComboboxSelected>>", self.on_command_changed)
        else:
            cmd_label = ttk.Label(self, text=self.current_command or "N/A", width=15)
            cmd_label.pack(side=tk.LEFT, padx=5)

        self.status_label = ttk.Label(self, text="unknown", width=12)
        self.status_label.pack(side=tk.LEFT, padx=5)

        self.start_stop_button = ttk.Button(
            self, text="Start", width=10, command=self.on_start_stop_clicked
        )
        self.start_stop_button.pack(side=tk.LEFT, padx=5)

        if self.tab_manager:
            view_tab_button = ttk.Button(
                self, text="View Tab", width=10, command=self.on_view_tab_clicked
            )
            view_tab_button.pack(side=tk.LEFT, padx=5)

    def on_command_changed(self, event=None):
        if hasattr(self, "command_var"):
            self.current_command = self.command_var.get()
            self.update_status()

    def update_status(self):
        if not self.current_command:
            self.status_label.config(text="N/A", foreground="gray")
            self.start_stop_button.config(state=tk.DISABLED)
            return

        status = get_service_status(
            self.module.name,
            self.service_name,
            self.current_command,
            self.state_manager,
        )

        if status == "running":
            self.status_label.config(text=status, foreground="green")
            self.start_stop_button.config(text="Stop")
        elif status == "stopped":
            self.status_label.config(text=status, foreground="dark yellow")
            self.start_stop_button.config(text="Start")
        elif status == "orphaned":
            self.status_label.config(text=status, foreground="orange")
            self.start_stop_button.config(text="Kill")
        else:
            self.status_label.config(text=status, foreground="gray")
            self.start_stop_button.config(text="Start")

    def on_start_stop_clicked(self):
        if not self.current_command:
            return

        status = get_service_status(
            self.module.name,
            self.service_name,
            self.current_command,
            self.state_manager,
        )

        if status == "running" or status == "orphaned":
            self.on_stop_clicked()
        else:
            self.on_start_clicked()

    def on_start_clicked(self):
        logger.info(f"Starting {self.module.name}:{self.service_name}:{self.current_command}")
        self.start_stop_button.config(state=tk.DISABLED)
        self.status_label.config(text="starting...", foreground="darkgreen")

        try:
            process_state = start_service(
                self.module,
                self.service_name,
                self.current_command,
                self.project_path,
                self.state_manager,
            )

            if process_state.state == "running":
                logger.info(f"Started successfully")
            else:
                logger.error(f"Failed to start: {process_state.last_error}")

        except Exception as e:
            logger.error(f"Error starting service: {e}", exc_info=True)
        finally:
            self.after(500, self.update_status)
            self.start_stop_button.config(state=tk.NORMAL)

    def on_stop_clicked(self):
        logger.info(f"Stopping {self.module.name}:{self.service_name}:{self.current_command}")
        self.start_stop_button.config(state=tk.DISABLED)
        self.status_label.config(text="stopping...", foreground="darkorange")

        try:
            success = stop_service(
                self.module.name,
                self.service_name,
                self.current_command,
                self.project_path,
                self.state_manager,
            )

            if success:
                logger.info(f"Stopped successfully")
            else:
                logger.warning(f"Failed to stop")

        except Exception as e:
            logger.error(f"Error stopping service: {e}", exc_info=True)
        finally:
            self.after(500, self.update_status)
            self.start_stop_button.config(state=tk.NORMAL)

    def on_view_tab_clicked(self):
        if self.tab_manager:
            tab_id = f"{self.module.name}:{self.service_name}"
            self.tab_manager.open_service_tab(
                self.module, self.service_name, self.project_path
            )

    def start_status_polling(self):
        def poll():
            if not self.winfo_exists():
                return
            self.update_status()
            self.after(2000, poll)

        self.after(2000, poll)
