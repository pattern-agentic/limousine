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
          project.existsOnDisk ? Icons.folder : Icons.folder_off,
          color: project.existsOnDisk ? Colors.green : Colors.orange,
        ),
        title: Text(project.name),
        subtitle: Text(
          project.resolvedPath,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        trailing: canClone ? _buildCloneButton() : null,
        children: [
          if (!project.existsOnDisk)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Project not found on disk'),
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
