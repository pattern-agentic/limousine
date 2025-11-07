import tkinter as tk
from tkinter import messagebox
from pathlib import Path
from limousine.state_manager import StateManager
from limousine.storage.project_config import load_project_config, validate_project_config
from limousine.ui.main_window import MainWindow
from limousine.ui.welcome_screen import WelcomeScreen
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
        self.current_view = None

        if self.project_path:
            self.load_project(self.project_path)
        else:
            self.show_welcome_screen()

    def show_welcome_screen(self):
        def do_show():
            if self.current_view:
                self.current_view.destroy()
                self.current_view = None

            self.title("Limousine")
            self.current_view = WelcomeScreen(self, self.on_project_selected)

        self.after(0, do_show)

    def on_project_selected(self, project_path: Path):
        self.after(0, lambda: self.load_project(project_path))

    def load_project(self, project_path: Path):
        if not project_path.exists():
            def show_error():
                messagebox.showerror(
                    "Project Not Found",
                    f"Project file not found:\n{project_path}",
                )
                self.show_welcome_screen()
            self.after(0, show_error)
            return

        try:
            project_config = load_project_config(project_path)

            if not validate_project_config(project_config):
                def show_error():
                    messagebox.showerror(
                        "Invalid Project",
                        "The project configuration is invalid.",
                    )
                    self.show_welcome_screen()
                self.after(0, show_error)
                return

            self.state_manager.load_project(project_path)
            self.project_path = project_path

            def complete_load():
                if self.current_view:
                    self.current_view.destroy()
                    self.current_view = None

                self.title(f"Limousine - {project_path.name}")

                self.main_window = MainWindow(
                    self,
                    project_config,
                    project_path,
                    self.state_manager,
                )

                logger.info(f"Loaded project: {project_path}")

            self.after(0, complete_load)

        except Exception as e:
            logger.error(f"Failed to load project: {e}", exc_info=True)
            def show_error():
                messagebox.showerror(
                    "Load Error",
                    f"Failed to load project:\n{str(e)}",
                )
                self.show_welcome_screen()
            self.after(0, show_error)

    def run(self):
        self.mainloop()
