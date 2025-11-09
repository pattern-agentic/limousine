import tkinter as tk
from tkinter import messagebox
from pathlib import Path
from limousine.state_manager import StateManager
from limousine.storage.workspace_config import load_workspace_config, validate_workspace_config
from limousine.ui.main_window import MainWindow
from limousine.ui.welcome_screen import WelcomeScreen
from limousine.ui.loading_screen import LoadingScreen
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)


class LimousineApp(tk.Tk):
    def __init__(self, workspace_path: Path | None = None):
        super().__init__()

        self.title("Limousine")
        self.geometry("900x600")

        self.state_manager = StateManager()
        self.workspace_path = workspace_path
        self.main_window = None
        self.current_view = None

        if self.workspace_path:
            self.load_workspace(self.workspace_path)
        else:
            self.show_welcome_screen()

    def show_welcome_screen(self):
        def do_show():
            if self.current_view:
                self.current_view.destroy()
                self.current_view = None

            self.title("Limousine")
            self.current_view = WelcomeScreen(self, self.on_workspace_selected)

        self.after(0, do_show)

    def show_loading_screen(self, message: str = "Loading workspace..."):
        if self.current_view:
            self.current_view.destroy()
            self.current_view = None

        self.current_view = LoadingScreen(self, message)
        self.update_idletasks()

    def on_workspace_selected(self, workspace_path: Path):
        self.after(0, lambda: self.load_workspace(workspace_path))

    def load_workspace(self, workspace_path: Path):
        self.show_loading_screen("Loading workspace...")

        if not workspace_path.exists():
            def show_error():
                messagebox.showerror(
                    "Workspace Not Found",
                    f"Workspace file not found:\n{workspace_path}",
                )
                self.show_welcome_screen()
            self.after(0, show_error)
            return

        try:
            workspace_config = load_workspace_config(workspace_path)

            if not validate_workspace_config(workspace_config):
                def show_error():
                    messagebox.showerror(
                        "Invalid Workspace",
                        "The workspace configuration is invalid.",
                    )
                    self.show_welcome_screen()
                self.after(0, show_error)
                return

            self.state_manager.load_workspace(workspace_path)
            self.workspace_path = workspace_path

            def complete_load():
                if isinstance(self.current_view, LoadingScreen):
                    self.current_view.update_message("Creating tabs...")

                if self.current_view:
                    self.current_view.destroy()
                    self.current_view = None

                self.title(f"Limousine - {workspace_config.name}")

                self.main_window = MainWindow(
                    self,
                    workspace_path,
                    self.state_manager,
                )

                logger.info(f"Loaded workspace: {workspace_path}")

            self.after(100, complete_load)

        except Exception as ex:
            msg = str(ex)
            logger.error(f"Failed to load workspace: {msg}", exc_info=True)
            def show_error():
                messagebox.showerror(
                    "Load Error",
                    f"Failed to load workspace:\n{str(msg)}",
                )
                self.show_welcome_screen()
            self.after(0, show_error)

    def run(self):
        self.mainloop()
