import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import '../core/dto.dart';
import '../core/module.dart';
import 'env.dart';
import 'storage.dart';
import 'workspace_manager.dart';

final _log = Logger('ServiceManager');

class _RunningService {
  final Pty pty;
  final DateTime startTime;
  _RunningService(this.pty, this.startTime);
}

class ServiceManager {
  static const int _bufferLines = 2000;

  final WorkspaceManager workspaceManager;
  final Map<String, ServiceStateDto> _states = {};
  final Map<String, _RunningService> _running = {};

  // Persistent per-service output, kept across runs so a WS client that
  // attaches before the process starts still receives every chunk.
  final Map<String, List<String>> _buffers = {};
  final Map<String, StreamController<String>> _outputStreams = {};

  final StreamController<ServiceStateDto> _stateChanges =
      StreamController<ServiceStateDto>.broadcast();

  ServiceManager(this.workspaceManager);

  Stream<ServiceStateDto> get stateChanges => _stateChanges.stream;

  Map<String, ServiceStateDto> get states => Map.unmodifiable(_states);

  ServiceStateDto _ensureState(String serviceId) {
    return _states.putIfAbsent(
      serviceId,
      () => ServiceStateDto(serviceId: serviceId),
    );
  }

  void _emit(ServiceStateDto state) {
    _states[state.serviceId] = state;
    _stateChanges.add(state);
  }

  StreamController<String> _ensureStream(String serviceId) {
    return _outputStreams.putIfAbsent(
      serviceId,
      () => StreamController<String>.broadcast(),
    );
  }

  Stream<String> outputStream(String serviceId) =>
      _ensureStream(serviceId).stream;

  List<String> bufferedOutput(String serviceId) =>
      List.unmodifiable(_buffers[serviceId] ?? const []);

  Future<void> startService(String serviceId, {String? commandName}) async {
    final info = workspaceManager.findService(serviceId);
    if (info == null) throw ArgumentError('Unknown service: $serviceId');

    final existing = _ensureState(serviceId);
    if (existing.status == ProcessStatus.running) {
      throw StateError('Service $serviceId already running');
    }

    final commands = info.service.commands;
    if (commands.isEmpty) throw StateError('Service $serviceId has no commands');

    final cmd = commandName != null
        ? commands[commandName] ??
            (throw ArgumentError(
                'Unknown command "$commandName" for $serviceId. Available: ${commands.keys.join(', ')}'))
        : (commands['run'] ?? commands.values.first);

    final shell = _findShell();
    if (shell == null) throw StateError('No shell available');

    final envPath = p.join(info.projectPath, info.moduleConfig.activeEnvFile);
    final secretsPath = p.join(info.projectPath, info.moduleConfig.activeSecretsEnvFile);
    final env = await Env.buildProcessEnv(envPath, secretsPath);

    final pty = Pty.start(
      shell,
      arguments: ['-l', '-c', cmd],
      workingDirectory: info.projectPath,
      environment: env,
    );

    _running[serviceId] = _RunningService(pty, DateTime.now());
    _emit(ServiceStateDto(
      serviceId: serviceId,
      status: ProcessStatus.running,
      pid: pty.pid,
      startTime: _running[serviceId]!.startTime,
      nextSignal: StopSignal.sigint,
    ));

    _appendOutput(serviceId, '\x1b[90m\$ $cmd\x1b[0m\r\n');

    final workspacePath = workspaceManager.workspacePath;
    if (workspacePath != null) {
      await Storage.writePidFile(workspacePath, serviceId, pty.pid);
    }

    pty.output.listen(
      (data) => _appendOutput(serviceId, String.fromCharCodes(data)),
      onDone: () => _onProcessDone(serviceId),
      onError: (e, st) {
        _log.warning('PTY error for $serviceId', e, st);
        _onProcessDone(serviceId);
      },
    );
  }

  void _appendOutput(String serviceId, String chunk) {
    final buffer = _buffers.putIfAbsent(serviceId, () => <String>[]);
    buffer.add(chunk);
    while (buffer.length > _bufferLines) {
      buffer.removeAt(0);
    }
    final stream = _ensureStream(serviceId);
    if (!stream.isClosed) stream.add(chunk);
  }

  void writeStdin(String serviceId, String data) {
    final running = _running[serviceId];
    if (running == null) return;
    running.pty.write(Uint8List.fromList(data.codeUnits));
  }

