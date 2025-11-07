import tkinter as tk
from tkinter import ttk, scrolledtext, messagebox
import traceback
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)


def show_error(message: str, details: str | None = None, parent=None) -> None:
    logger.error(f"Error: {message}")
    if details:
        logger.error(f"Details: {details}")

    if details:
        dialog = tk.Toplevel(parent)
        dialog.title("Error")
        dialog.geometry("600x400")

        if parent and parent.winfo_exists():
            dialog.transient(parent)

        frame = ttk.Frame(dialog, padding=10)
        frame.pack(fill=tk.BOTH, expand=True)

        ttk.Label(frame, text=message, wraplength=560, font=("", 10, "bold")).pack(
            pady=(0, 10)
        )

        details_frame = ttk.LabelFrame(frame, text="Details", padding=10)
        details_frame.pack(fill=tk.BOTH, expand=True, pady=(0, 10))

        text_widget = scrolledtext.ScrolledText(
            details_frame, wrap=tk.WORD, height=15, font=("Courier", 9)
        )
        text_widget.pack(fill=tk.BOTH, expand=True)
        text_widget.insert("1.0", details)
        text_widget.config(state=tk.DISABLED)

        ttk.Button(frame, text="Close", command=dialog.destroy).pack()
    else:
        messagebox.showerror("Error", message)


def show_exception(exc: Exception, parent=None) -> None:
    logger.error(f"Exception: {exc}", exc_info=True)

    tb = traceback.format_exception(type(exc), exc, exc.__traceback__)
    details = "".join(tb)

    show_error(str(exc), details, parent)
