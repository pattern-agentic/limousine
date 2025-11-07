import tkinter as tk
from tkinter import scrolledtext


class LogViewer(scrolledtext.ScrolledText):
    def __init__(self, parent, **kwargs):
        super().__init__(
            parent,
            wrap=tk.WORD,
            font=("Courier", 9),
            state=tk.DISABLED,
            bg="black",
            fg="white",
            insertbackground="white",
            **kwargs,
        )
        self.auto_scroll_enabled = True
        self.max_lines = 5000

    def append_line(self, text: str) -> None:
        self.config(state=tk.NORMAL)
        self.insert(tk.END, text)

        line_count = int(self.index("end-1c").split(".")[0])
        if line_count > self.max_lines:
            lines_to_delete = line_count - self.max_lines
            self.delete("1.0", f"{lines_to_delete}.0")

        self.config(state=tk.DISABLED)

        if self.auto_scroll_enabled:
            self.see(tk.END)

    def append_lines(self, lines: list[str]) -> None:
        if not lines:
            return

        self.config(state=tk.NORMAL)
        for line in lines:
            if not line.endswith("\n"):
                line += "\n"
            self.insert(tk.END, line)

        line_count = int(self.index("end-1c").split(".")[0])
        if line_count > self.max_lines:
            lines_to_delete = line_count - self.max_lines
            self.delete("1.0", f"{lines_to_delete}.0")

        self.config(state=tk.DISABLED)

        if self.auto_scroll_enabled:
            self.see(tk.END)

    def clear(self) -> None:
        self.config(state=tk.NORMAL)
        self.delete("1.0", tk.END)
        self.config(state=tk.DISABLED)

    def toggle_auto_scroll(self) -> None:
        self.auto_scroll_enabled = not self.auto_scroll_enabled

    def set_max_lines(self, max_lines: int) -> None:
        self.max_lines = max_lines
