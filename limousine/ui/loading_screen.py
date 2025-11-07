import tkinter as tk
from tkinter import ttk


class LoadingScreen(ttk.Frame):
    def __init__(self, parent, message: str = "Loading..."):
        super().__init__(parent, padding=20)
        self.pack(fill=tk.BOTH, expand=True)

        container = ttk.Frame(self)
        container.place(relx=0.5, rely=0.5, anchor=tk.CENTER)

        self.message_label = ttk.Label(
            container,
            text=message,
            font=("", 12),
        )
        self.message_label.pack(pady=(0, 20))

        self.progress_bar = ttk.Progressbar(
            container,
            mode="indeterminate",
            length=300,
        )
        self.progress_bar.pack()
        self.progress_bar.start(10)

    def update_message(self, message: str):
        self.message_label.config(text=message)
        self.update_idletasks()

    def stop(self):
        self.progress_bar.stop()
