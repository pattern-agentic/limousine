import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/dto.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/git_status_provider.dart';
import '../../../providers/workspace_provider.dart';
import 'git_chip_dialogs.dart';
import 'service_row.dart';

class ProjectCard extends ConsumerStatefulWidget {
  final LoadedProjectDto project;
  const ProjectCard({super.key, required this.project});

  @override
  ConsumerState<ProjectCard> createState() => _ProjectCardState();
}

class _ProjectCardState extends ConsumerState<ProjectCard> {
  bool _cloning = false;

  @override
  void initState() {
    super.initState();
    // Each card initiates its own status load on mount. Local-only, cheap.
    if (widget.project.existsOnDisk) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(gitStatusProvider.notifier).load(widget.project.name);
      });
    }
    _logLoadErrorOnce(widget.project);
  }

  @override
  void didUpdateWidget(covariant ProjectCard old) {
    super.didUpdateWidget(old);
    // Project went from missing → cloned: kick off a fresh status load.
    if (!old.project.existsOnDisk && widget.project.existsOnDisk) {
      ref.read(gitStatusProvider.notifier).load(widget.project.name);
    }
    if (old.project.loadError != widget.project.loadError) {
      _logLoadErrorOnce(widget.project);
    }
  }

  /// Send loadError to the browser console as a real error so it's
  /// inspectable (stack trace + filterable in DevTools). The UI also shows
  /// the same string in the expanded card body, so the user can copy-paste
  /// from either place.
  void _logLoadErrorOnce(LoadedProjectDto project) {
    final err = project.loadError;
    if (err == null || err.isEmpty) return;
    developer.log(
      err,
      name: 'limousine.workspace',
      level: 1000, // SEVERE in Dart's logging convention
      error: 'loadError on project ${project.name}',
    );
  }

  Future<void> _clone() async {
    setState(() => _cloning = true);
    try {
      await ref.read(apiClientProvider).cloneProject(widget.project.name);
      await ref.read(workspaceStateProvider.notifier).refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Clone failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _cloning = false);
    }
  }

  Future<void> _refresh() async {
    await ref.read(gitStatusProvider.notifier).refresh(widget.project.name);
  }

  Future<void> _pull() async {
    final result =
        await ref.read(gitStatusProvider.notifier).pull(widget.project.name);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
          '${widget.project.name}: ${result.ok ? "pulled" : "pull failed"} — ${result.message}'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final project = widget.project;
    final canClone = !project.existsOnDisk && project.gitRepoUrl != null;
    final gitStatus = ref.watch(gitStatusProvider
        .select((b) => b.byProject[project.name]));
    final gitBusy = ref.watch(
        gitStatusProvider.select((b) => b.inFlight.contains(project.name)));

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: ExpansionTile(
        leading: Icon(
          project.loadError != null
              ? Icons.error_outline
              : project.existsOnDisk
                  ? Icons.folder
                  : Icons.folder_off,
          color: project.loadError != null
              ? const Color(0xFFF43F5E)
              : project.existsOnDisk
                  ? Colors.green
                  : Colors.orange,
        ),
        title: Text(project.name),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              project.resolvedPath,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (project.existsOnDisk && gitStatus != null) ...[
              const SizedBox(height: 4),
              _GitLine(status: gitStatus),
            ],
          ],
        ),
        trailing: canClone
            ? _cloneButton()
            : (project.existsOnDisk
                ? _onDiskActions(gitStatus, gitBusy)
                : null),
        children: [
          if (!project.existsOnDisk)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Project not found on disk'),
                  if (project.gitRepoUrl != null) ...[
                    const SizedBox(height: 8),
                    SelectableText(
                      project.gitRepoUrl!,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ],
              ),
            )
          else if (project.loadError != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: SelectableText(
                project.loadError!,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: Color(0xFFF43F5E),
                ),
              ),
            )
          else if (project.projectData == null)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No limousine.proj found'),
            )
          else
            ...project.projectData!.modules.expand(
              (module) => module.services.entries.map(
                (entry) => ServiceRow(
                  serviceId: '${module.name}/${entry.key}',
                  service: entry.value,
                  moduleConfig: module.config,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _cloneButton() {
    if (_cloning) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12),
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return IconButton(
      icon: const Icon(Icons.download),
      tooltip: 'Clone repository',
      onPressed: _clone,
    );
  }

  Widget _onDiskActions(GitStatusDto? status, bool busy) {
    // Lock files don't block pull — server auto-stashes them.
    final canPull = status != null &&
        status.behindUpstream != null &&
        status.behindUpstream! > 0 &&
        (status.aheadUpstream ?? 0) == 0 &&
        status.dirtyCode == 0;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Check for updates (git fetch)',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          iconSize: 18,
          icon: busy
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.cloud_sync),
          onPressed: busy ? null : _refresh,
        ),
        IconButton(
          tooltip: canPull
              ? 'git pull --ff-only'
              : (status == null
                  ? 'loading…'
                  : 'pull: branch is ahead, dirty, or already up to date'),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          iconSize: 18,
          icon: const Icon(Icons.south),
          onPressed: (busy || !canPull) ? null : _pull,
        ),
      ],
    );
  }
}

