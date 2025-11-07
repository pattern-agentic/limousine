import tkinter as tk
from tkinter import ttk, scrolledtext
from pathlib import Path
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)


class AboutDialog(tk.Toplevel):
    def __init__(self, parent, project_path: Path):
        super().__init__(parent)
        self.title("About Limousine")
        self.geometry("600x500")
        self.transient(parent)

        self.project_path = project_path

        frame = ttk.Frame(self, padding=20)
        frame.pack(fill=tk.BOTH, expand=True)

        self.create_info_section(frame)
        self.create_log_viewer(frame)

        button_frame = ttk.Frame(frame)
        button_frame.pack(fill=tk.X, pady=(10, 0))

        ttk.Button(button_frame, text="Close", command=self.destroy).pack()

    def create_info_section(self, parent):
        info_frame = ttk.Frame(parent)
        info_frame.pack(fill=tk.X, pady=(0, 15))

        ttk.Label(
            info_frame,
            text="Limousine",
            font=("", 16, "bold"),
        ).pack()

        version = self.show_version()
        ttk.Label(
            info_frame,
            text=f"Version {version}",
            font=("", 10),
        ).pack(pady=(5, 10))

        ttk.Label(
            info_frame,
            text="Microservice Development Environment Manager",
            font=("", 10),
        ).pack(pady=(0, 10))

        log_file_path = Path.home() / ".limousine" / "logs" / "limousine.log"
        ttk.Label(
            info_frame,
            text=f"Log file: {log_file_path}",
            font=("", 9),
            foreground="gray",
        ).pack()

        ttk.Label(
            info_frame,
            text=f"Project: {self.project_path.name}",
            font=("", 9),
            foreground="gray",
        ).pack()

    def show_version(self) -> str:
        try:
            from importlib.metadata import version

            return version("limousine")
        except Exception:
            return "0.1.0"

    def create_log_viewer(self, parent):
        log_frame = ttk.LabelFrame(parent, text="Recent Logs", padding=10)
        log_frame.pack(fill=tk.BOTH, expand=True)

        self.log_text = scrolledtext.ScrolledText(
            log_frame, wrap=tk.WORD, height=15, font=("Courier", 8)
        )
        self.log_text.pack(fill=tk.BOTH, expand=True)

        self.load_logs()

        button_frame = ttk.Frame(log_frame)
        button_frame.pack(fill=tk.X, pady=(5, 0))

        ttk.Button(button_frame, text="Refresh", command=self.load_logs).pack(
            side=tk.LEFT
        )

    def load_logs(self):
        log_file_path = Path.home() / ".limousine" / "logs" / "limousine.log"

        self.log_text.config(state=tk.NORMAL)
        self.log_text.delete("1.0", tk.END)

        if not log_file_path.exists():
            self.log_text.insert("1.0", "No log file found")
            self.log_text.config(state=tk.DISABLED)
            return

        try:
            with open(log_file_path, "r") as f:
                lines = f.readlines()
                recent_lines = lines[-200:]
                self.log_text.insert("1.0", "".join(recent_lines))

        except Exception as e:
            self.log_text.insert("1.0", f"Error reading log file: {e}")

        self.log_text.config(state=tk.DISABLED)
        self.log_text.see(tk.END)
