import tkinter as tk
from tkinter import ttk, filedialog, messagebox
from pathlib import Path
from limousine.storage.global_config import load_global_config, save_global_config
from limousine.models.config import GlobalConfig
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)


def show_project_selector(root: tk.Tk, projects: list[Path]) -> Path | None:
    dialog = tk.Toplevel(root)
    dialog.title("Select Project")
    dialog.geometry("500x400")

    root_visible = root.winfo_viewable()
    if root_visible:
        dialog.transient(root)

    dialog.grab_set()

    selected_project = None

    frame = ttk.Frame(dialog, padding=10)
    frame.pack(fill=tk.BOTH, expand=True)

    ttk.Label(frame, text="Select a project to open:", font=("", 12, "bold")).pack(
        pady=(0, 10)
    )

    listbox_frame = ttk.Frame(frame)
    listbox_frame.pack(fill=tk.BOTH, expand=True, pady=(0, 10))

    scrollbar = ttk.Scrollbar(listbox_frame)
    scrollbar.pack(side=tk.RIGHT, fill=tk.Y)

    listbox = tk.Listbox(
        listbox_frame, yscrollcommand=scrollbar.set, font=("", 10)
    )
    listbox.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
    scrollbar.config(command=listbox.yview)

    for project in projects:
        listbox.insert(tk.END, str(project))

    def on_select():
        nonlocal selected_project
        selection = listbox.curselection()
        if selection:
            selected_project = projects[selection[0]]
            dialog.destroy()

    def on_browse():
        nonlocal selected_project
        file_path = filedialog.askopenfilename(
            title="Select .limousine-proj file",
            filetypes=[("Limousine Project", "*.limousine-proj"), ("All files", "*.*")],
        )
        if file_path:
            selected_project = Path(file_path)
            dialog.destroy()

    def on_double_click(event):
        on_select()

    listbox.bind("<Double-Button-1>", on_double_click)

    button_frame = ttk.Frame(frame)
    button_frame.pack(fill=tk.X)

    ttk.Button(button_frame, text="Open", command=on_select).pack(
        side=tk.LEFT, padx=5
    )
    ttk.Button(button_frame, text="Browse...", command=on_browse).pack(
        side=tk.LEFT, padx=5
    )
    ttk.Button(button_frame, text="Cancel", command=dialog.destroy).pack(
        side=tk.RIGHT, padx=5
    )

    if not root_visible:
        dialog.update_idletasks()
        screen_width = dialog.winfo_screenwidth()
        screen_height = dialog.winfo_screenheight()
        x = (screen_width - dialog.winfo_width()) // 2
        y = (screen_height - dialog.winfo_height()) // 2
        dialog.geometry(f"+{x}+{y}")

    dialog.wait_window()
    return selected_project


def handle_first_run(root: tk.Tk) -> Path | None:
    messagebox.showinfo(
        "Welcome to Limousine",
        "Welcome to Limousine!\n\nPlease select a .limousine-proj file to get started.",
    )

    file_path = filedialog.askopenfilename(
        title="Select .limousine-proj file",
        filetypes=[("Limousine Project", "*.limousine-proj"), ("All files", "*.*")],
    )

    if file_path:
        return Path(file_path)

    return None


def load_or_select_project(root: tk.Tk) -> Path | None:
    global_config = load_global_config()

    if not global_config.projects:
        return handle_first_run(root)

    project_path = show_project_selector(root, global_config.projects)

    if project_path and project_path not in global_config.projects:
        global_config.projects.append(project_path)
        save_global_config(global_config)

    return project_path
