import tkinter as tk
from tkinter import ttk
from pathlib import Path
import threading
from limousine.models.config import DockerService
from limousine.state_manager import StateManager
from limousine.ui.service_tab.log_viewer import LogViewer
from limousine.actions.service_actions import (
    start_docker_service,
    stop_docker_service,
    get_service_status,
)
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)


class DockerServiceTab(ttk.Frame):
    def __init__(
        self,
        parent,
        docker_service: DockerService,
        service_name: str,
        project_root: Path,
        state_manager: StateManager,
    ):
        super().__init__(parent, padding=10)
        self.docker_service = docker_service
        self.service_name = service_name
        self.project_root = project_root
        self.state_manager = state_manager

        self.command_names = list(docker_service.commands.keys())
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
            self.status_label.config(text="N/A")
            self.start_stop_button.config(state=tk.DISABLED)
            return

        process_state = self.state_manager.get_docker_service_state(
            self.service_name, self.current_command
        )

        if not process_state:
            status = "stopped"
        elif process_state.state == "running" and process_state.pid:
            from limousine.process.manager import check_process_running

            if check_process_running(process_state.pid):
                status = "running"
            else:
                process_state.state = "stopped"
                self.state_manager.update_docker_service_state(
                    self.service_name, self.current_command, process_state
                )
                status = "stopped"
        else:
            status = process_state.state

        self.status_label.config(text=status)

        if status == "running":
            if process_state and process_state.termination_stage:
                self.start_stop_button.config(text=f"Stop ({process_state.termination_stage})")
            else:
                self.start_stop_button.config(text="Stop")
            if not self.stream_thread or not self.stream_thread.is_alive():
                self.start_log_streaming()
        else:
            self.start_stop_button.config(text="Start")
            self.stop_log_streaming()

    def on_start_stop_clicked(self):
        if not self.current_command:
            return

        process_state = self.state_manager.get_docker_service_state(
            self.service_name, self.current_command
        )

        if process_state and process_state.state == "running":
            self.on_stop_clicked()
        else:
            self.on_start_clicked()

    def on_start_clicked(self):
        logger.info(f"Starting docker:{self.service_name}:{self.current_command}")
        self.start_stop_button.config(state=tk.DISABLED)
        self.status_label.config(text="starting...")

        try:
            process_state = start_docker_service(
                self.docker_service,
                self.service_name,
                self.current_command,
                self.project_root,
                self.state_manager,
            )

            if process_state.state == "running":
                logger.info(f"Started successfully")
                self.start_log_streaming()
            else:
                logger.error(f"Failed to start: {process_state.last_error}")

        except Exception as e:
            logger.error(f"Error starting docker service: {e}", exc_info=True)
        finally:
            self.after(500, self.update_status)
            self.start_stop_button.config(state=tk.NORMAL)

    def on_stop_clicked(self):
        logger.info(f"Stopping docker:{self.service_name}:{self.current_command}")
        self.start_stop_button.config(state=tk.DISABLED)
        self.status_label.config(text="stopping...")

        self.stop_log_streaming()

        try:
            success = stop_docker_service(
                self.service_name,
                self.current_command,
                self.project_root,
                self.state_manager,
            )

            if success:
                logger.info(f"Stopped successfully")
            else:
                logger.warning(f"Failed to stop")

        except Exception as e:
            logger.error(f"Error stopping docker service: {e}", exc_info=True)
        finally:
            self.after(500, self.update_status)
            self.start_stop_button.config(state=tk.NORMAL)

    def start_log_streaming(self):
        process_state = self.state_manager.get_docker_service_state(
            self.service_name, self.current_command
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
                    ps = self.state_manager.get_docker_service_state(
                        self.service_name, self.current_command
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

    def start_status_polling(self):
        def poll():
            if not self.winfo_exists():
                return
            self.update_status()
            self.after(2000, poll)

        self.after(2000, poll)
