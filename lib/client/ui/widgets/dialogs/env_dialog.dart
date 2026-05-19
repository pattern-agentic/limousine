import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/dto.dart';
import '../../../providers/api_provider.dart';

class EnvDialog extends ConsumerStatefulWidget {
  final String serviceId;
  const EnvDialog({super.key, required this.serviceId});

  @override
  ConsumerState<EnvDialog> createState() => _EnvDialogState();
}

class _EnvDialogState extends ConsumerState<EnvDialog> {
  EnvComparisonDto? _comparison;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final cmp = await ref.read(apiClientProvider).getEnv(widget.serviceId);
      setState(() {
        _comparison = cmp;
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
                  Text('Environment Variables',
                      style: Theme.of(context).textTheme.headlineSmall),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const Divider(),
              Expanded(child: _body()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text('Error: $_error'));
    final cmp = _comparison!;
    if (!cmp.activeExists) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.warning, size: 48, color: Colors.orange),
            SizedBox(height: 16),
            Text('Env file missing'),
          ],
        ),
      );
    }
    return Row(
      children: [
        Expanded(
          child: _EnvPanel(
            title: 'Active',
            content: cmp.activeContent,
            highlight: cmp.extraInActive,
          ),
        ),
        const VerticalDivider(),
        Expanded(
          child: _EnvPanel(
            title: 'Source',
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
  const _EnvPanel({required this.title, required this.content, required this.highlight});

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
              itemBuilder: (_, i) {
                final e = entries[i];
                final isHi = highlight.contains(e.key);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '${e.key}=${e.value}',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: isHi ? Colors.orange : Colors.white70,
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
