import tkinter as tk
from tkinter import ttk, scrolledtext
import subprocess
import threading
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)


class CommandDialog(tk.Toplevel):
    def __init__(self, parent, title: str, command: str, working_dir):
        super().__init__(parent)
        self.title(title)
        self.geometry("700x500")
        self.transient(parent)

        self.command = command
        self.working_dir = working_dir
        self.process = None
        self.cancelled = False

        frame = ttk.Frame(self, padding=10)
        frame.pack(fill=tk.BOTH, expand=True)

        ttk.Label(frame, text=f"Running: {command}", wraplength=660).pack(
            pady=(0, 10)
        )

        output_frame = ttk.LabelFrame(frame, text="Output", padding=10)
        output_frame.pack(fill=tk.BOTH, expand=True, pady=(0, 10))

        self.output_text = scrolledtext.ScrolledText(
            output_frame, wrap=tk.WORD, height=20, font=("Courier", 9)
        )
        self.output_text.pack(fill=tk.BOTH, expand=True)

        button_frame = ttk.Frame(frame)
        button_frame.pack(fill=tk.X)

        self.cancel_button = ttk.Button(
            button_frame, text="Cancel", command=self.on_cancel
        )
        self.cancel_button.pack(side=tk.LEFT, padx=5)

        self.close_button = ttk.Button(
            button_frame, text="Close", command=self.destroy, state=tk.DISABLED
        )
        self.close_button.pack(side=tk.RIGHT, padx=5)

        self.protocol("WM_DELETE_WINDOW", self.on_close)

        self.start_command()

    def start_command(self):
        def run_command():
            try:
                self.process = subprocess.Popen(
                    self.command,
                    shell=True,
                    cwd=self.working_dir,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    bufsize=1,
                )

                for line in iter(self.process.stdout.readline, ""):
                    if self.cancelled:
                        break
                    self.after(0, self.append_output, line)

                self.process.wait()
                return_code = self.process.returncode

                if not self.cancelled:
                    self.after(0, self.show_completion, return_code)

            except Exception as e:
                logger.error(f"Command execution failed: {e}", exc_info=True)
                self.after(0, self.append_output, f"\nError: {e}\n")
                self.after(0, self.show_completion, -1)

        thread = threading.Thread(target=run_command, daemon=True)
        thread.start()

    def append_output(self, text: str):
        self.output_text.insert(tk.END, text)
        self.output_text.see(tk.END)

    def show_completion(self, return_code: int):
        if return_code == 0:
            status = "Command completed successfully"
        else:
            status = f"Command failed with exit code {return_code}"

        self.append_output(f"\n{'-' * 60}\n{status}\n")

        self.cancel_button.config(state=tk.DISABLED)
        self.close_button.config(state=tk.NORMAL)

    def on_cancel(self):
        if self.process and self.process.poll() is None:
            self.cancelled = True
            self.process.terminate()
            self.append_output("\n\nCommand cancelled by user\n")
            self.cancel_button.config(state=tk.DISABLED)
            self.close_button.config(state=tk.NORMAL)

    def on_close(self):
        if self.process and self.process.poll() is None:
            self.on_cancel()
        else:
            self.destroy()
