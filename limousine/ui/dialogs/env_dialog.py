import tkinter as tk
from tkinter import ttk, scrolledtext, messagebox
from pathlib import Path
from limousine.models.config import Module
from limousine.env.env_updater import update_env_files, apply_env_update
from limousine.utils.path_utils import resolve_path
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)


class EnvUpdateDialog(tk.Toplevel):
    def __init__(self, parent, module: Module, project_root: Path):
        super().__init__(parent)
        self.title(f"Update Env Files - {module.name}")
        self.geometry("600x500")
        self.transient(parent)
        self.grab_set()

        self.module = module
        self.project_root = project_root
        self.result = None

        frame = ttk.Frame(self, padding=10)
        frame.pack(fill=tk.BOTH, expand=True)

        ttk.Label(
            frame,
            text=f"Checking env file changes for {module.name}...",
            font=("", 11, "bold"),
        ).pack(pady=(0, 10))

        self.changes_frame = ttk.Frame(frame)
        self.changes_frame.pack(fill=tk.BOTH, expand=True, pady=(0, 10))

        button_frame = ttk.Frame(frame)
        button_frame.pack(fill=tk.X)

        self.apply_button = ttk.Button(
            button_frame, text="Apply Update", command=self.on_apply, state=tk.DISABLED
        )
        self.apply_button.pack(side=tk.LEFT, padx=5)

        ttk.Button(button_frame, text="Cancel", command=self.destroy).pack(
            side=tk.RIGHT, padx=5
        )

        self.after(100, self.load_changes)

    def load_changes(self):
        result = update_env_files(self.module, self.project_root)

        if not result.get("success"):
            error_msg = result.get("error", "Unknown error")
            messagebox.showerror("Error", f"Failed to check env files:\n{error_msg}")
            self.destroy()
            return

        self.result = result
        self.show_changes(result)

    def show_changes(self, result: dict):
        for widget in self.changes_frame.winfo_children():
            widget.destroy()

        added = result.get("added", [])
        removed = result.get("removed", [])
        changed = result.get("changed", [])
        secrets_warnings = result.get("secrets_warnings", [])

        text_widget = scrolledtext.ScrolledText(
            self.changes_frame, wrap=tk.WORD, height=20, font=("Courier", 9)
        )
        text_widget.pack(fill=tk.BOTH, expand=True)

        if added:
            text_widget.insert(tk.END, f"Added keys ({len(added)}):\n", "header")
            for key in sorted(added):
                text_widget.insert(tk.END, f"  + {key}\n", "added")
            text_widget.insert(tk.END, "\n")

        if removed:
            text_widget.insert(tk.END, f"Removed keys ({len(removed)}):\n", "header")
            for key in sorted(removed):
                text_widget.insert(tk.END, f"  - {key}\n", "removed")
            text_widget.insert(tk.END, "\n")

        if changed:
            text_widget.insert(tk.END, f"Changed keys ({len(changed)}):\n", "header")
            for key in sorted(changed):
                text_widget.insert(tk.END, f"  ~ {key}\n", "changed")
            text_widget.insert(tk.END, "\n")

        if not added and not removed and not changed:
            text_widget.insert(tk.END, "No changes detected.\n", "info")

        if secrets_warnings:
            text_widget.insert(tk.END, "\nSecrets Warnings:\n", "warning")
            for warning in secrets_warnings:
                text_widget.insert(tk.END, f"  ! {warning}\n", "warning")

        text_widget.tag_config("header", font=("", 10, "bold"))
        text_widget.tag_config("added", foreground="green")
        text_widget.tag_config("removed", foreground="red")
        text_widget.tag_config("changed", foreground="orange")
        text_widget.tag_config("warning", foreground="red", font=("", 9, "bold"))
        text_widget.tag_config("info", foreground="gray")

        text_widget.config(state=tk.DISABLED)

        if added or removed or changed:
            self.apply_button.config(state=tk.NORMAL)

    def on_apply(self):
        if not self.module.config:
            return

        clone_path = resolve_path(self.module.clone_path, self.project_root)
        source_path = clone_path / self.module.config.source_env_file
        active_path = clone_path / self.module.config.active_env_file

        confirmed = messagebox.askyesno(
            "Confirm Update",
            "This will update the active env file with values from the source.\n\n"
            "Existing values will be preserved and new values will be added.\n\n"
            "Continue?",
        )

        if not confirmed:
            return

        success = apply_env_update(source_path, active_path, mode="merge")

        if success:
            messagebox.showinfo("Success", "Env file updated successfully")
            self.destroy()
        else:
            messagebox.showerror("Error", "Failed to update env file")
