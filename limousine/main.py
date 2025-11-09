from pathlib import Path
from limousine.utils.logging_config import setup_logging
from limousine.ui.app import LimousineApp
import tkinter as tk
import logging

print("Limousine starting..")
print("Tcl/Tk version:", tk.Tcl().eval('info patchlevel'))


def main():
    limousine_home = Path.home() / ".limousine"
    log_file = limousine_home / "logs" / "limousine.log"

    setup_logging(log_file=log_file)

    app = LimousineApp()
    app.run()


if __name__ == "__main__":
    main()
