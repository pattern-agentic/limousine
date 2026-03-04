import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../providers/workspace_provider.dart';
import '../../../services/process_service.dart';
import 'service_row.dart';

class ProjectCard extends ConsumerStatefulWidget {
  final LoadedProject project;

  const ProjectCard({super.key, required this.project});

  @override
  ConsumerState<ProjectCard> createState() => _ProjectCardState();
}

class _ProjectCardState extends ConsumerState<ProjectCard> {
  bool _isCloning = false;

  @override
  Widget build(BuildContext context) {
    final project = widget.project;
    final hasGitUrl = project.gitRepoUrl != null;
    final canClone = !project.existsOnDisk && hasGitUrl;

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: ExpansionTile(
        leading: Icon(
          project.loadError != null
              ? Icons.error_outline
              : project.existsOnDisk ? Icons.folder : Icons.folder_off,
          color: project.loadError != null
              ? const Color(0xFFF43F5E)
              : project.existsOnDisk ? Colors.green : Colors.orange,
        ),
        title: Text(project.name),
        subtitle: Text(
          project.resolvedPath,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (project.projectData?.agentGuide != null)
              IconButton(
                icon: const Icon(Icons.info_outline, size: 20),
                tooltip: 'Agent guide',
                onPressed: () => _showAgentGuide(context),
              ),
            if (canClone) _buildCloneButton(),
          ],
        ),
        children: [
          if (!project.existsOnDisk)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Project not found on disk'),
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
              child: Text('No .limousine.proj file found'),
            )
          else
            ...project.projectData!.modules.expand(
              (module) => module.services.values.map(
                (service) => ServiceRow(
                  projectPath: project.resolvedPath,
                  moduleName: module.name,
                  moduleConfig: module.config,
                  service: service,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCloneButton() {
    if (_isCloning) {
      return const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return IconButton(
      icon: const Icon(Icons.download),
      tooltip: 'Clone repository',
      onPressed: _clone,
    );
  }

  void _showAgentGuide(BuildContext context) {
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

  Future<void> _clone() async {
    final url = widget.project.gitRepoUrl;
    if (url == null) return;

    final workspace = ref.read(workspaceProvider).valueOrNull;
    final sshKeyPath = workspace?.gitSshKeyPath;

    setState(() => _isCloning = true);
    try {
      final result = await ProcessService.runGitClone(
        url,
        widget.project.resolvedPath,
        sshKeyPath: sshKeyPath,
      );
      if (result.exitCode != 0) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Clone failed: ${result.stderr}')),
          );
        }
      } else {
        ref.read(projectsProvider.notifier).refresh();
      }
    } finally {
      if (mounted) setState(() => _isCloning = false);
    }
  }
}
