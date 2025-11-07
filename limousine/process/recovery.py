from pathlib import Path
from tkinter import messagebox
import psutil
from limousine.process.pidfile import read_pidfile, remove_pidfile
from limousine.process.manager import check_process_running, stop_command
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)


def handle_stale_pidfile(pidfile_path: Path, service_name: str) -> bool:
    pid = read_pidfile(pidfile_path)

    if pid is None:
        logger.warning(f"Could not read PID from {pidfile_path}")
        remove_pidfile(pidfile_path)
        return True

    if not check_process_running(pid):
        logger.info(f"Removing stale pidfile for {service_name} (PID {pid})")
        remove_pidfile(pidfile_path)
        return True

    should_kill = prompt_kill_process(service_name, pid)
    if should_kill:
        success = stop_command(pid, pidfile_path)
        if success:
            logger.info(f"Killed process {pid} for {service_name}")
            return True
        else:
            logger.error(f"Failed to kill process {pid}")
            return False

    return False


def prompt_kill_process(service_name: str, pid: int) -> bool:
    result = messagebox.askyesno(
        "Process Running",
        f"Service '{service_name}' has a running process (PID {pid}).\n\n"
        f"Do you want to kill this process?",
    )
    return result


def cleanup_crashed_processes(pids_dir: Path) -> int:
    if not pids_dir.exists():
        return 0

    cleaned_count = 0

    for pidfile in pids_dir.glob("*.pid"):
        pid = read_pidfile(pidfile)

        if pid is None:
            logger.info(f"Removing invalid pidfile: {pidfile.name}")
            remove_pidfile(pidfile)
            cleaned_count += 1
            continue

        if not check_process_running(pid):
            logger.info(f"Removing stale pidfile: {pidfile.name} (PID {pid})")
            remove_pidfile(pidfile)
            cleaned_count += 1

    if cleaned_count > 0:
        logger.info(f"Cleaned up {cleaned_count} stale pidfiles")

    return cleaned_count
