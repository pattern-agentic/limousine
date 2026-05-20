import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/dto.dart';
import '../../../api_client.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/workspace_provider.dart';
import 'service_row.dart';

class ProjectCard extends ConsumerStatefulWidget {
  final LoadedProjectDto project;
  const ProjectCard({super.key, required this.project});

  @override
  ConsumerState<ProjectCard> createState() => _ProjectCardState();
}

class _ProjectCardState extends ConsumerState<ProjectCard> {
  bool _cloning = false;

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

  Future<void> _reloadProjectFile() async {
    try {
      await ref.read(apiClientProvider).reloadProject(widget.project.name);
      await ref.read(workspaceStateProvider.notifier).refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${widget.project.name}: limousine.proj reloaded')),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      _showReloadBlockedDialog(e);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Reload failed: $e')),
      );
    }
  }

  void _showReloadBlockedDialog(ApiException e) {
    List<String> running = const [];
    String message = e.message;
    try {
      final body = jsonDecode(e.message) as Map<String, dynamic>;
      message = (body['error'] as String?) ?? message;
      final list = body['runningServices'];
      if (list is List) {
        running = list.map((s) => (s as Map)['id'].toString()).toList();
      }
    } catch (_) {}
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reload blocked'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message),
              if (running.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('Running services:',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                const SizedBox(height: 4),
                ...running.map((id) => Text('  • $id',
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12))),
              ],
            ],
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

  @override
  Widget build(BuildContext context) {
    final project = widget.project;
    final canClone = !project.existsOnDisk && project.gitRepoUrl != null;

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
        subtitle: Text(
          project.resolvedPath,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (canClone) _cloneButton(),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, size: 20),
              tooltip: 'Project actions',
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'reload',
                  child: ListTile(
                    leading: Icon(Icons.refresh, size: 18),
                    title: Text('Reload project file'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                ),
                if (project.projectData?.agentGuide != null)
                  const PopupMenuItem(
                    value: 'agent-guide',
                    child: ListTile(
                      leading: Icon(Icons.info_outline, size: 18),
                      title: Text('Show agent guide'),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                    ),
                  ),
              ],
              onSelected: (v) {
                if (v == 'reload') _reloadProjectFile();
                if (v == 'agent-guide') _showGuide(context);
              },
            ),
          ],
        ),
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

  void _showGuide(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${widget.project.name} — Agent Guide'),
        content: SizedBox(
          width: 500,
          child: SelectableText(
            widget.project.projectData!.agentGuide!,
            style: const TextStyle(fontSize: 13, height: 1.5),
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
}
