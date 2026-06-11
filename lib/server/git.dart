import 'dart:io';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import '../core/dto.dart';

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

  // ─── status / refresh / pull ────────────────────────────────────────────
  // All of these shell out to the same `git` binary the rest of this class
  // uses. status() is local-only (no network). refresh() runs `git fetch`.
  // pullFfOnly() runs `git pull --ff-only` after a sanity check.

  /// Run `git <args>` in [cwd], return ProcessResult. Captures stderr for
  /// diagnostics; doesn't log unless the exit code is non-zero. Times out
  /// after 30s so a wedged ssh-agent prompt can't hang the server.
  static Future<ProcessResult> _run(
    List<String> args,
    String cwd, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    // BatchMode + ConnectTimeout: same hardening as clone() — never prompt
    // the terminal for credentials, return a real error fast.
    const sshOpts =
        '-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new';
    return Process.run(
      'git',
      ['-c', 'core.askpass=', '-c', 'core.sshCommand=ssh $sshOpts', ...args],
      workingDirectory: cwd,
      environment: {
        'GIT_TERMINAL_PROMPT': '0',
        'SSH_ASKPASS': '/bin/false',
        'SSH_ASKPASS_REQUIRE': 'never',
      },
      includeParentEnvironment: true,
    ).timeout(timeout);
  }

  /// Compute a [GitStatusDto] for the repo at [projectPath] without any
  /// network calls. Safe to invoke from the hot path of the dashboard load.
  static Future<GitStatusDto> status(String projectName, String projectPath) async {
    final dir = Directory(projectPath);
    final gitDir = Directory(p.join(projectPath, '.git'));
    if (!await dir.exists() || !await gitDir.exists()) {
      return GitStatusDto(project: projectName, exists: false);
    }

    try {
      // Branch (or "HEAD" for detached).
      final branchRes = await _run(['rev-parse', '--abbrev-ref', 'HEAD'], projectPath);
      final branch = branchRes.exitCode == 0
          ? (branchRes.stdout as String).trim()
          : null;

      // Short SHA + last commit subject.
      final shaRes = await _run(['rev-parse', '--short', 'HEAD'], projectPath);
      final shortSha = shaRes.exitCode == 0 ? (shaRes.stdout as String).trim() : null;

      final subjRes = await _run(['log', '-1', '--format=%s', 'HEAD'], projectPath);
      final subject = subjRes.exitCode == 0 ? (subjRes.stdout as String).trim() : null;

      // Dirty files. Parse porcelain output: first two chars are status
      // (e.g. " M", "??", "MM"), then a space, then the path.
      final dirtyRes = await _run(['status', '--porcelain'], projectPath);
      final dirtyFiles = <DirtyFileDto>[];
      if (dirtyRes.exitCode == 0) {
        for (final line in (dirtyRes.stdout as String).split('\n')) {
          if (line.length < 4) continue;
          final code = line.substring(0, 2);
          final path = line.substring(3);
          dirtyFiles.add(DirtyFileDto(
            path: path,
            status: code,
            isLockFile: _isLockFile(path),
          ));
        }
      }

      // Upstream + behind/ahead vs upstream (local refs only).
      final upstreamRes =
          await _run(['rev-parse', '--abbrev-ref', '@{upstream}'], projectPath);
      String? upstream;
      int? behindUpstream;
      int? aheadUpstream;
      if (upstreamRes.exitCode == 0) {
        upstream = (upstreamRes.stdout as String).trim();
        final countsRes = await _run(
          ['rev-list', '--left-right', '--count', '$upstream...HEAD'],
          projectPath,
        );
        if (countsRes.exitCode == 0) {
          final parts = (countsRes.stdout as String).trim().split(RegExp(r'\s+'));
          if (parts.length == 2) {
            behindUpstream = int.tryParse(parts[0]);
            aheadUpstream = int.tryParse(parts[1]);
          }
        }
      }

      // Resolve default branch — `origin/HEAD` if set, fall back to main/master.
      final mainBranch = await _resolveMainBranch(projectPath);

      // Commits behind main (only when current branch isn't main).
      int? behindMain;
      if (mainBranch != null && branch != mainBranch) {
        final mainRefRes =
            await _run(['rev-list', '--count', 'HEAD..origin/$mainBranch'], projectPath);
        if (mainRefRes.exitCode == 0) {
          behindMain = int.tryParse((mainRefRes.stdout as String).trim());
        }
      }

      // Most recent tag reachable from origin/<main>, plus the number of
      // commits between that tag and HEAD. Matches `git describe HEAD`
      // semantics — "how far past the last release am I" — so on a feature
      // branch with 2 unmerged commits the dashboard shows `v1.31.1 +2`.
      // Tags are restricted to main (the team only tags on main); the count
      // is from HEAD so unmerged work on your branch is visible.
      String? latestTag;
      int? commitsSinceTag;
      if (mainBranch != null) {
        final tagRes = await _run(
          ['describe', '--tags', '--abbrev=0', 'origin/$mainBranch'],
          projectPath,
        );
        if (tagRes.exitCode == 0) {
          final tag = (tagRes.stdout as String).trim();
          if (tag.isNotEmpty) {
            latestTag = tag;
            final countRes = await _run(
              ['rev-list', '--count', '$tag..HEAD'],
              projectPath,
            );
            if (countRes.exitCode == 0) {
              commitsSinceTag =
                  int.tryParse((countRes.stdout as String).trim());
            }
          }
        }
      }

      // FETCH_HEAD mtime as proxy for "last fetched".
      DateTime? lastFetched;
      final fetchHead = File(p.join(projectPath, '.git', 'FETCH_HEAD'));
      if (await fetchHead.exists()) {
        lastFetched = (await fetchHead.stat()).modified;
      }

      return GitStatusDto(
        project: projectName,
        exists: true,
        branch: branch,
        shortSha: shortSha,
        subject: subject,
        dirtyFiles: dirtyFiles,
        upstream: upstream,
        behindUpstream: behindUpstream,
        aheadUpstream: aheadUpstream,
        mainBranch: mainBranch,
        behindMain: behindMain,
        latestTag: latestTag,
        commitsSinceTag: commitsSinceTag,
        lastFetched: lastFetched,
      );
    } catch (e, st) {
      _log.warning('git status failed for $projectName at $projectPath', e, st);
      return GitStatusDto(
        project: projectName,
        exists: true,
        error: e.toString(),
      );
    }
  }

  /// `git fetch --prune --quiet origin` then return fresh status. Network op.
  static Future<GitStatusDto> refresh(String projectName, String projectPath) async {
    final dir = Directory(projectPath);
    if (!await dir.exists()) {
      return GitStatusDto(project: projectName, exists: false);
    }
    // `--tags` belt-and-suspenders: tags reachable from fetched branches
    // come along automatically, but a tag pointing at a commit that's no
    // longer in the default-fetched set would otherwise be missed.
    final fetchRes = await _run(['fetch', '--prune', '--tags', '--quiet', 'origin'], projectPath);
    if (fetchRes.exitCode != 0) {
      _log.warning(
        'git fetch failed for $projectName: ${(fetchRes.stderr as String).trim()}',
      );
    }
    return status(projectName, projectPath);
  }

  /// `git pull --ff-only` with lock-file auto-stash. Pre-flight: refuses if
  /// any non-lock files are dirty (caller should gate the button anyway).
  /// When lock files are dirty, stashes just those paths, pulls, then pops.
  /// If pop conflicts (rare — only when remote also modified those exact
  /// lines), the stash is left in place and the failure is surfaced.
  static Future<GitPullResult> pullFfOnly(
    String projectName,
    String projectPath,
  ) async {
    final dir = Directory(projectPath);
    if (!await dir.exists()) {
      return GitPullResult(
        success: false,
        message: 'project directory missing',
        status: GitStatusDto(project: projectName, exists: false),
      );
    }

    final pre = await Git.status(projectName, projectPath);
    if (pre.dirtyCode > 0) {
      return GitPullResult(
        success: false,
        message:
            'refused: ${pre.dirtyCode} code file(s) dirty. Commit or stash them first.',
        status: pre,
      );
    }

    var stashed = false;
    if (pre.dirtyLock > 0) {
      final lockPaths = pre.lockFiles.map((f) => f.path).toList();
      final stashRes = await _run(
        ['stash', 'push', '--quiet', '-m', 'limousine: auto-stash lock files', '--', ...lockPaths],
        projectPath,
      );
      if (stashRes.exitCode != 0) {
        final err = (stashRes.stderr as String).trim();
        return GitPullResult(
          success: false,
          message: 'failed to stash lock files: $err',
          status: await Git.status(projectName, projectPath),
        );
      }
      stashed = true;
    }

    final pullRes = await _run(['pull', '--ff-only', '--quiet'], projectPath);
    final pullStderr = (pullRes.stderr as String).trim();
    final pullOk = pullRes.exitCode == 0;

    String popMessage = '';
    if (stashed) {
      final popRes = await _run(['stash', 'pop', '--quiet'], projectPath);
      if (popRes.exitCode != 0) {
        final popErr = (popRes.stderr as String).trim();
        // Pop failed → stash still in place. Tell the user.
        popMessage =
            ' Lock-file stash kept (conflict on pop) — run `git stash list` then resolve manually. ${popErr.isEmpty ? '' : popErr}';
      } else if (pullOk) {
        popMessage = ' Auto-stashed and restored lock files.';
      }
    }

    final status = await Git.status(projectName, projectPath);
    return GitPullResult(
      success: pullOk && (stashed ? !popMessage.contains('conflict') : true),
      message: pullOk
          ? 'fast-forwarded.$popMessage'
          : (pullStderr.isEmpty ? 'pull failed' : pullStderr),
      status: status,
    );
  }

  /// Lock files: basename-matched. Same set across ecosystems.
  static const _lockFileNames = {
    'uv.lock',
    'package-lock.json',
    'yarn.lock',
    'pnpm-lock.yaml',
    'Cargo.lock',
    'Pipfile.lock',
    'poetry.lock',
    'composer.lock',
    'Gemfile.lock',
  };

  static bool _isLockFile(String path) {
    final base = path.split('/').last;
    return _lockFileNames.contains(base);
  }

  static Future<String?> _resolveMainBranch(String projectPath) async {
    final symRes = await _run(
      ['symbolic-ref', '--short', 'refs/remotes/origin/HEAD'],
      projectPath,
    );
    if (symRes.exitCode == 0) {
      final v = (symRes.stdout as String).trim();
      // Returns "origin/main" — strip the "origin/" prefix.
      if (v.startsWith('origin/')) return v.substring('origin/'.length);
      return v;
    }
    // Fallbacks if origin/HEAD isn't set locally.
    for (final candidate in ['main', 'master']) {
      final r = await _run(
        ['show-ref', '--verify', '--quiet', 'refs/remotes/origin/$candidate'],
        projectPath,
      );
      if (r.exitCode == 0) return candidate;
    }
    return null;
  }
}

class GitPullResult {
  final bool success;
  final String message;
  final GitStatusDto status;
  GitPullResult({required this.success, required this.message, required this.status});
}
