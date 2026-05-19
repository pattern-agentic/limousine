import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/dto.dart';
import '../../../providers/workspace_provider.dart';
import 'project_card.dart';

class DashboardTab extends ConsumerWidget {
  const DashboardTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wsAsync = ref.watch(workspaceStateProvider);
    return wsAsync.when(
      data: (ws) {
        if (!ws.open || ws.projects.isEmpty) {
          return const Center(child: Text('No projects in this workspace.'));
        }
        final projects = ws.projects.values.toList();
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: projects.length,
          itemBuilder: (_, i) => ProjectCard(project: projects[i]),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
    );
  }
}

extension LoadedProjectDtoUiExt on LoadedProjectDto {}
