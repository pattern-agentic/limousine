import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../../providers/workspace_provider.dart';
import '../../../services/env_service.dart';

class EnvDialog extends StatefulWidget {
  final ServiceInfo serviceInfo;

  const EnvDialog({super.key, required this.serviceInfo});

  @override
  State<EnvDialog> createState() => _EnvDialogState();
}

class _EnvDialogState extends State<EnvDialog> {
  EnvComparison? _comparison;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final config = widget.serviceInfo.moduleConfig;
      final activePath = p.join(
        widget.serviceInfo.projectPath,
        config.activeEnvFile,
      );
      final sourcePath = p.join(
        widget.serviceInfo.projectPath,
        config.sourceEnvFile,
      );
      final comparison = await EnvService.compareEnvFiles(activePath, sourcePath);
      setState(() {
        _comparison = comparison;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 600),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    'Environment Variables',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const Divider(),
              Expanded(child: _buildContent()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Text('Error: $_error'));
    }
    final cmp = _comparison!;

    if (!cmp.activeExists) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.warning, size: 48, color: Colors.orange),
            const SizedBox(height: 16),
            Text(
              'Env file missing',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Copy from ${widget.serviceInfo.moduleConfig.sourceEnvFile}?',
            ),
          ],
        ),
      );
    }

    return Row(
      children: [
        Expanded(
          child: _EnvPanel(
            title: 'Active (${widget.serviceInfo.moduleConfig.activeEnvFile})',
            content: cmp.activeContent,
            highlight: cmp.extraInActive,
          ),
        ),
        const VerticalDivider(),
        Expanded(
          child: _EnvPanel(
            title: 'Source (${widget.serviceInfo.moduleConfig.sourceEnvFile})',
            content: cmp.sourceContent,
            highlight: cmp.missingInActive,
          ),
        ),
      ],
    );
  }
}

class _EnvPanel extends StatelessWidget {
  final String title;
  final Map<String, String> content;
  final Set<String> highlight;

  const _EnvPanel({
    required this.title,
    required this.content,
    required this.highlight,
  });

  @override
  Widget build(BuildContext context) {
    final entries = content.entries.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(8),
            ),
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entry = entries[index];
                final isHighlighted = highlight.contains(entry.key);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '${entry.key}=${entry.value}',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: isHighlighted ? Colors.orange : Colors.white70,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
