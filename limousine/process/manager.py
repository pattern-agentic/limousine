import subprocess
import psutil
import threading
import os
import signal
from pathlib import Path
from datetime import datetime
from collections import deque
from limousine.models.state import ProcessState
from limousine.process.pidfile import create_pidfile, remove_pidfile, read_pidfile
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)

_active_processes: dict[int, subprocess.Popen] = {}


def start_command(
    service_name: str,
    command_name: str,
    command: str,
    working_dir: Path,
    env_vars: dict[str, str],
    pids_dir: Path,
    buffer_size: int = 5000,
) -> ProcessState:
    try:
        logger.info(
            f"Starting {service_name}:{command_name} in {working_dir}: {command}"
        )

        process = subprocess.Popen(
            command,
            shell=True,
            start_new_session=True,
            cwd=working_dir,
            env=env_vars,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )

        pidfile_path = create_pidfile(pids_dir, service_name, command_name, process.pid)

        state = ProcessState(
            state="running",
            pid=process.pid,
            start_time=datetime.now(),
        )

        state.output_buffer = deque(maxlen=buffer_size)

        _active_processes[process.pid] = process

        def capture_output():
            try:
                for line in iter(process.stdout.readline, ""):
                    if not line:
                        break
                    state.add_output(line)
                process.wait()
            except Exception as e:
                logger.error(f"Error capturing output: {e}", exc_info=True)
            finally:
                if process.pid in _active_processes:
                    del _active_processes[process.pid]

        thread = threading.Thread(target=capture_output, daemon=True)
        thread.start()

        logger.info(
            f"Started {service_name}:{command_name} with PID {process.pid}"
        )
        return state

    except Exception as e:
        logger.error(
            f"Failed to start {service_name}:{command_name}: {e}", exc_info=True
        )
        return ProcessState(state="failed", last_error=str(e))


def stop_command(
    pid: int,
    pidfile_path: Path | None = None,
    signal_name: str = "SIGINT",
    process_state: ProcessState | None = None,
) -> tuple[bool, str | None]:
    try:
        if not check_process_running(pid):
            logger.warning(f"Process {pid} is not running")
            if pidfile_path:
                remove_pidfile(pidfile_path)
            return False, None

        process = psutil.Process(pid)

        try:
            pgid = os.getpgid(pid)
        except OSError as e:
            logger.warning(f"Could not get process group for PID {pid}: {e}")
            pgid = None

        if signal_name == "SIGINT":
            logger.info(f"Sending SIGINT to process group {pgid if pgid else pid}, waiting for process to terminate...")
            if process_state:
                process_state.add_output("Sent SIGINT, waiting for process to terminate...\n")
            if pgid:
                os.killpg(pgid, signal.SIGINT)
            else:
                process.send_signal(signal.SIGINT)
            next_stage = "SIGTERM"
        elif signal_name == "SIGTERM":
            logger.info(f"Sending SIGTERM to process group {pgid if pgid else pid}")
            if process_state:
                process_state.add_output("Sent SIGTERM to process\n")
            if pgid:
                os.killpg(pgid, signal.SIGTERM)
            else:
                process.terminate()
            next_stage = "SIGKILL"
        elif signal_name == "SIGKILL":
            logger.info(f"Sending SIGKILL to process group {pgid if pgid else pid}")
            if process_state:
                process_state.add_output("Sent SIGKILL to process\n")
            if pgid:
                os.killpg(pgid, signal.SIGKILL)
            else:
                children = process.children(recursive=True)
                for child in children:
                    try:
                        logger.info(f"Killing child process {child.pid}")
                        child.kill()
                    except psutil.NoSuchProcess:
                        pass
                process.kill()
            next_stage = None
        else:
            logger.error(f"Unknown signal: {signal_name}")
            return False, None

        try:
            process.wait(timeout=0.5)
            logger.info(f"Process {pid} terminated")
            if process_state:
                process_state.add_output("Process terminated\n")
            if pidfile_path:
                remove_pidfile(pidfile_path)
            return True, None
        except psutil.TimeoutExpired:
            return False, next_stage

    except psutil.NoSuchProcess:
        logger.warning(f"Process {pid} does not exist")
        if pidfile_path:
            remove_pidfile(pidfile_path)
        return False, None
    except Exception as e:
        logger.error(f"Failed to stop process {pid}: {e}", exc_info=True)
        return False, None


def check_process_running(pid: int) -> bool:
    try:
        return psutil.pid_exists(pid) and psutil.Process(pid).is_running()
    except psutil.NoSuchProcess:
        return False
    except Exception as e:
        logger.error(f"Error checking if process {pid} is running: {e}", exc_info=True)
        return False


def cleanup_stale_pidfile(pidfile_path: Path) -> bool:
    pid = read_pidfile(pidfile_path)

    if pid is None:
        logger.warning(f"Could not read PID from {pidfile_path}")
        remove_pidfile(pidfile_path)
        return True

    if not check_process_running(pid):
        logger.info(f"Cleaning up stale pidfile {pidfile_path} for PID {pid}")
        remove_pidfile(pidfile_path)
        return True

    return False
