import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';
import 'package:path/path.dart' as p;
import '../models/service_state.dart';
import '../services/storage_service.dart';
import '../services/process_service.dart';
import '../services/env_service.dart';
import 'workspace_provider.dart';

final serviceStatesProvider =
    NotifierProvider<ServiceStatesNotifier, Map<String, ServiceState>>(
      ServiceStatesNotifier.new,
    );

class ServiceStatesNotifier extends Notifier<Map<String, ServiceState>> {
  @override
  Map<String, ServiceState> build() => {};

  ServiceState getOrCreate(String serviceId) {
    if (!state.containsKey(serviceId)) {
      state = {
        ...state,
        serviceId: ServiceState(serviceId: serviceId, terminal: Terminal()),
      };
    }
    return state[serviceId]!;
  }

  void _update(String serviceId, ServiceState newState) {
    state = {...state, serviceId: newState};
  }

  Future<void> startService(ServiceInfo info, String command) async {
    final serviceId = info.id;
    final workspacePath = ref.read(currentWorkspacePathProvider);
    if (workspacePath == null) return;

    var serviceState = getOrCreate(serviceId);
    if (serviceState.status == ProcessStatus.running) return;

    final shell = ProcessService.findShell();
    if (shell == null) {
      serviceState.terminal.write('Error: No shell found\r\n');
      return;
    }

    final envPath = p.join(
      info.projectPath,
      info.moduleConfig.activeEnvFile,
    );
    final secretsPath = p.join(
      info.projectPath,
      info.moduleConfig.activeSecretsEnvFile,
    );
    final env = await EnvService.buildProcessEnv(envPath, secretsPath);

    serviceState.terminal.write('\x1b[90m\$ $command\x1b[0m\r\n');

    final pty = ProcessService.startPty(
      executable: shell,
      arguments: ['-c', command],
      workingDirectory: info.projectPath,
      environment: env,
    );

    serviceState = serviceState.copyWith(
      status: ProcessStatus.running,
      pid: pty.pid,
      startTime: DateTime.now(),
      pty: pty,
      nextSignal: StopSignal.sigint,
    );
    _update(serviceId, serviceState);

    await StorageService.writePidFile(workspacePath, serviceId, pty.pid);

    pty.output.listen(
      (data) {
        state[serviceId]?.terminal.write(String.fromCharCodes(data));
      },
      onDone: () => _onProcessDone(serviceId, workspacePath),
      onError: (_) => _onProcessDone(serviceId, workspacePath),
    );

    serviceState.terminal.onOutput = (data) {
      pty.write(Uint8List.fromList(data.codeUnits));
    };
  }

  void _onProcessDone(String serviceId, String workspacePath) {
    final serviceState = state[serviceId];
    if (serviceState == null) return;

    serviceState.terminal.write('\r\n--- Process terminated ---\r\n');
    _update(
      serviceId,
      serviceState.copyWith(
        status: ProcessStatus.stopped,
        clearPty: true,
        clearPid: true,
        nextSignal: StopSignal.sigint,
      ),
    );
    StorageService.deletePidFile(workspacePath, serviceId);
  }

  Future<void> stopService(String serviceId) async {
    final serviceState = state[serviceId];
    if (serviceState == null) return;
    if (serviceState.pid == null) return;

    final signal = serviceState.currentSignal;
    final signalName = signal.toString().split('.').last.toUpperCase();
    serviceState.terminal.write('\r\n--- Sending $signalName ---\r\n');

    ProcessService.sendSignal(serviceState.pid!, signal);

    final nextSignal = switch (serviceState.nextSignal) {
      StopSignal.sigint => StopSignal.sigterm,
      StopSignal.sigterm => StopSignal.sigkill,
      StopSignal.sigkill => StopSignal.sigkill,
    };
    _update(serviceId, serviceState.copyWith(nextSignal: nextSignal));
  }

  Future<void> killOrphanedProcess(String serviceId) async {
    final serviceState = state[serviceId];
    if (serviceState == null) return;
    if (serviceState.pid == null) return;

    serviceState.terminal.write('--- Killing orphaned process ---\r\n');
    ProcessService.sendSignal(serviceState.pid!, ProcessSignal.sigkill);

    final workspacePath = ref.read(currentWorkspacePathProvider);
    if (workspacePath != null) {
      await StorageService.deletePidFile(workspacePath, serviceId);
    }

    _update(
      serviceId,
      serviceState.copyWith(
        status: ProcessStatus.stopped,
        clearPid: true,
        nextSignal: StopSignal.sigint,
      ),
    );
  }

  Future<void> loadOrphanedProcesses() async {
    final workspacePath = ref.read(currentWorkspacePathProvider);
    if (workspacePath == null) return;

    final pidFiles = await StorageService.loadAllPidFiles(workspacePath);
    for (final entry in pidFiles.entries) {
      final serviceId = entry.key;
      final pid = entry.value;

      var serviceState = getOrCreate(serviceId);
      if (ProcessService.isProcessRunning(pid)) {
        serviceState.terminal.write(
          '--- Orphaned process detected (PID: $pid) ---\r\n',
        );
        _update(
          serviceId,
          serviceState.copyWith(
            status: ProcessStatus.orphaned,
            pid: pid,
          ),
        );
      } else {
        await StorageService.deletePidFile(workspacePath, serviceId);
      }
    }
  }
}
