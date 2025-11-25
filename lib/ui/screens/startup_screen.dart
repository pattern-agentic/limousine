import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import '../../providers/global_config_provider.dart';
import '../../providers/workspace_provider.dart';

class StartupScreen extends ConsumerWidget {
  const StartupScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configAsync = ref.watch(globalConfigProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Limousine')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: configAsync.when(
            data: (config) => _buildContent(context, ref, config),
            loading: () => const CircularProgressIndicator(),
            error: (e, _) => Text('Error: $e'),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    WidgetRef ref,
    dynamic config,
  ) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.directions_car, size: 64),
          const SizedBox(height: 24),
          const Text(
            'Select a Workspace',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          if (config.workspacePaths.isEmpty)
            const Text(
              'No workspaces found. Open a .limousine.wksp file to get started.',
              textAlign: TextAlign.center,
            )
          else
            ...config.workspacePaths.map<Widget>(
              (path) => _WorkspaceItem(path: path),
            ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () => _openWorkspace(context, ref),
            icon: const Icon(Icons.folder_open),
            label: const Text('Open Workspace File'),
          ),
        ],
      ),
    );
  }

  Future<void> _openWorkspace(BuildContext context, WidgetRef ref) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['wksp'],
      dialogTitle: 'Select Workspace File',
    );
    if (result == null || result.files.isEmpty) return;

    final path = result.files.first.path;
    if (path == null) return;

    await ref.read(globalConfigProvider.notifier).addWorkspace(path);
    ref.read(currentWorkspacePathProvider.notifier).state = path;
  }
}

class _WorkspaceItem extends ConsumerWidget {
  final String path;

  const _WorkspaceItem({required this.path});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.folder),
        title: Text(
          path.split('/').last,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          path,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () =>
                  ref.read(globalConfigProvider.notifier).removeWorkspace(path),
            ),
          ],
        ),
        onTap: () =>
            ref.read(currentWorkspacePathProvider.notifier).state = path,
      ),
    );
  }
}
