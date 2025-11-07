# Limousine Implementation Plan

3-stage implementation plan for the limousine project management tool.

## Stage 1: Core Infrastructure & Data Layer

### 1.1 Project Structure
- `limousine/main.py` - Entry point
- `limousine/models/` - Data models
- `limousine/storage/` - Persistence layer
- `limousine/process/` - Process management
- `limousine/utils/` - Shared utilities

### 1.2 Data Models (`limousine/models/`)
- `config.py` - Dataclasses for:
  - GlobalConfig (limousine-project list)
  - ProjectConfig (modules, docker-services)
  - Module (name, git-repo-url, clone-path, services, config)
  - Service (commands dict)
  - DockerService (commands dict)
- `state.py` - Runtime state classes:
  - AppState (current-project-file, modules, docker-services)
  - ProcessState (state, last-error, pid, start-time, output)
  - SourceState (cloned bool)
  - ServiceState (command-state dict)
  - ModuleState (services, source-state)

### 1.3 Storage Layer (`limousine/storage/`)
- `global_config.py`:
  - load_global_config() -> GlobalConfig
  - save_global_config(config)
  - get_global_config_path() -> Path (~/.limousine)
- `project_config.py`:
  - load_project_config(path) -> ProjectConfig
  - save_project_config(config, path)
  - validate_project_config(config) -> bool

### 1.4 Process Management (`limousine/process/`)
- `manager.py`:
  - start_command(service, command, env_vars) -> ProcessState
  - stop_command(pid)
  - check_process_running(pid) -> bool
  - cleanup_stale_pidfile(pidfile_path)
- `pidfile.py`:
  - create_pidfile(service_name, command, pid) -> Path (.limousine/pids/)
  - remove_pidfile(path)
  - read_pidfile(path) -> int | None
- `environment.py`:
  - load_env_file(path) -> dict
  - merge_env_vars(system_env, env_file, secrets_file) -> dict

### 1.5 Utilities (`limousine/utils/`)
- `logging_config.py` - Configure logging to stdout + file
- `path_utils.py` - Path resolution helpers

### Deliverables
- All data models with type hints
- Storage layer with JSON read/write
- Process management with pid file handling
- Env file loading with dotenv-style parsing
- Unit tests for models and storage

---

## Stage 2: UI Foundation & Dashboard

### 2.1 Application Structure (`limousine/ui/`)
- `app.py` - Main Tkinter application class:
  - LimousineApp(tk.Tk)
  - initialize() - Load config, setup state
  - run() - Main event loop
- `startup.py`:
  - show_project_selector(projects) -> Path | None
  - handle_first_run() -> Path
  - load_or_select_project() -> ProjectConfig

### 2.2 Main Window (`limousine/ui/`)
- `main_window.py`:
  - MainWindow(ttk.Frame)
  - create_menu_bar()
  - create_tab_container()
  - switch_project()
  - show_about_dialog()

### 2.3 Dashboard Tab (`limousine/ui/dashboard/`)
- `dashboard.py`:
  - DashboardTab(ttk.Frame)
  - render_modules(modules)
  - render_docker_services(services)
- `module_widget.py`:
  - ModuleWidget(ttk.Frame)
  - show_module_menu() - Clone, update env
  - render_services(services)
- `service_row.py`:
  - ServiceRow(ttk.Frame)
  - create_start_stop_button()
  - update_status(state)
  - on_start_clicked()
  - on_stop_clicked()

### 2.4 State Management
- `limousine/state_manager.py`:
  - StateManager class
  - load_project(project_path)
  - get_service_state(module, service) -> ProcessState
  - update_service_state(module, service, state)
  - subscribe_to_changes(callback)

### 2.5 Basic Actions (`limousine/actions/`)
- `module_actions.py`:
  - clone_repository(module) - Execute git clone
  - check_module_cloned(module) -> bool
- `service_actions.py`:
  - start_service(module, service)
  - stop_service(module, service)
  - get_service_status(module, service) -> str

### Deliverables
- Functional Tkinter app with startup flow
- Project selector for multiple projects
- Dashboard showing all modules and services
- Working start/stop buttons
- Basic state management and UI updates

