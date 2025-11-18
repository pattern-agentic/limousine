import tkinter as tk
from tkinter import ttk
from pathlib import Path
import threading
import subprocess
from limousine.models.config import Module, Service
from limousine.state_manager import StateManager
from limousine.ui.service_tab.log_viewer import LogViewer
from limousine.actions.service_actions import start_service, stop_service, get_service_status
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)


class ServiceTab(ttk.Frame):
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
        super().__init__(parent, padding=10)
        self.module = module
        self.service_name = service_name
        self.service = service
        self.project_path = project_path
        self.state_manager = state_manager
        self.tab_manager = tab_manager

        self.command_names = list(service.commands.keys())
        self.current_command = self.command_names[0] if self.command_names else None

        self.stream_thread = None
        self.stop_streaming = False

        self.create_control_bar()
        self.create_log_viewer()

        self.update_status()
        self.start_status_polling()

    def create_control_bar(self):
        control_frame = ttk.Frame(self)
        control_frame.pack(fill=tk.X, pady=(0, 10))

        ttk.Label(control_frame, text="Command:", font=("", 10)).pack(
            side=tk.LEFT, padx=5
        )

        if len(self.command_names) > 1:
            self.command_var = tk.StringVar(value=self.current_command)
            command_dropdown = ttk.Combobox(
                control_frame,
                textvariable=self.command_var,
                values=self.command_names,
                state="readonly",
                width=20,
            )
            command_dropdown.pack(side=tk.LEFT, padx=5)
            command_dropdown.bind("<<ComboboxSelected>>", self.on_command_changed)
        else:
            ttk.Label(
                control_frame, text=self.current_command or "N/A", font=("", 10, "bold")
            ).pack(side=tk.LEFT, padx=5)

        self.status_label = ttk.Label(
            control_frame, text="stopped", font=("", 10, "bold")
        )
        self.status_label.pack(side=tk.LEFT, padx=10)

        self.start_stop_button = ttk.Button(
            control_frame, text="Start", command=self.on_start_stop_clicked
        )
        self.start_stop_button.pack(side=tk.LEFT, padx=5)

        self.clear_button = ttk.Button(
            control_frame, text="Clear Logs", command=self.on_clear_logs
        )
        self.clear_button.pack(side=tk.LEFT, padx=5)

        ttk.Button(
            control_frame, text="A+", width=3, command=self.on_increase_font
        ).pack(side=tk.LEFT, padx=2)

        ttk.Button(
            control_frame, text="A-", width=3, command=self.on_decrease_font
        ).pack(side=tk.LEFT, padx=2)

        ttk.Button(
            control_frame, text="---", width=3, command=self.on_add_separator
        ).pack(side=tk.LEFT, padx=2)

        menu_button = ttk.Button(
            control_frame, text="⋮", width=3, command=self.show_env_menu
        )
        menu_button.pack(side=tk.RIGHT, padx=5)

    def create_log_viewer(self):
        log_frame = ttk.LabelFrame(self, text="Logs", padding=10)
        log_frame.pack(fill=tk.BOTH, expand=True)

        self.log_viewer = LogViewer(log_frame, height=25)
        self.log_viewer.pack(fill=tk.BOTH, expand=True)

    def on_command_changed(self, event=None):
        if hasattr(self, "command_var"):
            self.current_command = self.command_var.get()
            self.update_status()

    def update_status(self):
        if not self.current_command:
            self.status_label.config(text="N/A", foreground="gray")
            self.start_stop_button.config(state=tk.DISABLED)
            if self.tab_manager:
                tab_id = f"{self.module.name}:{self.service_name}"
                self.tab_manager.update_tab_label(tab_id, False)
            return

        status = get_service_status(
            self.module.name,
            self.service_name,
            self.current_command,
            self.state_manager,
        )

        if status == "running":
            self.status_label.config(text=status, foreground="green")
        elif status == "stopped":
            self.status_label.config(text=status, foreground="dark yellow")
        else:
            self.status_label.config(text=status, foreground="gray")

        if status == "running":
            process_state = self.state_manager.get_service_state(
                self.module.name, self.service_name, self.current_command
            )
            if process_state and process_state.termination_stage:
                self.start_stop_button.config(text=f"Stop ({process_state.termination_stage})")
            else:
                self.start_stop_button.config(text="Stop")
            if not self.stream_thread or not self.stream_thread.is_alive():
                self.start_log_streaming()
            if self.tab_manager:
                tab_id = f"{self.module.name}:{self.service_name}"
                self.tab_manager.update_tab_label(tab_id, True)
        else:
            self.start_stop_button.config(text="Start")
            self.stop_log_streaming()
            if self.tab_manager:
                tab_id = f"{self.module.name}:{self.service_name}"
                self.tab_manager.update_tab_label(tab_id, False)

    def on_start_stop_clicked(self):
        if not self.current_command:
            return

        status = get_service_status(
            self.module.name,
            self.service_name,
            self.current_command,
            self.state_manager,
        )

        if status == "running":
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
                self.start_log_streaming()
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

        self.stop_log_streaming()
        
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
                self.log_viewer.append_lines(["\n(process terminated)\n============================\n"])
            else:
                logger.warning(f"Failed to stop")

        except Exception as e:
            logger.error(f"Error stopping service: {e}", exc_info=True)
        finally:
            self.after(500, self.update_status)
            self.start_stop_button.config(state=tk.NORMAL)

    def start_log_streaming(self):
        process_state = self.state_manager.get_service_state(
            self.module.name, self.service_name, self.current_command
        )

        if not process_state or not process_state.pid:
            return

        existing_output = process_state.get_output_lines()
        if existing_output:
            self.log_viewer.append_lines(existing_output)

        self.stop_streaming = False

        def stream_logs():
            try:
                while not self.stop_streaming:
                    ps = self.state_manager.get_service_state(
                        self.module.name, self.service_name, self.current_command
                    )

                    if ps and ps.output_buffer:
                        new_lines = list(ps.output_buffer)
                        if new_lines:
                            self.after(0, self.log_viewer.append_lines, new_lines)
                            ps.output_buffer.clear()

                    threading.Event().wait(0.5)

            except Exception as e:
                logger.error(f"Error streaming logs: {e}", exc_info=True)

        self.stream_thread = threading.Thread(target=stream_logs, daemon=True)
        self.stream_thread.start()

    def stop_log_streaming(self):
        self.stop_streaming = True

    def on_clear_logs(self):
        self.log_viewer.clear()

    def on_increase_font(self):
        self.log_viewer.increase_font_size()

    def on_decrease_font(self):
        self.log_viewer.decrease_font_size()

    def on_add_separator(self):
        self.log_viewer.add_separator()

    def start_status_polling(self):
        def poll():
            if not self.winfo_exists():
                return
            self.update_status()
            self.after(2000, poll)

        self.after(2000, poll)

    def show_env_menu(self):
        menu = tk.Menu(self, tearoff=0)
        menu.add_command(label="Show env variables...", command=self.on_show_env_clicked)
        menu.add_command(label="Show secrets...", command=self.on_show_secrets_clicked)

        try:
            menu.tk_popup(self.winfo_pointerx(), self.winfo_pointery())
        finally:
            menu.grab_release()

    def on_show_env_clicked(self):
        from limousine.ui.dialogs.env_compare_dialog import EnvCompareDialog

        EnvCompareDialog(self.winfo_toplevel(), self.module, self.project_path)

    def on_show_secrets_clicked(self):
        from limousine.ui.dialogs.secrets_compare_dialog import SecretsCompareDialog

        SecretsCompareDialog(self.winfo_toplevel(), self.module, self.project_path)
