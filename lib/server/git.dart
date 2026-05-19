import 'dart:io';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

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

  /// If [targetPath] exists but contains only a `.git/` (or is empty), move
  /// it to `<targetPath>.failed-<ISO timestamp>` so the next clone has a clean
  /// slate. Backup keeps anything `git fetch` may have salvaged. Real content
  /// (non-`.git` entries) is never touched.
  static Future<String?> _rescuePartialTarget(String targetPath) async {
    final dir = Directory(targetPath);
    if (!await dir.exists()) return null;

    await for (final entity in dir.list(followLinks: false)) {
      if (p.basename(entity.path) != '.git') {
        // Real content — leave it alone. Caller decides what to do.
        return null;
      }
    }

    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final backup = '$targetPath.failed-$timestamp';
    _log.info('Moving partial clone target $targetPath → $backup');
    await dir.rename(backup);
    return backup;
  }

  /// Clone [repoUrl] into [targetPath]. Always normalizes to SSH for known
  /// providers (see [normalizeUrl]). Optionally uses a specific SSH key.
  static Future<GitCloneResult> clone(
    String repoUrl,
    String targetPath, {
    String? sshKeyPath,
  }) async {
    final rescued = await _rescuePartialTarget(targetPath);
    if (rescued != null) {
      _log.info('Previous partial clone preserved at $rescued');
    }
    final url = normalizeUrl(repoUrl);

    final args = <String>[];
    // Belt-and-suspenders: never prompt the terminal for credentials. If auth
    // fails we want a clean error in the snackbar, not a hung server.
    args.addAll(['-c', 'core.askpass=']);
    // Force BatchMode + a short ConnectTimeout so ssh never tries to
    // interactively prompt for a passphrase (would deadlock the server) and
    // returns a real error if the agent isn't reachable.
    final sshOpts = '-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new';
    if (sshKeyPath != null && sshKeyPath.isNotEmpty) {
      args.addAll([
        '-c',
        'core.sshCommand=ssh -i $sshKeyPath -o IdentitiesOnly=yes $sshOpts',
      ]);
    } else {
      args.addAll(['-c', 'core.sshCommand=ssh $sshOpts']);
    }
    args.addAll(['clone', url, targetPath]);

    _log.info('git ${args.join(' ')}');
    final result = await Process.run(
      'git',
      args,
      environment: {
        'GIT_TERMINAL_PROMPT': '0',
        'SSH_ASKPASS': '/bin/false',
        'SSH_ASKPASS_REQUIRE': 'never',
      },
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
