import tkinter as tk
from tkinter import ttk, messagebox
from pathlib import Path
from limousine.storage.global_config import load_global_config, save_global_config
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)


class SettingsDialog(tk.Toplevel):
    def __init__(self, parent):
        super().__init__(parent)
        self.title("Settings")
        self.geometry("600x400")
        self.transient(parent)

        frame = ttk.Frame(self, padding=10)
        frame.pack(fill=tk.BOTH, expand=True)

        notebook = ttk.Notebook(frame)
        notebook.pack(fill=tk.BOTH, expand=True)

        projects_tab = self.create_projects_tab(notebook)
        notebook.add(projects_tab, text="Projects")

        info_tab = self.create_info_tab(notebook)
        notebook.add(info_tab, text="Info")

        button_frame = ttk.Frame(frame)
        button_frame.pack(fill=tk.X, pady=(10, 0))

        ttk.Button(button_frame, text="Close", command=self.destroy).pack()

    def create_projects_tab(self, parent):
        frame = ttk.Frame(parent, padding=10)

        ttk.Label(
            frame, text="Registered Projects", font=("", 11, "bold")
        ).pack(pady=(0, 10))

        list_frame = ttk.Frame(frame)
        list_frame.pack(fill=tk.BOTH, expand=True)

        scrollbar = ttk.Scrollbar(list_frame)
        scrollbar.pack(side=tk.RIGHT, fill=tk.Y)

        self.projects_listbox = tk.Listbox(
            list_frame, yscrollcommand=scrollbar.set, font=("", 9)
        )
        self.projects_listbox.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        scrollbar.config(command=self.projects_listbox.yview)

        self.load_projects()

        button_frame = ttk.Frame(frame)
        button_frame.pack(fill=tk.X, pady=(10, 0))

        ttk.Button(
            button_frame, text="Remove Selected", command=self.remove_selected_project
        ).pack(side=tk.LEFT, padx=5)

        ttk.Button(button_frame, text="Refresh", command=self.load_projects).pack(
            side=tk.LEFT, padx=5
        )

        return frame

    def create_info_tab(self, parent):
        frame = ttk.Frame(parent, padding=10)

        ttk.Label(
            frame, text="Application Information", font=("", 11, "bold")
        ).pack(pady=(0, 10))

        info_frame = ttk.Frame(frame)
        info_frame.pack(fill=tk.BOTH, expand=True)

        log_file_path = Path.home() / ".limousine" / "logs" / "limousine.log"
        config_path = Path.home() / ".limousine" / "config.json"

        info_items = [
            ("Log File:", str(log_file_path)),
            ("Config File:", str(config_path)),
            ("Version:", self.get_version()),
        ]

        for label, value in info_items:
            row = ttk.Frame(info_frame)
            row.pack(fill=tk.X, pady=5)

            ttk.Label(row, text=label, font=("", 9, "bold"), width=15).pack(
                side=tk.LEFT, padx=5
            )
            ttk.Label(row, text=value, font=("", 9)).pack(side=tk.LEFT, padx=5)

        return frame

    def load_projects(self):
        self.projects_listbox.delete(0, tk.END)

        global_config = load_global_config()
        for project_path in global_config.projects:
            self.projects_listbox.insert(tk.END, str(project_path))

    def remove_selected_project(self):
        selection = self.projects_listbox.curselection()
        if not selection:
            messagebox.showwarning("No Selection", "Please select a project to remove")
            return

        index = selection[0]
        project_path = self.projects_listbox.get(index)

        confirmed = messagebox.askyesno(
            "Confirm Removal",
            f"Remove this project from the list?\n\n{project_path}\n\n"
            "Note: This will not delete the project files.",
        )

        if confirmed:
            global_config = load_global_config()
            global_config.projects = [
                p for p in global_config.projects if str(p) != project_path
            ]
            save_global_config(global_config)
            self.load_projects()
            messagebox.showinfo("Removed", "Project removed from list")

    def get_version(self) -> str:
        try:
            from importlib.metadata import version

            return version("limousine")
        except Exception:
            return "0.1.0"