  Future<void> _onProcessDone(String serviceId) async {
    _running.remove(serviceId);
    _appendOutput(serviceId, '\r\n--- Process terminated ---\r\n');
    _emit(ServiceStateDto(
      serviceId: serviceId,
      status: ProcessStatus.stopped,
    ));
    final workspacePath = workspaceManager.workspacePath;
    if (workspacePath != null) {
      await Storage.deletePidFile(workspacePath, serviceId);
    }
  }

  Future<void> stopService(String serviceId) async {
    final state = _states[serviceId];
    final running = _running[serviceId];
    if (state == null || running == null || state.pid == null) {
      throw StateError('Service $serviceId is not running');
    }

    final signal = switch (state.nextSignal) {
      StopSignal.sigint => ProcessSignal.sigint,
      StopSignal.sigterm => ProcessSignal.sigterm,
      StopSignal.sigkill => ProcessSignal.sigkill,
    };
    final signalName = state.nextSignal.name.toUpperCase();
    _appendOutput(serviceId, '\r\n--- Sending $signalName ---\r\n');
    Process.killPid(state.pid!, signal);

    final next = switch (state.nextSignal) {
      StopSignal.sigint => StopSignal.sigterm,
      StopSignal.sigterm => StopSignal.sigkill,
      StopSignal.sigkill => StopSignal.sigkill,
    };
    _emit(ServiceStateDto(
      serviceId: serviceId,
      status: ProcessStatus.running,
      pid: state.pid,
      startTime: state.startTime,
      nextSignal: next,
    ));
  }

  /// Escalating stop. Sends SIGINT, polls 5s; SIGTERM, polls 5s; SIGKILL, polls 5s.
  /// Returns true if the service stopped, false otherwise.
  Future<bool> stopServiceEscalating(String serviceId) async {
    final state = _states[serviceId];
    if (state == null || state.status != ProcessStatus.running) return true;

    for (var round = 0; round < 3; round++) {
      await stopService(serviceId);
      for (var tick = 0; tick < 5; tick++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        final current = _states[serviceId];
        if (current == null || current.status != ProcessStatus.running) return true;
      }
    }
    return false;
  }

  Future<void> killOrphan(String serviceId) async {
    final state = _states[serviceId];
    if (state == null || state.pid == null) return;
    try {
      Process.killPid(state.pid!, ProcessSignal.sigkill);
    } catch (_) {}
    final workspacePath = workspaceManager.workspacePath;
    if (workspacePath != null) {
      await Storage.deletePidFile(workspacePath, serviceId);
    }
    _emit(ServiceStateDto(serviceId: serviceId, status: ProcessStatus.stopped));
  }

  Future<void> scanOrphans() async {
    final workspacePath = workspaceManager.workspacePath;
    if (workspacePath == null) return;
    final pidFiles = await Storage.loadAllPidFiles(workspacePath);
    for (final entry in pidFiles.entries) {
      if (_isProcessRunning(entry.value)) {
        _emit(ServiceStateDto(
          serviceId: entry.key,
          status: ProcessStatus.orphaned,
          pid: entry.value,
        ));
      } else {
        await Storage.deletePidFile(workspacePath, entry.key);
      }
    }
  }

  bool _isProcessRunning(int pid) {
    try {
      return Process.killPid(pid, ProcessSignal.sigusr1);
    } catch (_) {
      return false;
    }
  }

  String? _findShell() {
    final shell = Platform.environment['SHELL'];
    if (shell != null) return shell;
    for (final s in ['/bin/bash', '/bin/sh', '/bin/zsh']) {
      if (File(s).existsSync()) return s;
    }
    return null;
  }

  Future<void> dispose() async {
    for (final running in _running.values) {
      try {
        running.pty.kill(ProcessSignal.sigterm);
      } catch (_) {}
    }
    _running.clear();
    for (final s in _outputStreams.values) {
      await s.close();
    }
    _outputStreams.clear();
    await _stateChanges.close();
  }
}

class ServiceInfo {
  final String projectName;
  final String projectPath;
  final String moduleName;
  final ModuleConfig moduleConfig;
  final String serviceName;
  final Service service;

  ServiceInfo({
    required this.projectName,
    required this.projectPath,
    required this.moduleName,
    required this.moduleConfig,
    required this.serviceName,
    required this.service,
  });

  String get id => '$moduleName/$serviceName';

  Map<String, dynamic> toJson() => {
    'id': id,
    'projectName': projectName,
    'projectPath': projectPath,
    'moduleName': moduleName,
    'serviceName': serviceName,
    'commands': service.commands,
  };
}
