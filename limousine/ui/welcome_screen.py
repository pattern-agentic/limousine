import tkinter as tk
from tkinter import ttk, filedialog
import threading
from pathlib import Path
from limousine.storage.global_config import load_global_config, save_global_config
from limousine.utils.logging_config import get_logger


logger = get_logger(__name__)


class WelcomeScreen(ttk.Frame):
    def __init__(self, parent, on_project_selected):
        super().__init__(parent, padding=20)
        self.on_project_selected = on_project_selected
        self.pack(fill=tk.BOTH, expand=True)

        self.create_widgets()

    def create_widgets(self):
        container = ttk.Frame(self)
        container.place(relx=0.5, rely=0.5, anchor=tk.CENTER)

        ttk.Label(
            container,
            text="Welcome to Limousine",
            font=("", 20, "bold"),
        ).pack(pady=(0, 10))

        ttk.Label(
            container,
            text="Microservice Development Environment Manager",
            font=("", 12),
        ).pack(pady=(0, 30))

        global_config = load_global_config()

        if global_config.projects:
            ttk.Label(
                container,
                text="Recent Projects:",
                font=("", 11, "bold"),
            ).pack(pady=(0, 10))

            list_frame = ttk.Frame(container)
            list_frame.pack(pady=(0, 20))

            scrollbar = ttk.Scrollbar(list_frame)
            scrollbar.pack(side=tk.RIGHT, fill=tk.Y)

            self.projects_listbox = tk.Listbox(
                list_frame,
                yscrollcommand=scrollbar.set,
                font=("", 10),
                width=50,
                height=8,
            )
            self.projects_listbox.pack(side=tk.LEFT)
            scrollbar.config(command=self.projects_listbox.yview)

            for project in global_config.projects:
                self.projects_listbox.insert(tk.END, str(project))

            self.projects_listbox.bind("<Double-Button-1>", self.on_project_double_click)

            button_frame = ttk.Frame(container)
            button_frame.pack(pady=(0, 10))

            ttk.Button(
                button_frame, text="Open Selected", command=self.on_open_selected
            ).pack(side=tk.LEFT, padx=5)

            ttk.Button(
                button_frame, text="Browse...", command=self.on_browse
            ).pack(side=tk.LEFT, padx=5)
        else:
            ttk.Label(
                container,
                text="No recent projects found.",
                font=("", 10),
            ).pack(pady=(0, 20))

            ttk.Button(
                container,
                text="Select Project File",
                command=self.on_browse,
            ).pack()

    def on_project_double_click(self, event):
        self.on_open_selected()

    def on_open_selected(self):
        selection = self.projects_listbox.curselection()
        if selection:
            global_config = load_global_config()
            project_path = global_config.projects[selection[0]]
            self.after(0, lambda: self.on_project_selected(project_path))

    def on_browse(self):
        file_path = filedialog.askopenfilename(
            title="Select .limousine-proj file",
            filetypes=[("Limousine Project", "*.limousine-proj"), ("All files", "*.*")],
        )
        
        if file_path:
            project_path = Path(file_path)
        
            global_config = load_global_config()
            if project_path not in global_config.projects:
                global_config.projects.append(project_path)
                save_global_config(global_config)
        
            self.after(0, lambda: self.on_project_selected(project_path))
