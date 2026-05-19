import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/dto.dart';
import '../../../providers/api_provider.dart';

/// Side-by-side diff editor for an env / secrets file pair.
/// Left: source (read-only). Right: active (editable per-row).
class EnvEditorDialog extends ConsumerStatefulWidget {
  final String title;
  final String serviceId;
  final bool isSecrets; // mask values + use setSecrets endpoint
  final Future<EnvComparisonDto> Function() loader;
  final Future<void> Function(Map<String, String>) saver;

  const EnvEditorDialog({
    super.key,
    required this.title,
    required this.serviceId,
    required this.isSecrets,
    required this.loader,
    required this.saver,
  });

  @override
  ConsumerState<EnvEditorDialog> createState() => _EnvEditorDialogState();
}

class _EnvEditorDialogState extends ConsumerState<EnvEditorDialog> {
  EnvComparisonDto? _comparison;
  String? _error;
  bool _loading = true;
  bool _saving = false;

  // Editable mirror of the active file. Order preserved by insertion order.
  final Map<String, TextEditingController> _controllers = {};
  final List<String> _order = []; // canonical key order for the active panel
  final Set<String> _revealed = {}; // keys whose secret values are currently shown
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final cmp = await widget.loader();
      _initFromComparison(cmp);
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

  void _initFromComparison(EnvComparisonDto cmp) {
    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();
    _order.clear();
    for (final entry in cmp.activeContent.entries) {
      _controllers[entry.key] = TextEditingController(text: entry.value);
      _order.add(entry.key);
    }
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  void _copyFromSource(String key) {
    final cmp = _comparison;
    if (cmp == null) return;
    final value = cmp.sourceContent[key] ?? '';
    setState(() {
      if (_controllers.containsKey(key)) {
        _controllers[key]!.text = value;
      } else {
        _controllers[key] = TextEditingController(text: value);
        _order.add(key);
      }
      _dirty = true;
    });
  }

  void _copyAllMissing() {
    final cmp = _comparison;
    if (cmp == null) return;
    for (final key in cmp.missingInActive) {
      _copyFromSource(key);
    }
  }

  void _removeKey(String key) {
    setState(() {
      _controllers.remove(key)?.dispose();
      _order.remove(key);
      _revealed.remove(key);
      _dirty = true;
    });
  }

  Future<void> _addKey() async {
    final key = await showDialog<String>(
      context: context,
      builder: (ctx) => const _NewKeyDialog(),
    );
    if (key == null || key.isEmpty || !mounted) return;
    if (_controllers.containsKey(key)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Key $key already exists')),
      );
      return;
    }
    setState(() {
      _controllers[key] = TextEditingController();
      _order.add(key);
      _dirty = true;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final content = <String, String>{
      for (final key in _order)
        if (_controllers[key] != null) key: _controllers[key]!.text,
    };
    try {
      await widget.saver(content);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${widget.title}: saved')),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100, maxHeight: 700),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _header(),
              const Divider(),
              Expanded(child: _body()),
              const SizedBox(height: 8),
              _footer(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Row(
      children: [
        Text(widget.title, style: Theme.of(context).textTheme.headlineSmall),
        const Spacer(),
        IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text('Error: $_error'));
    final cmp = _comparison!;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _sourcePanel(cmp)),
        const SizedBox(width: 12),
        Expanded(child: _activePanel(cmp)),
      ],
    );
  }

  Widget _sourcePanel(EnvComparisonDto cmp) {
    final entries = cmp.sourceContent.entries.toList();
    return EnvEditorPanel(
      title: 'Source · ${entries.length} key${entries.length == 1 ? '' : 's'}',
      missing: cmp.activeExists ? null : 'source file not found',
      child: ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: entries.length,
        itemBuilder: (_, i) {
          final e = entries[i];
          final isMissingInActive = !_controllers.containsKey(e.key);
          return _SourceRow(
            key: ValueKey(e.key),
            keyName: e.key,
            value: e.value,
            missingInActive: isMissingInActive,
            masked: false, // source values are template placeholders
            onCopy: isMissingInActive ? () => _copyFromSource(e.key) : null,
            onOverwrite: !isMissingInActive ? () => _copyFromSource(e.key) : null,
          );
        },
      ),
    );
  }

  Widget _activePanel(EnvComparisonDto cmp) {
    final missingCount = _order.where((k) => !cmp.sourceContent.containsKey(k)).length;
    return EnvEditorPanel(
      title: 'Active · ${_order.length} key${_order.length == 1 ? '' : 's'}'
          '${missingCount > 0 ? ' · $missingCount extra' : ''}',
      child: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: _order.length,
              itemBuilder: (_, i) {
                final key = _order[i];
                final extraInActive = !cmp.sourceContent.containsKey(key);
                return _ActiveRow(
                  key: ValueKey(key),
                  keyName: key,
                  controller: _controllers[key]!,
                  isSecret: widget.isSecrets,
                  revealed: _revealed.contains(key),
                  onToggleReveal: widget.isSecrets
                      ? () => setState(() {
                            _revealed.contains(key)
                                ? _revealed.remove(key)
                                : _revealed.add(key);
                          })
                      : null,
                  onChanged: _markDirty,
                  onRemove: () => _removeKey(key),
                  extraInActive: extraInActive,
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _addKey,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add key'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _footer() {
    final cmp = _comparison;
    final missingCount = cmp == null ? 0 : cmp.missingInActive.length;
    return Row(
      children: [
        if (missingCount > 0)
          OutlinedButton.icon(
            onPressed: _copyAllMissing,
            icon: const Icon(Icons.keyboard_double_arrow_right, size: 16),
            label: Text('Copy $missingCount missing from source'),
          ),
        const Spacer(),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(_dirty ? 'Cancel' : 'Close'),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: (_dirty && !_saving) ? _save : null,
          icon: _saving
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save, size: 16),
          label: const Text('Save'),
        ),
      ],
    );
  }
}

class EnvEditorPanel extends StatelessWidget {
  final String title;
  final String? missing;
  final Widget child;
  const EnvEditorPanel({super.key, required this.title, this.missing, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0B1120),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Text(
              title,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          if (missing != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(missing!,
                  style: const TextStyle(fontSize: 11, color: Colors.orange)),
            ),
          const Divider(height: 1),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _SourceRow extends StatelessWidget {
  final String keyName;
  final String value;
  final bool missingInActive;
  final bool masked;
  final VoidCallback? onCopy;
  final VoidCallback? onOverwrite;

  const _SourceRow({
    super.key,
    required this.keyName,
    required this.value,
    required this.missingInActive,
    required this.masked,
    this.onCopy,
    this.onOverwrite,
  });

  @override
  Widget build(BuildContext context) {
    final highlightColor = missingInActive ? Colors.orange : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (missingInActive)
            const Icon(Icons.warning, color: Colors.orange, size: 14)
          else
            const SizedBox(width: 14),
          const SizedBox(width: 4),
          Expanded(
            child: Tooltip(
              message: missingInActive ? 'Missing in active' : '',
              child: Text(
                '$keyName=${masked ? '••••' : value}',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: highlightColor ?? Colors.white70,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          if (onCopy != null)
            IconButton(
              tooltip: 'Copy to active',
              icon: const Icon(Icons.arrow_forward, size: 16),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 28, height: 28),
              onPressed: onCopy,
            )
          else if (onOverwrite != null)
            IconButton(
              tooltip: 'Overwrite active with source value',
              icon: const Icon(Icons.refresh, size: 14),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 28, height: 28),
              onPressed: onOverwrite,
            ),
        ],
      ),
    );
  }
}

class _ActiveRow extends StatelessWidget {
  final String keyName;
  final TextEditingController controller;
  final bool isSecret;
  final bool revealed;
  final VoidCallback? onToggleReveal;
  final VoidCallback onChanged;
  final VoidCallback onRemove;
  final bool extraInActive;

  const _ActiveRow({
    super.key,
    required this.keyName,
    required this.controller,
    required this.isSecret,
    required this.revealed,
    required this.onToggleReveal,
    required this.onChanged,
    required this.onRemove,
    required this.extraInActive,
  });

  @override
  Widget build(BuildContext context) {
    final obscured = isSecret && !revealed;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (extraInActive)
            const Tooltip(
              message: 'Not in source — likely stale',
              child: Icon(Icons.warning, color: Colors.orange, size: 14),
            )
          else
            const SizedBox(width: 14),
          const SizedBox(width: 4),
          SizedBox(
            width: 180,
            child: Text(
              keyName,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              obscureText: obscured,
              onChanged: (_) => onChanged(),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                border: OutlineInputBorder(),
              ),
            ),
          ),
          if (onToggleReveal != null)
            IconButton(
              tooltip: revealed ? 'Hide value' : 'Reveal value',
              icon: Icon(revealed ? Icons.visibility_off : Icons.visibility, size: 14),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 28, height: 28),
              onPressed: onToggleReveal,
            ),
          IconButton(
            tooltip: 'Remove',
            icon: const Icon(Icons.close, size: 14),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

class _NewKeyDialog extends StatefulWidget {
  const _NewKeyDialog();

  @override
  State<_NewKeyDialog> createState() => _NewKeyDialogState();
}

class _NewKeyDialogState extends State<_NewKeyDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add key'),
      content: SizedBox(
        width: 320,
        child: TextField(
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'KEY_NAME',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('Add'),
        ),
      ],
    );
  }
}

/// Convenience constructors so callers don't need to know about loader/saver.
class EnvEditorOpener {
  static Future<void> openEnv(BuildContext context, WidgetRef ref, String serviceId) {
    final api = ref.read(apiClientProvider);
    return showDialog(
      context: context,
      builder: (_) => EnvEditorDialog(
        title: 'Environment',
        serviceId: serviceId,
        isSecrets: false,
        loader: () => api.getEnv(serviceId),
        saver: (content) => api.setEnv(serviceId, content),
      ),
    );
  }

}
