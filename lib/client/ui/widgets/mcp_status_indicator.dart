import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/mcp_provider.dart';

class McpStatusIndicator extends ConsumerWidget {
  const McpStatusIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mcp = ref.watch(mcpProvider);
    final running = mcp.status == McpStatus.running;

    return IconButton(
      tooltip: running ? 'MCP server running on port ${mcp.port}' : 'MCP server stopped',
      onPressed: () => showDialog(
        context: context,
        builder: (_) => const _McpDialog(),
      ),
      icon: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: running ? const Color(0xFF22C55E) : Colors.grey,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            running ? 'mcp:${mcp.port}' : 'mcp: off',
            style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.7)),
          ),
        ],
      ),
    );
  }
}

class _McpDialog extends ConsumerStatefulWidget {
  const _McpDialog();

  @override
  ConsumerState<_McpDialog> createState() => _McpDialogState();
}

class _McpDialogState extends ConsumerState<_McpDialog> {
  final _portController = TextEditingController();
  bool _busy = false;
  bool _portInitialized = false;

  @override
  void dispose() {
    _portController.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    setState(() => _busy = true);
    try {
      final mcp = ref.read(mcpProvider);
      final notifier = ref.read(mcpProvider.notifier);
      if (mcp.status == McpStatus.running) {
        await notifier.stop();
      } else {
        await notifier.start(port: int.tryParse(_portController.text));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _copyConfig(String label, Map<String, dynamic> payload) {
    Clipboard.setData(ClipboardData(
      text: const JsonEncoder.withIndent('  ').convert(payload),
    ));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label config copied to clipboard'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mcp = ref.watch(mcpProvider);
    if (!_portInitialized) {
      _portController.text = mcp.port.toString();
      _portInitialized = true;
    }

    final running = mcp.status == McpStatus.running;
    final starting = mcp.status == McpStatus.starting;
    final error = mcp.status == McpStatus.error;

    final mcpUrl = 'http://localhost:${mcp.port}/mcp';
    final claudeConfig = {
      'mcpServers': {
        'limousine': {'type': 'http', 'url': mcpUrl},
      },
    };

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
                    color: running
                        ? const Color(0xFF22C55E)
                        : error
                            ? const Color(0xFFF43F5E)
                            : Colors.grey,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  running
                      ? 'Running on port ${mcp.port}'
                      : starting
                          ? 'Starting…'
                          : error
                              ? 'Error'
                              : 'Stopped',
                  style: const TextStyle(fontSize: 14),
                ),
              ],
            ),
            if (mcp.error != null) ...[
              const SizedBox(height: 8),
              Text(mcp.error!,
                  style: const TextStyle(color: Color(0xFFF43F5E), fontSize: 12)),
            ],
            const SizedBox(height: 16),
            const Text('Port',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 4),
            TextField(
              controller: _portController,
              enabled: !running,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
                hintText: '6891',
              ),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              keyboardType: TextInputType.number,
            ),
            if (running) ...[
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _copyConfig('Claude Code', claudeConfig),
                    icon: const Icon(Icons.copy, size: 14),
                    label: const Text('Claude Code config',
                        style: TextStyle(fontSize: 12)),
                  ),
                  OutlinedButton.icon(
                    onPressed: () =>
                        _copyConfig('Claude Desktop', claudeConfig),
                    icon: const Icon(Icons.copy, size: 14),
                    label: const Text('Claude Desktop config',
                        style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'URL: $mcpUrl',
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 11, color: Colors.white70),
              ),
            ],
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: _busy || starting ? null : _toggle,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(running ? 'Stop' : 'Start'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

