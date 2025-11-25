import 'dart:io';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:logging/logging.dart';

final _log = Logger('ProcessService');

class ProcessService {
  static bool isProcessRunning(int pid) {
    try {
      Process.killPid(pid, ProcessSignal.sigusr1);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Pty startPty({
    required String executable,
    required List<String> arguments,
    required String workingDirectory,
    required Map<String, String> environment,
  }) {
    return Pty.start(
      executable,
      arguments: arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
  }

  static bool sendSignal(int pid, ProcessSignal signal) {
    try {
      return Process.killPid(pid, signal);
    } catch (_) {
      return false;
    }
  }

  static Future<ProcessResult> runGitClone(
    String repoUrl,
    String targetPath, {
    String? sshKeyPath,
  }) async {
    final args = <String>[];
    if (sshKeyPath != null) {
      args.addAll(['-c', 'core.sshCommand=ssh -i $sshKeyPath -o IdentitiesOnly=yes']);
    }
    args.addAll(['clone', repoUrl, targetPath]);

    final sshInfo = sshKeyPath != null ? ' (with SSH key: $sshKeyPath)' : '';
    _log.info('Running: git ${args.join(' ')}$sshInfo');

    final result = await Process.run('git', args);

    _log.info('Git clone exit code: ${result.exitCode}');
    final stdout = result.stdout.toString().trim();
    final stderr = result.stderr.toString().trim();
    if (stdout.isNotEmpty) {
      _log.info('Git clone stdout: $stdout');
    }
    if (stderr.isNotEmpty) {
      _log.warning('Git clone stderr: $stderr');
    }

    return result;
  }

  static String? findShell() {
    final shell = Platform.environment['SHELL'];
    if (shell != null) return shell;
    for (final s in ['/bin/bash', '/bin/sh', '/bin/zsh']) {
      if (File(s).existsSync()) return s;
    }
    return null;
  }
}
