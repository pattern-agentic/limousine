import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/dto.dart';
import '../../../providers/git_status_provider.dart';
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
          itemCount: projects.length + 1,
          itemBuilder: (_, i) {
            if (i == 0) return const _DashboardHeader();
            return ProjectCard(project: projects[i - 1]);
          },
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
    );
  }
}

class _DashboardHeader extends ConsumerWidget {
  const _DashboardHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final anyInFlight =
        ref.watch(gitStatusProvider.select((b) => b.inFlight.isNotEmpty));
    final knownCount =
        ref.watch(gitStatusProvider.select((b) => b.byProject.length));

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          const Text(
            'Projects',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
          ),
          const Spacer(),
          Tooltip(
            message: knownCount == 0
                ? 'Waiting for project status to load…'
                : 'Check for updates: run `git fetch` against every repo '
                    'in parallel. Updates the behind/ahead counts.',
            child: TextButton.icon(
              icon: anyInFlight
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_sync, size: 16),
              label: const Text('Fetch all'),
              onPressed: (knownCount == 0 || anyInFlight)
                  ? null
                  : () => ref.read(gitStatusProvider.notifier).refreshAll(),
            ),
          ),
        ],
      ),
    );
  }
}

extension LoadedProjectDtoUiExt on LoadedProjectDto {}
