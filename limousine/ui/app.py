import tkinter as tk
from tkinter import messagebox
from pathlib import Path
from limousine.state_manager import StateManager
from limousine.storage.project_config import load_project_config, validate_project_config
from limousine.ui.main_window import MainWindow
from limousine.ui.startup import load_or_select_project
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)


class LimousineApp(tk.Tk):
    def __init__(self, project_path: Path | None = None):
        super().__init__()

        self.title("Limousine")
        self.geometry("900x600")

        self.state_manager = StateManager()
        self.project_path = project_path
        self.main_window = None

        self.withdraw()

        if not self.initialize():
            self.destroy()
            return

        self.deiconify()

    def initialize(self) -> bool:
        if not self.project_path:
            self.project_path = load_or_select_project(self)

        if not self.project_path:
            logger.info("No project selected, exiting")
            return False

        if not self.project_path.exists():
            messagebox.showerror(
                "Project Not Found",
                f"Project file not found:\n{self.project_path}",
            )
            return False

        try:
            project_config = load_project_config(self.project_path)

            if not validate_project_config(project_config):
                messagebox.showerror(
                    "Invalid Project",
                    "The project configuration is invalid.",
                )
                return False

            self.state_manager.load_project(self.project_path)

            self.title(f"Limousine - {self.project_path.name}")

            self.main_window = MainWindow(
                self,
                project_config,
                self.project_path,
                self.state_manager,
            )

            return True

        except Exception as e:
            logger.error(f"Failed to initialize project: {e}", exc_info=True)
            messagebox.showerror(
                "Initialization Error",
                f"Failed to load project:\n{str(e)}",
            )
            return False

    def run(self):
        if self.main_window:
            self.mainloop()
