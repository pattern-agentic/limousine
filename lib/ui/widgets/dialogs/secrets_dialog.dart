import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../../providers/workspace_provider.dart';
import '../../../services/env_service.dart';

class SecretsDialog extends StatefulWidget {
  final ServiceInfo serviceInfo;

  const SecretsDialog({super.key, required this.serviceInfo});

  @override
  State<SecretsDialog> createState() => _SecretsDialogState();
}

class _SecretsDialogState extends State<SecretsDialog> {
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
        config.activeSecretsEnvFile,
      );
      final sourcePath = p.join(
        widget.serviceInfo.projectPath,
        config.sourceSecretsFile,
      );
      final comparison =
          await EnvService.compareEnvFiles(activePath, sourcePath);
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
                    'Secrets',
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
              'Secrets file missing',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Expected: ${widget.serviceInfo.moduleConfig.activeSecretsEnvFile}',
            ),
          ],
        ),
      );
    }

    return Row(
      children: [
        Expanded(
          child: _SecretsPanel(
            title:
                'Active (${widget.serviceInfo.moduleConfig.activeSecretsEnvFile})',
            keys: cmp.activeKeys.toList()..sort(),
            highlight: cmp.extraInActive,
          ),
        ),
        const VerticalDivider(),
        Expanded(
          child: _SecretsPanel(
            title:
                'Source (${widget.serviceInfo.moduleConfig.sourceSecretsFile})',
            keys: cmp.sourceKeys.toList()..sort(),
            highlight: cmp.missingInActive,
          ),
        ),
      ],
    );
  }
}

class _SecretsPanel extends StatelessWidget {
  final String title;
  final List<String> keys;
  final Set<String> highlight;

  const _SecretsPanel({
    required this.title,
    required this.keys,
    required this.highlight,
  });

  @override
  Widget build(BuildContext context) {
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
              itemCount: keys.length,
              itemBuilder: (context, index) {
                final key = keys[index];
                final isHighlighted = highlight.contains(key);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '$key=<hidden>',
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