class _GitLine extends StatelessWidget {
  final GitStatusDto status;
  const _GitLine({required this.status});

  @override
  Widget build(BuildContext context) {
    if (status.error != null) {
      return Text(
        'git: ${status.error}',
        style: const TextStyle(fontSize: 11, color: Color(0xFFF43F5E)),
        overflow: TextOverflow.ellipsis,
      );
    }
    return Row(
      children: [
        Text(
          status.branch ?? '?',
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            color: Color(0xFF22D3EE),
          ),
        ),
        if (status.shortSha != null) ...[
          const SizedBox(width: 6),
          Text(
            status.shortSha!,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: Color(0xFF94A3B8),
            ),
          ),
        ],
        if (status.latestTag != null) ...[
          const SizedBox(width: 8),
          Tooltip(
            message: 'Most recent tag on origin/'
                '${status.mainBranch ?? "main"}'
                '${(status.commitsSinceTag ?? 0) > 0 ? ", ${status.commitsSinceTag} commit(s) ahead at HEAD" : " (HEAD is at the tag)"}',
            child: _TagBadge(
              tag: status.latestTag!,
              ahead: status.commitsSinceTag ?? 0,
            ),
          ),
        ],
        const SizedBox(width: 10),
        Expanded(child: _Chips(status: status)),
        if (status.lastFetched != null)
          Text(
            'fetched ${_relative(status.lastFetched!)}',
            style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
          ),
      ],
    );
  }

  static String _relative(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 48) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

class _TagBadge extends StatelessWidget {
  final String tag;
  final int ahead;
  const _TagBadge({required this.tag, required this.ahead});

  @override
  Widget build(BuildContext context) {
    final label = ahead > 0 ? '$tag +$ahead' : tag;
    const color = Color(0xFFA78BFA); // muted purple — distinct from sha/branch.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.local_offer_outlined, size: 11, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _Chips extends StatelessWidget {
  final GitStatusDto status;
  const _Chips({required this.status});

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[];

    if (status.dirty > 0) {
      final lock = status.dirtyLock;
      final code = status.dirtyCode;
      final label = (lock > 0 && code > 0)
          ? '${status.dirty} dirty ($lock lock)'
          : lock > 0
              ? '$lock dirty (lock)'
              : '$code dirty';
      chips.add(_Chip(
        label: label,
        color: const Color(0xFFEAB308),
        tooltip:
            'Uncommitted changes in the working tree. Tap for details and commands.',
        onTap: () => showDirtyDialog(context, status),
      ));
    }

    if (status.behindUpstream != null && status.behindUpstream! > 0) {
      chips.add(_Chip(
        label: '↓${status.behindUpstream} upstream',
        color: const Color(0xFF22C55E),
        tooltip: 'Commits on the remote branch you don\'t have yet. '
            'Pull to apply.',
        onTap: () => showBehindUpstreamDialog(context, status),
      ));
    }

    if (status.aheadUpstream != null && status.aheadUpstream! > 0) {
      chips.add(_Chip(
        label: '↑${status.aheadUpstream} upstream',
        color: const Color(0xFF22D3EE),
        tooltip: 'Local commits not yet pushed to the remote.',
        onTap: () => showAheadUpstreamDialog(context, status),
      ));
    }

    if (status.upstream == null) {
      chips.add(_Chip(
        label: 'no upstream',
        color: const Color(0xFF94A3B8),
        tooltip:
            'Branch isn\'t tracking a remote — push with -u to set one up.',
        onTap: () => showNoUpstreamDialog(context, status),
      ));
    }

    if (status.behindMain != null && status.behindMain! > 0) {
      chips.add(_Chip(
        label: '↓${status.behindMain} ${status.mainBranch ?? "main"}',
        color: const Color(0xFFF43F5E),
        tooltip:
            'Commits on ${status.mainBranch ?? "main"} that aren\'t on this branch. '
            'A rebase or merge may be needed.',
        onTap: () => showBehindMainDialog(context, status),
      ));
    }

    return Wrap(spacing: 6, runSpacing: 4, children: chips);
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;
  const _Chip({
    required this.label,
    required this.color,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 350),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            border:
                Border.all(color: color.withValues(alpha: 0.5), width: 1),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            style:
                TextStyle(fontSize: 11, color: color, fontFamily: 'monospace'),
          ),
        ),
      ),
    );
  }
}
