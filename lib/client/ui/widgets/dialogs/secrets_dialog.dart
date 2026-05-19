import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/dto.dart';
import '../../../providers/api_provider.dart';

class SecretsDialog extends ConsumerStatefulWidget {
  final String serviceId;
  const SecretsDialog({super.key, required this.serviceId});

  @override
  ConsumerState<SecretsDialog> createState() => _SecretsDialogState();
}

class _SecretsDialogState extends ConsumerState<SecretsDialog> {
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
      final cmp = await ref.read(apiClientProvider).getSecrets(widget.serviceId);
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
                  Text('Secrets',
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
            Text('Secrets file missing'),
          ],
        ),
      );
    }
    return Row(
      children: [
        Expanded(
          child: _Panel(
            title: 'Active',
            keys: cmp.activeKeys.toList()..sort(),
            highlight: cmp.extraInActive,
          ),
        ),
        const VerticalDivider(),
        Expanded(
          child: _Panel(
            title: 'Source',
            keys: cmp.sourceKeys.toList()..sort(),
            highlight: cmp.missingInActive,
          ),
        ),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  final String title;
  final List<String> keys;
  final Set<String> highlight;
  const _Panel({required this.title, required this.keys, required this.highlight});

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
              itemBuilder: (_, i) {
                final k = keys[i];
                final isHi = highlight.contains(k);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '$k=<hidden>',
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
