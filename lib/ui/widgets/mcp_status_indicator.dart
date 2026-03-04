import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../mcp/mcp_config.dart';
import '../../mcp/mcp_server_provider.dart';
import '../../providers/workspace_provider.dart';
import '../../services/storage_service.dart';

class McpStatusIndicator extends ConsumerWidget {
  const McpStatusIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mcpState = ref.watch(mcpServerProvider);
    final isRunning = mcpState.status == McpServerStatus.running;

    return IconButton(
      tooltip: isRunning ? 'MCP server running on port ${mcpState.port}' : 'MCP server stopped',
      onPressed: () => showDialog(context: context, builder: (_) => const _McpPopoverDialog()),
      icon: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isRunning ? const Color(0xFF22C55E) : Colors.grey,
            ),
          ),
          if (isRunning) ...[
            const SizedBox(width: 4),
            Text(
              ':${mcpState.port}',
              style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.7)),
            ),
          ],
        ],
      ),
    );
  }
}

class _McpPopoverDialog extends ConsumerStatefulWidget {
  const _McpPopoverDialog();

  @override
  ConsumerState<_McpPopoverDialog> createState() => _McpPopoverDialogState();
}

class _McpPopoverDialogState extends ConsumerState<_McpPopoverDialog> {
  late TextEditingController _portController;
  late TextEditingController _tokenController;
  bool _obscureToken = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _portController = TextEditingController();
    _tokenController = TextEditingController();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final workspace = await ref.read(workspaceProvider.future);
    final config = workspace?.mcpConfig ?? McpConfig();
    if (!mounted) return;
    _portController.text = config.port.toString();
    _tokenController.text = config.token ?? '';
  }

  @override
  void dispose() {
    _portController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  McpConfig _currentConfig() {
    return McpConfig(
      enabled: true,
      port: int.tryParse(_portController.text) ?? 6891,
      token: _tokenController.text.isEmpty ? null : _tokenController.text,
    );
  }

  Future<void> _saveConfig(McpConfig config) async {
    final path = ref.read(currentWorkspacePathProvider);
    final workspace = await ref.read(workspaceProvider.future);
    if (path == null || workspace == null) return;
    final updated = workspace.copyWith(mcpConfig: config);
    await StorageService.saveWorkspace(path, updated);
    ref.invalidate(workspaceProvider);
  }

  Future<void> _toggle() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final mcpState = ref.read(mcpServerProvider);
      final notifier = ref.read(mcpServerProvider.notifier);

      if (mcpState.status == McpServerStatus.running) {
        await notifier.stop();
        final config = _currentConfig().copyWith(enabled: false);
        await _saveConfig(config);
      } else {
        final config = _currentConfig();
        await _saveConfig(config);
        await notifier.start(config);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _copyConfig(String label, Map<String, dynamic> config) {
    final json = const JsonEncoder.withIndent('  ').convert(config);
    Clipboard.setData(ClipboardData(text: json));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label config copied to clipboard'), duration: const Duration(seconds: 2)),
    );
  }

  void _copyClaudeCodeConfig() {
    final config = _currentConfig();
    final url = 'http://localhost:${config.port}/mcp';
    _copyConfig('Claude Code', {
      'mcpServers': {
        'limousine': {
          'type': 'http',
          'url': url,
        },
      },
    });
  }

  void _copyClaudeDesktopConfig() {
    final config = _currentConfig();
    final url = 'http://localhost:${config.port}/mcp';
    _copyConfig('Claude Desktop', {
      'mcpServers': {
        'limousine': {
          'type': 'http',
          'url': url,
        },
      },
    });
  }

  @override
  Widget build(BuildContext context) {
    final mcpState = ref.watch(mcpServerProvider);
    final isRunning = mcpState.status == McpServerStatus.running;
    final isStarting = mcpState.status == McpServerStatus.starting;

    return AlertDialog(
      title: const Text('MCP Server'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isRunning
                        ? const Color(0xFF22C55E)
                        : mcpState.status == McpServerStatus.error
                            ? const Color(0xFFF43F5E)
                            : Colors.grey,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  isRunning
                      ? 'Running on port ${mcpState.port}'
                      : isStarting
                          ? 'Starting...'
                          : mcpState.status == McpServerStatus.error
                              ? 'Error'
                              : 'Stopped',
                  style: const TextStyle(fontSize: 14),
                ),
              ],
            ),
            if (mcpState.error != null) ...[
              const SizedBox(height: 8),
              Text(mcpState.error!, style: const TextStyle(color: Color(0xFFF43F5E), fontSize: 12)),
            ],
            const SizedBox(height: 16),
            const Text('Port', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 4),
            TextField(
              controller: _portController,
              enabled: !isRunning,
              decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, hintText: '6891'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              keyboardType: TextInputType.number,
            ),
            // Token auth disabled for now
            // const SizedBox(height: 12),
            // const Text('Token', ...),
            if (isRunning) ...[
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _copyClaudeCodeConfig,
                    icon: const Icon(Icons.copy, size: 14),
                    label: const Text('Claude Code config', style: TextStyle(fontSize: 12)),
                  ),
                  OutlinedButton.icon(
                    onPressed: _copyClaudeDesktopConfig,
                    icon: const Icon(Icons.copy, size: 14),
                    label: const Text('Claude Desktop config', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('Request logging', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  const Spacer(),
                  if (mcpState.logs.isNotEmpty)
                    TextButton(
                      onPressed: () => ref.read(mcpServerProvider.notifier).clearLogs(),
                      child: const Text('Clear', style: TextStyle(fontSize: 12)),
                    ),
                  Switch(
                    value: mcpState.verboseLogging,
                    onChanged: (v) => ref.read(mcpServerProvider.notifier).setVerboseLogging(v),
                  ),
                ],
              ),
              if (mcpState.logs.isNotEmpty)
                Container(
                  height: 200,
                  decoration: BoxDecoration(
                    color: const Color(0xFF020617),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white.withOpacity(0.1)),
                  ),
                  child: ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: mcpState.logs.length,
                    reverse: true,
                    itemBuilder: (context, index) {
                      final entry = mcpState.logs[mcpState.logs.length - 1 - index];
                      final time = '${entry.timestamp.hour.toString().padLeft(2, '0')}:'
                          '${entry.timestamp.minute.toString().padLeft(2, '0')}:'
                          '${entry.timestamp.second.toString().padLeft(2, '0')}';
                      final dirColor = switch (entry.direction) {
                        'REQ' => const Color(0xFF3B82F6),
                        'RES' => const Color(0xFF22C55E),
                        'ERR' => const Color(0xFFF43F5E),
                        'SYS' => const Color(0xFF94A3B8),
                        _ => Colors.white,
                      };
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: SelectableText.rich(
                          TextSpan(
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                            children: [
                              TextSpan(
                                text: '$time ',
                                style: TextStyle(color: Colors.white.withOpacity(0.4)),
                              ),
                              TextSpan(
                                text: '${entry.direction} ',
                                style: TextStyle(color: dirColor, fontWeight: FontWeight.bold),
                              ),
                              TextSpan(
                                text: '${entry.method} ',
                                style: const TextStyle(color: Color(0xFF22D3EE)),
                              ),
                              TextSpan(
                                text: entry.body.length > 120
                                    ? '${entry.body.substring(0, 120)}...'
                                    : entry.body,
                                style: TextStyle(color: Colors.white.withOpacity(0.6)),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: _busy || isStarting ? null : _toggle,
          child: _busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(isRunning ? 'Stop' : 'Start'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
