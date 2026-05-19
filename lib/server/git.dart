import 'dart:io';
import 'package:logging/logging.dart';

final _log = Logger('Git');

class GitCloneResult {
  final bool success;
  final String stdout;
  final String stderr;
  final int exitCode;
  GitCloneResult(this.success, this.stdout, this.stderr, this.exitCode);
}

class Git {
  /// Hosts whose URLs we coerce to `ssh://git@<host>/<path>` regardless of
  /// the scheme used in the workspace file. SSH is the only auth path we
  /// support — whoever starts the server brings the keys / agent.
  static const _sshHosts = {'github.com', 'gitlab.com', 'bitbucket.org'};

  /// Normalize a workspace URL into something a stock `git clone` will accept.
  /// - Strips the pip-style `git+` prefix.
  /// - Rewrites `https://<host>/…` to `ssh://git@<host>/…` for known providers.
  /// - Adds the `git@` user when the SSH form is missing it.
  static String normalizeUrl(String url) {
    var u = url.startsWith('git+') ? url.substring(4) : url;
    final uri = Uri.tryParse(u);
    if (uri == null) return u;

    if (uri.scheme == 'https' && _sshHosts.contains(uri.host)) {
      return 'ssh://git@${uri.host}${uri.path}';
    }
    if (uri.scheme == 'ssh' &&
        uri.userInfo.isEmpty &&
        _sshHosts.contains(uri.host)) {
      return 'ssh://git@${uri.host}${uri.path}';
    }
    return u;
  }

  /// Clone [repoUrl] into [targetPath]. Always normalizes to SSH for known
  /// providers (see [normalizeUrl]). Optionally uses a specific SSH key.
  static Future<GitCloneResult> clone(
    String repoUrl,
    String targetPath, {
    String? sshKeyPath,
  }) async {
    final url = normalizeUrl(repoUrl);

    final args = <String>[];
    // Belt-and-suspenders: never prompt the terminal for credentials. If auth
    // fails we want a clean error in the snackbar, not a hung server.
    args.addAll(['-c', 'core.askpass=']);
    if (sshKeyPath != null && sshKeyPath.isNotEmpty) {
      args.addAll(['-c', 'core.sshCommand=ssh -i $sshKeyPath -o IdentitiesOnly=yes']);
    }
    args.addAll(['clone', url, targetPath]);

    _log.info('git ${args.join(' ')}');
    final result = await Process.run(
      'git',
      args,
      environment: {'GIT_TERMINAL_PROMPT': '0'},
      includeParentEnvironment: true,
    );
    final stdout = result.stdout.toString().trim();
    final stderr = result.stderr.toString().trim();
    if (stdout.isNotEmpty) _log.info('stdout: $stdout');
    if (stderr.isNotEmpty) _log.info('stderr: $stderr');

    return GitCloneResult(
      result.exitCode == 0,
      stdout,
      stderr,
      result.exitCode,
    );
  }
}
