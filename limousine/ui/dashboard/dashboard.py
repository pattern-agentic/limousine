import tkinter as tk
from tkinter import ttk
from limousine.state_manager import StateManager
from limousine.ui.dashboard.project_widget import ProjectWidget
from limousine.ui.dashboard.service_row import ServiceRow
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)


class DashboardTab(ttk.Frame):
    def __init__(
        self,
        parent,
        state_manager: StateManager,
        tab_manager=None,
    ):
        super().__init__(parent, padding=10)
        self.state_manager = state_manager
        self.tab_manager = tab_manager

        self.create_widgets()

    def create_widgets(self):
        canvas = tk.Canvas(self, highlightthickness=0)
        scrollbar = ttk.Scrollbar(self, orient=tk.VERTICAL, command=canvas.yview)
        scrollable_frame = ttk.Frame(canvas)

        scrollable_frame.bind(
            "<Configure>", lambda e: canvas.configure(scrollregion=canvas.bbox("all"))
        )

        canvas.create_window((0, 0), window=scrollable_frame, anchor="nw")
        canvas.configure(yscrollcommand=scrollbar.set)

        if self.state_manager.workspace_config:
            projects_label = ttk.Label(
                scrollable_frame, text="Projects", font=("", 14, "bold")
            )
            projects_label.pack(anchor="w", pady=(0, 10))

            self.render_projects(scrollable_frame)

        canvas.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        scrollbar.pack(side=tk.RIGHT, fill=tk.Y)

    def render_projects(self, parent):
        if not self.state_manager.workspace_config:
            return

        for project_name, project in self.state_manager.workspace_config.projects.items():
            project_widget = ProjectWidget(
                parent,
                project_name,
                project,
                self.state_manager,
                self.tab_manager,
            )
            project_widget.pack(fill=tk.X, pady=5, padx=5)
