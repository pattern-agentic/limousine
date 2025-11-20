import os
from pathlib import Path
from limousine.models.config import Module, DockerService
from limousine.models.state import ProcessState
from limousine.process.manager import start_command, stop_command, check_process_running
from limousine.process.environment import merge_env_vars
from limousine.utils.path_utils import resolve_path, get_limousine_dir
from limousine.state_manager import StateManager
from limousine.utils.logging_config import get_logger

logger = get_logger(__name__)


def start_service(
    module: Module,
    service_name: str,
    command_name: str,
    project_path: Path,
    state_manager: StateManager,
) -> ProcessState:
    service = module.services.get(service_name)
    if not service:
        return ProcessState(state="failed", last_error=f"Service {service_name} not found")

    command = service.commands.get(command_name)
    if not command:
        return ProcessState(state="failed", last_error=f"Command {command_name} not found")

    if not project_path.exists():
        return ProcessState(
            state="failed", last_error=f"Project not found at {project_path}"
        )

    env_vars = dict(os.environ)
    if module.config:
        if module.config.active_env_file:
            env_file = project_path / module.config.active_env_file
            secrets_file = None
            if module.config.secrets_file:
                secrets_file = project_path / module.config.secrets_file
            env_vars = merge_env_vars(env_vars, env_file, secrets_file)

    limousine_dir = get_limousine_dir(project_path)
    pids_dir = limousine_dir / "pids"

    process_state = start_command(
        service_name=f"{module.name}_{service_name}",
        command_name=command_name,
        command=command,
        working_dir=project_path,
        env_vars=env_vars,
        pids_dir=pids_dir,
    )

    state_manager.update_service_state(
        module.name, service_name, command_name, process_state
    )

    return process_state


def stop_service(
    module_name: str,
    service_name: str,
    command_name: str,
    project_path: Path,
    state_manager: StateManager,
) -> bool:
    process_state = state_manager.get_service_state(
        module_name, service_name, command_name
    )

    if not process_state or not process_state.pid:
        logger.warning(f"No running process for {module_name}:{service_name}:{command_name}")
        return False

    limousine_dir = get_limousine_dir(project_path)
    pids_dir = limousine_dir / "pids"
    pidfile = pids_dir / f"{module_name}_{service_name}_{command_name}.pid"

    signal = process_state.termination_stage or "SIGINT"

    success, next_stage = stop_command(
        process_state.pid, pidfile, signal, process_state
    )

    if success:
        process_state.state = "stopped"
        process_state.pid = None
        process_state.termination_stage = None
        state_manager.update_service_state(
            module_name, service_name, command_name, process_state
        )
    else:
        process_state.termination_stage = next_stage
        state_manager.update_service_state(
            module_name, service_name, command_name, process_state
        )

    return success


def get_service_status(
    module_name: str,
    service_name: str,
    command_name: str,
    state_manager: StateManager,
) -> str:
    process_state = state_manager.get_service_state(
        module_name, service_name, command_name
    )

    if not process_state:
        return "unknown"

    if process_state.state == "orphaned":
        if process_state.pid and check_process_running(process_state.pid):
            return "orphaned"
        else:
            process_state.state = "stopped"
            state_manager.update_service_state(
                module_name, service_name, command_name, process_state
            )
            return "stopped"

    if process_state.state == "running" and process_state.pid:
        if check_process_running(process_state.pid):
            return "running"
        else:
            process_state.state = "stopped"
            state_manager.update_service_state(
                module_name, service_name, command_name, process_state
            )
            return "stopped"

    return process_state.state


def start_docker_service(
    docker_service: DockerService,
    service_name: str,
    command_name: str,
    project_path: Path,
    state_manager: StateManager,
) -> ProcessState:
    command = docker_service.commands.get(command_name)
    if not command:
        return ProcessState(
            state="failed", last_error=f"Command {command_name} not found"
        )

    env_vars = dict(os.environ)
    limousine_dir = get_limousine_dir(project_path)
    pids_dir = limousine_dir / "pids"

    process_state = start_command(
        service_name=f"docker_{service_name}",
        command_name=command_name,
        command=command,
        working_dir=project_path,
        env_vars=env_vars,
        pids_dir=pids_dir,
    )

    state_manager.update_docker_service_state(service_name, command_name, process_state)

    return process_state


def stop_docker_service(
    service_name: str,
    command_name: str,
    project_path: Path,
    state_manager: StateManager,
) -> bool:
    process_state = state_manager.get_docker_service_state(service_name, command_name)

    if not process_state or not process_state.pid:
        logger.warning(f"No running process for docker:{service_name}:{command_name}")
        return False

    limousine_dir = get_limousine_dir(project_path)
    pids_dir = limousine_dir / "pids"
    pidfile = pids_dir / f"docker_{service_name}_{command_name}.pid"

    signal = process_state.termination_stage or "SIGINT"

    success, next_stage = stop_command(
        process_state.pid, pidfile, signal, process_state
    )

    if success:
        process_state.state = "stopped"
        process_state.pid = None
        process_state.termination_stage = None
        state_manager.update_docker_service_state(service_name, command_name, process_state)
    else:
        process_state.termination_stage = next_stage
        state_manager.update_docker_service_state(service_name, command_name, process_state)

    return success


def get_docker_service_status(
    service_name: str,
    command_name: str,
    state_manager: StateManager,
) -> str:
    process_state = state_manager.get_docker_service_state(service_name, command_name)

    if not process_state:
        return "unknown"

    if process_state.state == "orphaned":
        if process_state.pid and check_process_running(process_state.pid):
            return "orphaned"
        else:
            process_state.state = "stopped"
            state_manager.update_docker_service_state(service_name, command_name, process_state)
            return "stopped"

    if process_state.state == "running" and process_state.pid:
        if check_process_running(process_state.pid):
            return "running"
        else:
            process_state.state = "stopped"
            state_manager.update_docker_service_state(service_name, command_name, process_state)
            return "stopped"

    return process_state.state
