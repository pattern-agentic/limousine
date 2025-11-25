import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../providers/workspace_provider.dart';
import '../../../services/logging_service.dart';
import '../../../services/storage_service.dart';

class SettingsDialog extends ConsumerStatefulWidget {
  const SettingsDialog({super.key});

  @override
  ConsumerState<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends ConsumerState<SettingsDialog> {
  late TextEditingController _sshKeyController;
  bool _hasChanges = false;

  @override
  void initState() {
    super.initState();
    _sshKeyController = TextEditingController();
  }

  @override
  void dispose() {
    _sshKeyController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final path = ref.read(currentWorkspacePathProvider);
    final workspace = await ref.read(workspaceProvider.future);
    if (path == null || workspace == null) return;

    final trimmedText = _sshKeyController.text.trim();
    final updated = trimmedText.isEmpty
        ? workspace.copyWith(clearGitSshKeyPath: true)
        : workspace.copyWith(gitSshKeyPath: trimmedText);
    await StorageService.saveWorkspace(path, updated);
    ref.invalidate(workspaceProvider);
    setState(() => _hasChanges = false);
  }

  @override
  Widget build(BuildContext context) {
    final workspaceAsync = ref.watch(workspaceProvider);

    return AlertDialog(
      title: const Text('Settings'),
      content: workspaceAsync.when(
        data: (workspace) {
          if (_sshKeyController.text.isEmpty && workspace?.gitSshKeyPath != null) {
            _sshKeyController.text = workspace!.gitSshKeyPath!;
          }
          return _buildContent(workspace);
        },
        loading: () => const SizedBox(
          height: 100,
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (e, _) => Text('Error: $e'),
      ),
      actions: [
        if (_hasChanges)
          TextButton(
            onPressed: _save,
            child: const Text('Save'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(_hasChanges ? 'Cancel' : 'Close'),
        ),
      ],
    );
  }

  Widget _buildContent(dynamic workspace) {
    return SizedBox(
      width: 400,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Limousine',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const Text('Version: 0.1.0'),
          const SizedBox(height: 16),
          const Text(
            'Log File',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          SelectableText(
            LoggingService.logFilePath,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          const SizedBox(height: 24),
          const Text(
            'Git SSH Key Path',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _sshKeyController,
            decoration: const InputDecoration(
              hintText: '/path/to/.ssh/id_rsa',
              helperText: 'Optional: SSH key to use for git clone operations',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            onChanged: (_) => setState(() => _hasChanges = true),
          ),
        ],
      ),
    );
  }
}
