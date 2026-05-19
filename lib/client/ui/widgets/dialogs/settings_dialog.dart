import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/workspace.dart';
import '../../../providers/workspace_provider.dart';

class SettingsDialog extends ConsumerStatefulWidget {
  const SettingsDialog({super.key});

  @override
  ConsumerState<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends ConsumerState<SettingsDialog> {
  final _sshKeyController = TextEditingController();
  final _mcpPortController = TextEditingController();
  bool _initialized = false;
  bool _mcpEnabled = false;
  bool _dirty = false;
  bool _saving = false;

  @override
  void dispose() {
    _sshKeyController.dispose();
    _mcpPortController.dispose();
    super.dispose();
  }

  void _initFrom(Workspace ws) {
    if (_initialized) return;
    _sshKeyController.text = ws.gitSshKeyPath ?? '';
    final mcp = ws.mcpConfig ?? McpConfig();
    _mcpEnabled = mcp.enabled;
    _mcpPortController.text = mcp.port.toString();
    _initialized = true;
  }

  Future<void> _save() async {
    final ws = ref.read(workspaceStateProvider).valueOrNull?.workspace;
    if (ws == null) return;
    setState(() => _saving = true);
    try {
      final sshKey = _sshKeyController.text.trim();
      final mcpConfig = McpConfig(
        enabled: _mcpEnabled,
        port: int.tryParse(_mcpPortController.text) ?? 6891,
        token: ws.mcpConfig?.token,
      );
      final updated = (sshKey.isEmpty
              ? ws.copyWith(clearGitSshKeyPath: true)
              : ws.copyWith(gitSshKeyPath: sshKey))
          .copyWith(mcpConfig: mcpConfig);
      await ref.read(workspaceStateProvider.notifier).saveWorkspace(updated);
      if (mounted) setState(() => _dirty = false);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wsAsync = ref.watch(workspaceStateProvider);
    final ws = wsAsync.valueOrNull?.workspace;
    if (ws != null) _initFrom(ws);

    return AlertDialog(
      title: const Text('Settings'),
      content: SizedBox(
        width: 440,
        child: ws == null
            ? const SizedBox(height: 100, child: Center(child: CircularProgressIndicator()))
            : _content(ws),
      ),
      actions: [
        if (_dirty)
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(_dirty ? 'Cancel' : 'Close'),
        ),
      ],
    );
  }

  Widget _content(Workspace ws) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Limousine', style: TextStyle(fontWeight: FontWeight.bold)),
        const Text('Version: 0.2.0'),
        const SizedBox(height: 16),
        const Text('Workspace', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        SelectableText(
          ref.read(workspaceStateProvider).valueOrNull?.path ?? '',
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
        const SizedBox(height: 16),
        const Text('Git SSH Key Path',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        TextField(
          controller: _sshKeyController,
          decoration: const InputDecoration(
            hintText: '/path/to/.ssh/id_rsa',
            helperText: 'Optional: SSH key for git clone operations',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          onChanged: (_) => setState(() => _dirty = true),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            const Text('MCP Server',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            Switch(
              value: _mcpEnabled,
              onChanged: (v) => setState(() {
                _mcpEnabled = v;
                _dirty = true;
              }),
            ),
          ],
        ),
        Text(
          _mcpEnabled
              ? 'Starts automatically when this workspace opens.'
              : 'Disabled. Toggle on to auto-start on workspace open.',
          style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.6)),
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
          onChanged: (_) => setState(() => _dirty = true),
        ),
      ],
    );
  }
}
