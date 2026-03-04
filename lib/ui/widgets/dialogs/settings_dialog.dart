import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../providers/workspace_provider.dart';
import '../../../mcp/mcp_config.dart';
import '../../../mcp/mcp_server_provider.dart';
import '../../../services/logging_service.dart';
import '../../../services/storage_service.dart';

class SettingsDialog extends ConsumerStatefulWidget {
  const SettingsDialog({super.key});

  @override
  ConsumerState<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends ConsumerState<SettingsDialog> {
  late TextEditingController _sshKeyController;
  late TextEditingController _mcpPortController;
  late TextEditingController _mcpTokenController;
  bool _mcpEnabled = false;
  bool _hasChanges = false;

  @override
  void initState() {
    super.initState();
    _sshKeyController = TextEditingController();
    _mcpPortController = TextEditingController(text: '6891');
    _mcpTokenController = TextEditingController();
  }

  @override
  void dispose() {
    _sshKeyController.dispose();
    _mcpPortController.dispose();
    _mcpTokenController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final path = ref.read(currentWorkspacePathProvider);
    final workspace = await ref.read(workspaceProvider.future);
    if (path == null || workspace == null) return;

    final trimmedText = _sshKeyController.text.trim();
    final mcpConfig = McpConfig(
      enabled: _mcpEnabled,
      port: int.tryParse(_mcpPortController.text) ?? 6891,
      token: _mcpTokenController.text.isEmpty ? null : _mcpTokenController.text,
    );
    final updated = (trimmedText.isEmpty
        ? workspace.copyWith(clearGitSshKeyPath: true)
        : workspace.copyWith(gitSshKeyPath: trimmedText))
        .copyWith(mcpConfig: mcpConfig);
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
          if (workspace?.mcpConfig != null) {
            final mcp = workspace!.mcpConfig!;
            if (_mcpPortController.text == '6891' && mcp.port != 6891) {
              _mcpPortController.text = mcp.port.toString();
            }
            if (_mcpTokenController.text.isEmpty && mcp.token != null) {
              _mcpTokenController.text = mcp.token!;
            }
            _mcpEnabled = mcp.enabled;
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
          const SizedBox(height: 24),
          Row(
            children: [
              const Text('MCP Server', style: TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              Switch(
                value: _mcpEnabled,
                onChanged: (v) => setState(() {
                  _mcpEnabled = v;
                  _hasChanges = true;
                }),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _mcpPortController,
            decoration: const InputDecoration(
              labelText: 'Port',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() => _hasChanges = true),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _mcpTokenController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Token',
              hintText: 'Optional bearer token for authentication',
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