---

## Stage 3: Advanced Features & Polish

### 3.1 Service Tabs (`limousine/ui/service_tab/`)
- `service_tab.py`:
  - ServiceTab(ttk.Frame)
  - create_control_bar() - Start/stop, command dropdown
  - create_log_viewer()
  - stream_output(process_state)
- `log_viewer.py`:
  - LogViewer(tk.Text)
  - append_line(text)
  - auto_scroll()
  - clear()

### 3.2 Dynamic Tab Management
- `limousine/ui/tab_manager.py`:
  - TabManager class
  - add_service_tab(module, service)
  - remove_tab(tab_id)
  - switch_to_tab(tab_id)
  - create_tab_on_demand()

### 3.3 Command Execution UI (`limousine/ui/dialogs/`)
- `command_dialog.py`:
  - CommandDialog(tk.Toplevel)
  - show_progress(command)
  - stream_command_output()
  - show_completion_status()
- `progress_dialog.py`:
  - ProgressDialog(tk.Toplevel)
  - show_spinner()
  - add_cancel_button()
  - update_message(text)

### 3.4 Env File Management (`limousine/env/`)
- `env_updater.py`:
  - update_env_files(module)
  - copy_source_to_active(source, target)
  - merge_env_files(source, active) -> dict (added, removed, warnings)
  - show_update_summary(changes)
- `env_dialog.py`:
  - EnvUpdateDialog(tk.Toplevel)
  - show_changes(added, removed)
  - confirm_update() -> bool

### 3.5 Error Handling & Recovery
- `limousine/process/recovery.py`:
  - handle_stale_pidfile(pidfile, service)
  - prompt_kill_process(pid) -> bool
  - cleanup_crashed_processes()
- `limousine/ui/dialogs/error_dialog.py`:
  - show_error(message, details)
  - show_exception(exc)

### 3.6 Settings & About (`limousine/ui/dialogs/`)
- `about_dialog.py`:
  - AboutDialog(tk.Toplevel)
  - show_version() - Use importlib.metadata
  - show_logs()
  - create_log_viewer()
- `settings_dialog.py`:
  - SettingsDialog(tk.Toplevel)
  - manage_projects()
  - configure_logging_level()

### 3.7 Background Task Management
- `limousine/async_ops/`:
  - `task_runner.py`:
    - run_with_progress(task_fn, on_complete, on_error)
    - cancel_task()
  - Use threading for long-running operations
  - Queue for thread-safe UI updates

### 3.8 Cross-Platform Support
- `limousine/platform/`:
  - `paths.py` - Platform-specific path handling
  - `process.py` - Platform-specific process checks (psutil alternative)
  - Use pathlib.Path throughout
  - Test on both Linux and macOS

### Deliverables
- Service tabs with real-time log streaming
- Command execution with progress dialogs
- Env file sync with change summary
- Stale pid file detection and recovery
- Settings dialog with log viewer
- Responsive UI with background task handling
- Full cross-platform support
- Comprehensive error handling and logging

---

## Implementation Notes

### Code Organization
- Max 150 lines per file (200 if necessary)
- No comments - self-documenting code
- Use type hints throughout
- Dataclasses over dicts where appropriate

### Logging Strategy
- Use standard logging module
- Log to stdout + `.limousine/logs/limousine.log`
- Always log exceptions with `exc_info=True`
- Never swallow exceptions without logging

### Testing Approach
- Unit tests for models, storage, process management
- Integration tests for service start/stop
- Manual testing for UI components

### Dependencies
- Minimal external deps (prefer stdlib)
- Use `uv` for dependency management
- Core: tkinter, subprocess, pathlib, json, logging
- Consider: psutil (for cross-platform process checks)

### State Synchronization
- StateManager as single source of truth
- Observer pattern for UI updates
- Periodic polling for process state (heartbeat)
- Thread-safe state updates

### Error Boundaries
- Try/catch at command execution level
- UI should never crash - show error dialogs
- Graceful degradation (continue if one service fails)
- Clear error messages for user action
