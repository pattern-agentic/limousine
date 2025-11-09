import tkinter as tk
from tkinter import ttk, messagebox
from pathlib import Path
from limousine.models.config import Module
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)


class EnvCompareDialog(tk.Toplevel):
    def __init__(self, parent, module: Module, project_path: Path):
        super().__init__(parent)
        self.module = module
        self.project_path = project_path

        self.title(f"Environment Variables - {module.name}")
        self.geometry("1000x600")

        if not module.config:
            messagebox.showinfo("No Configuration", "This module has no environment configuration")
            self.destroy()
            return

        self.source_env_file = module.config.source_env_file
        self.active_env_file = module.config.active_env_file

        if not self.source_env_file or not self.active_env_file:
            messagebox.showinfo("No Configuration", "Environment file paths not configured")
            self.destroy()
            return

        self.create_widgets()
        self.load_env_files()

    def create_widgets(self):
        header_frame = ttk.Frame(self, padding=10)
        header_frame.pack(fill=tk.X)

        ttk.Label(
            header_frame,
            text=f"Environment Variables - {self.module.name}",
            font=("", 12, "bold"),
        ).pack()

        content_frame = ttk.Frame(self, padding=10)
        content_frame.pack(fill=tk.BOTH, expand=True)

        source_frame = ttk.LabelFrame(
            content_frame, text=f"Source: {self.source_env_file}", padding=10
        )
        source_frame.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=(0, 5))

        self.source_text = tk.Text(
            source_frame,
            wrap=tk.NONE,
            font=("Courier", 10),
            bg="#f5f5f5",
        )
        source_scrollbar_y = ttk.Scrollbar(
            source_frame, orient=tk.VERTICAL, command=self.source_text.yview
        )
        source_scrollbar_x = ttk.Scrollbar(
            source_frame, orient=tk.HORIZONTAL, command=self.source_text.xview
        )
        self.source_text.config(
            yscrollcommand=source_scrollbar_y.set, xscrollcommand=source_scrollbar_x.set
        )
        self.source_text.grid(row=0, column=0, sticky="nsew")
        source_scrollbar_y.grid(row=0, column=1, sticky="ns")
        source_scrollbar_x.grid(row=1, column=0, sticky="ew")
        source_frame.grid_rowconfigure(0, weight=1)
        source_frame.grid_columnconfigure(0, weight=1)

        active_frame = ttk.LabelFrame(
            content_frame, text=f"Active: {self.active_env_file}", padding=10
        )
        active_frame.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=(5, 0))

        self.active_text = tk.Text(
            active_frame,
            wrap=tk.NONE,
            font=("Courier", 10),
            bg="#f5f5f5",
        )
        active_scrollbar_y = ttk.Scrollbar(
            active_frame, orient=tk.VERTICAL, command=self.active_text.yview
        )
        active_scrollbar_x = ttk.Scrollbar(
            active_frame, orient=tk.HORIZONTAL, command=self.active_text.xview
        )
        self.active_text.config(
            yscrollcommand=active_scrollbar_y.set, xscrollcommand=active_scrollbar_x.set
        )
        self.active_text.grid(row=0, column=0, sticky="nsew")
        active_scrollbar_y.grid(row=0, column=1, sticky="ns")
        active_scrollbar_x.grid(row=1, column=0, sticky="ew")
        active_frame.grid_rowconfigure(0, weight=1)
        active_frame.grid_columnconfigure(0, weight=1)

        button_frame = ttk.Frame(self, padding=10)
        button_frame.pack(fill=tk.X)

        self.copy_button = ttk.Button(
            button_frame,
            text=f"Copy from {self.source_env_file}",
            command=self.on_copy_clicked,
            state=tk.DISABLED,
        )
        self.copy_button.pack(side=tk.LEFT, padx=5)

        ttk.Button(button_frame, text="Close", command=self.destroy).pack(
            side=tk.RIGHT, padx=5
        )

    def load_env_files(self):
        source_path = self.project_path / self.source_env_file
        active_path = self.project_path / self.active_env_file

        if source_path.exists():
            try:
                with open(source_path, "r") as f:
                    content = f.read()
                self.source_text.insert("1.0", content)
                self.source_text.config(state=tk.DISABLED)
            except Exception as e:
                logger.error(f"Error reading source env file: {e}", exc_info=True)
                self.source_text.insert("1.0", f"Error reading file: {e}")
                self.source_text.config(state=tk.DISABLED)
        else:
            self.source_text.insert("1.0", f"File not found: {self.source_env_file}")
            self.source_text.config(state=tk.DISABLED)

        if active_path.exists():
            try:
                with open(active_path, "r") as f:
                    content = f.read()
                self.active_text.insert("1.0", content)
                self.active_text.config(state=tk.DISABLED)
            except Exception as e:
                logger.error(f"Error reading active env file: {e}", exc_info=True)
                self.active_text.insert("1.0", f"Error reading file: {e}")
                self.active_text.config(state=tk.DISABLED)
        else:
            self.active_text.insert(
                "1.0",
                f"Env file missing.\n\nCopy from {self.source_env_file}?",
            )
            self.active_text.config(state=tk.DISABLED)
            if source_path.exists():
                self.copy_button.config(state=tk.NORMAL)

    def on_copy_clicked(self):
        source_path = self.project_path / self.source_env_file
        active_path = self.project_path / self.active_env_file

        try:
            import shutil

            shutil.copy2(source_path, active_path)
            messagebox.showinfo(
                "Success", f"Copied {self.source_env_file} to {self.active_env_file}"
            )

            self.active_text.config(state=tk.NORMAL)
            self.active_text.delete("1.0", tk.END)
            with open(active_path, "r") as f:
                self.active_text.insert("1.0", f.read())
            self.active_text.config(state=tk.DISABLED)
            self.copy_button.config(state=tk.DISABLED)

        except Exception as e:
            logger.error(f"Error copying env file: {e}", exc_info=True)
            messagebox.showerror("Error", f"Failed to copy file: {e}")
