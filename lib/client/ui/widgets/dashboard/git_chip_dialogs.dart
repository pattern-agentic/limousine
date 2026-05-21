import 'package:flutter/material.dart';
import '../../../../core/dto.dart';

/// Dialog content for each chip type. All dialogs share the same shell —
/// title + body + optional file list + optional commands list. Per-chip
/// builder functions compose those pieces with the right copy.

void showChipDialog(
  BuildContext context, {
  required String title,
  required Widget body,
  List<DirtyFileDto> files = const [],
  List<CommandExample> commands = const [],
}) {
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              DefaultTextStyle.merge(
                style: const TextStyle(fontSize: 13, height: 1.4),
                child: body,
              ),
              if (files.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('Files', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                _FilesList(files: files),
              ],
              if (commands.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('Commands',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                ...commands.map((c) => _CommandBlock(example: c)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

class CommandExample {
  final String description;
  final String command;
  CommandExample(this.description, this.command);
}

class _CommandBlock extends StatelessWidget {
  final CommandExample example;
  const _CommandBlock({required this.example});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(example.description,
              style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
          const SizedBox(height: 2),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(4),
            ),
            child: SelectableText(
              example.command,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: Color(0xFFE5E7EB),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilesList extends StatelessWidget {
  final List<DirtyFileDto> files;
  const _FilesList({required this.files});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 240),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(4),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: SingleChildScrollView(
        child: SelectableText(
          files
              .map((f) => '${f.status}  ${f.path}${f.isLockFile ? "  [lock]" : ""}')
              .join('\n'),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ),
    );
  }
}

// ─── Per-chip content ──────────────────────────────────────────────────────

void showDirtyDialog(BuildContext context, GitStatusDto status) {
  final lockCount = status.dirtyLock;
  final codeCount = status.dirtyCode;
  showChipDialog(
    context,
    title: 'Uncommitted changes (${status.dirty})',
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Your working tree has ${status.dirty} file(s) with changes that '
          'aren\'t in any commit yet — $codeCount code, $lockCount lock.',
        ),
        const SizedBox(height: 8),
        if (lockCount > 0) ...[
          const Text(
            '• Lock files (uv.lock, package-lock.json, …) are tracked '
            'separately because dev tools often regenerate them without any '
            'real change. Limousine\'s "Pull" button auto-stashes them, '
            'runs the pull, then restores — they do not block pulling.',
            style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
          ),
          const SizedBox(height: 6),
        ],
        if (codeCount > 0)
          const Text(
            '• Code-file changes do block pull. Commit, stash, or discard '
            'them first.',
            style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
          ),
      ],
    ),
    files: status.dirtyFiles,
    commands: [
      CommandExample('See per-file status with paths:', 'git status'),
      CommandExample('Inspect what changed:', 'git diff'),
      CommandExample('Discard one file\'s changes (irreversible):',
          'git checkout -- path/to/file'),
      CommandExample('Set aside everything, restore later with `git stash pop`:',
          'git stash'),
      CommandExample('Commit code changes:', 'git commit -am "message"'),
    ],
  );
}

void showBehindUpstreamDialog(BuildContext context, GitStatusDto status) {
  final n = status.behindUpstream ?? 0;
  final upstream = status.upstream ?? 'origin/?';
  showChipDialog(
    context,
    title: 'Behind upstream ($n commit${n == 1 ? "" : "s"})',
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$upstream has $n commit(s) you don\'t have locally. '
          'Pulling will fast-forward your branch onto them.',
        ),
        const SizedBox(height: 8),
        const Text(
          '• Limousine\'s "Pull" button is enabled when your code files are '
          'clean (lock files are auto-handled).',
          style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
        ),
        if (status.aheadUpstream != null && status.aheadUpstream! > 0) ...[
          const SizedBox(height: 6),
          Text(
            '• You also have ${status.aheadUpstream} local commit(s) not yet '
            'pushed — fast-forward isn\'t possible in that case. Rebase or '
            'merge instead.',
            style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
          ),
        ],
      ],
    ),
    commands: [
      CommandExample('Standard case (clean tree):', 'git pull --ff-only'),
      CommandExample(
          'If you have uncommitted code changes — stash, pull, restore:',
          'git stash && git pull --ff-only && git stash pop'),
      if (status.aheadUpstream != null && status.aheadUpstream! > 0)
        CommandExample(
            'You have local commits — rebase onto the remote tip:',
            'git pull --rebase'),
    ],
  );
}

void showAheadUpstreamDialog(BuildContext context, GitStatusDto status) {
  final n = status.aheadUpstream ?? 0;
  showChipDialog(
    context,
    title: 'Ahead of upstream ($n commit${n == 1 ? "" : "s"})',
    body: Text(
      'You have $n local commit(s) that aren\'t on '
      '${status.upstream ?? "the remote"} yet. Push them to share with the team.',
    ),
    commands: [
      CommandExample('Publish your commits:', 'git push'),
      CommandExample(
          'If you also need to set the upstream (first push of a new branch):',
          'git push -u origin ${status.branch ?? "<branch>"}'),
    ],
  );
}

void showNoUpstreamDialog(BuildContext context, GitStatusDto status) {
  showChipDialog(
    context,
    title: 'No upstream branch',
    body: const Text(
      'Your local branch isn\'t tracking a remote branch. That means: no '
      'behind/ahead comparison, and `git pull` / `git push` without arguments '
      'don\'t know where to go. Usually this is a freshly-created local '
      'branch that hasn\'t been pushed yet.',
    ),
    commands: [
      CommandExample('Push and set the upstream in one go:',
          'git push -u origin ${status.branch ?? "<branch>"}'),
    ],
  );
}

void showBehindMainDialog(BuildContext context, GitStatusDto status) {
  final n = status.behindMain ?? 0;
  final main = status.mainBranch ?? 'main';
  showChipDialog(
    context,
    title: 'Behind $main ($n commit${n == 1 ? "" : "s"})',
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'origin/$main has moved $n commit(s) ahead since your branch '
          'diverged. Your branch will need to absorb those changes before '
          'merging back.',
        ),
        const SizedBox(height: 8),
        Text(
          '• Two ways: rebase (rewrites your branch on top of $main — '
          'cleanest history, but rewrites SHAs) or merge (preserves history '
          'with a merge commit).',
          style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
        ),
        const SizedBox(height: 6),
        const Text(
          '• If you\'ve already pushed your branch and others might be using '
          'it, prefer merge — rebasing rewrites history that others may have '
          'pulled.',
          style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
        ),
      ],
    ),
    commands: [
      CommandExample('First, get the latest of $main:',
          'git fetch origin $main:$main'),
      CommandExample('Rebase your branch onto $main (clean linear history):',
          'git rebase $main'),
      CommandExample('Or merge $main into your branch (safer for shared branches):',
          'git merge $main'),
    ],
  );
}
