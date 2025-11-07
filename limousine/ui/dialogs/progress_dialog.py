import tkinter as tk
from tkinter import ttk


class ProgressDialog(tk.Toplevel):
    def __init__(self, parent, title: str, message: str, cancelable: bool = False):
        super().__init__(parent)
        self.title(title)
        self.geometry("400x150")

        self.cancelled = False
        self.on_cancel_callback = None

        frame = ttk.Frame(self, padding=20)
        frame.pack(fill=tk.BOTH, expand=True)

        self.message_label = ttk.Label(
            frame, text=message, wraplength=360, font=("", 10)
        )
        self.message_label.pack(pady=(0, 15))

        self.progress_bar = ttk.Progressbar(
            frame, mode="indeterminate", length=360
        )
        self.progress_bar.pack(pady=(0, 15))
        self.progress_bar.start(10)

        if cancelable:
            self.add_cancel_button()

        self.protocol("WM_DELETE_WINDOW", self.on_close)

        self.update_idletasks()
        self.transient(parent)
        self.grab_set()

        self.center_on_parent(parent)

    def center_on_parent(self, parent):
        self.update_idletasks()
        x = parent.winfo_x() + (parent.winfo_width() - self.winfo_width()) // 2
        y = parent.winfo_y() + (parent.winfo_height() - self.winfo_height()) // 2
        self.geometry(f"+{x}+{y}")

    def update_message(self, text: str) -> None:
        self.message_label.config(text=text)

    def add_cancel_button(self) -> None:
        button_frame = ttk.Frame(self)
        button_frame.pack(fill=tk.X, padx=20, pady=(0, 10))

        self.cancel_button = ttk.Button(
            button_frame, text="Cancel", command=self.on_cancel_clicked
        )
        self.cancel_button.pack()

    def on_cancel_clicked(self) -> None:
        self.cancelled = True
        if self.on_cancel_callback:
            self.on_cancel_callback()
        self.destroy()

    def on_close(self) -> None:
        if hasattr(self, "cancel_button"):
            self.on_cancel_clicked()

    def set_cancel_callback(self, callback) -> None:
        self.on_cancel_callback = callback

    def close(self) -> None:
        self.progress_bar.stop()
        self.destroy()
