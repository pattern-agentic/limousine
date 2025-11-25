import 'dart:io';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

enum ProcessStatus { stopped, running, orphaned }

enum StopSignal { sigint, sigterm, sigkill }

class ServiceState {
  final String serviceId;
  final ProcessStatus status;
  final int? pid;
  final DateTime? startTime;
  final Terminal terminal;
  final Pty? pty;
  final StopSignal nextSignal;

  ServiceState({
    required this.serviceId,
    this.status = ProcessStatus.stopped,
    this.pid,
    this.startTime,
    required this.terminal,
    this.pty,
    this.nextSignal = StopSignal.sigint,
  });

  ServiceState copyWith({
    ProcessStatus? status,
    int? pid,
    DateTime? startTime,
    Pty? pty,
    StopSignal? nextSignal,
    bool clearPty = false,
    bool clearPid = false,
  }) {
    return ServiceState(
      serviceId: serviceId,
      status: status ?? this.status,
      pid: clearPid ? null : (pid ?? this.pid),
      startTime: startTime ?? this.startTime,
      terminal: terminal,
      pty: clearPty ? null : (pty ?? this.pty),
      nextSignal: nextSignal ?? this.nextSignal,
    );
  }

  ProcessSignal get currentSignal {
    switch (nextSignal) {
      case StopSignal.sigint:
        return ProcessSignal.sigint;
      case StopSignal.sigterm:
        return ProcessSignal.sigterm;
      case StopSignal.sigkill:
        return ProcessSignal.sigkill;
    }
  }

  String get stopButtonLabel {
    switch (nextSignal) {
      case StopSignal.sigint:
        return 'Stop';
      case StopSignal.sigterm:
        return 'Stop (TERM)';
      case StopSignal.sigkill:
        return 'Stop (KILL)';
    }
  }
}
