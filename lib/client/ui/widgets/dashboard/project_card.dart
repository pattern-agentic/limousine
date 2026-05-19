import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/dto.dart';
import 'service_row.dart';

class ProjectCard extends ConsumerWidget {
  final LoadedProjectDto project;
  const ProjectCard({super.key, required this.project});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
        trailing: project.projectData?.agentGuide != null
            ? IconButton(
                icon: const Icon(Icons.info_outline, size: 20),
                tooltip: 'Agent guide',
                onPressed: () => _showGuide(context),
              )
            : null,
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

  void _showGuide(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${project.name} — Agent Guide'),
        content: SizedBox(
          width: 500,
          child: SelectableText(
            project.projectData!.agentGuide!,
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

