import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/dto.dart';
import '../../../../core/module.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/workspace_provider.dart';

/// Side-by-side diff editor for an env / secrets file pair.
/// Left: source (read-only). Right: active (editable per-row).
class EnvEditorDialog extends ConsumerStatefulWidget {
  final String title;
  final String serviceId;
  final bool isSecrets; // mask values + use setSecrets endpoint
  final String? sourceFile;
  final String? activeFile;
  final Future<EnvComparisonDto> Function() loader;
  final Future<void> Function(Map<String, String>) saver;

  const EnvEditorDialog({
    super.key,
    required this.title,
    required this.serviceId,
    required this.isSecrets,
    this.sourceFile,
    this.activeFile,
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

  // Two controllers, mirrored by a clamped listener so the panels scroll in
  // lockstep. When the shorter side reaches its bottom, the longer one keeps
  // going. The `_syncing` flag guards against the listener loop that would
  // otherwise fire when our own programmatic jumpTo triggers the other side's
  // listener.
  final ScrollController _scrollSource = ScrollController();
  final ScrollController _scrollActive = ScrollController();
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _scrollSource.addListener(() => _mirror(_scrollSource, _scrollActive));
    _scrollActive.addListener(() => _mirror(_scrollActive, _scrollSource));
    _load();
  }

  void _mirror(ScrollController from, ScrollController to) {
    if (_syncing) return;
    if (!to.hasClients) return;
    final target = from.offset.clamp(0.0, to.position.maxScrollExtent);
    if ((to.offset - target).abs() < 0.5) return;
    _syncing = true;
    to.jumpTo(target);
    _syncing = false;
  }

  @override
  void dispose() {
    _scrollSource.dispose();
    _scrollActive.dispose();
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
    final size = MediaQuery.of(context).size;
    final width = (size.width - 48).clamp(800.0, 1800.0);
    final height = (size.height - 48).clamp(500.0, 1200.0);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: SizedBox(
        width: width,
        height: height,
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
      filePath: widget.sourceFile,
      missing: cmp.activeExists ? null : 'source file not found',
      child: ListView.builder(
        controller: _scrollSource,
        padding: const EdgeInsets.all(8),
        itemCount: entries.length,
        itemBuilder: (_, i) {
          final e = entries[i];
          final isMissingInActive = !_controllers.containsKey(e.key);
          return _RowCard(
            child: _SourceRow(
              key: ValueKey(e.key),
              keyName: e.key,
              value: e.value,
              missingInActive: isMissingInActive,
              masked: false,
              onCopy: isMissingInActive ? () => _copyFromSource(e.key) : null,
              onOverwrite:
                  !isMissingInActive ? () => _copyFromSource(e.key) : null,
            ),
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
      filePath: widget.activeFile,
      child: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollActive,
              padding: const EdgeInsets.all(8),
              itemCount: _order.length,
              itemBuilder: (_, i) {
                final key = _order[i];
                final extraInActive = !cmp.sourceContent.containsKey(key);
                return _RowCard(
                  child: _ActiveRow(
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
                  ),
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
  final String? filePath;
  final String? missing;
  final Widget child;
  const EnvEditorPanel({
    super.key,
    required this.title,
    this.filePath,
    this.missing,
    required this.child,
  });

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
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
                if (filePath != null) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      filePath!,
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: Color(0xFF94A3B8),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          ),
          // Always reserve a fixed-height line under the title so panels with
          // and without a `missing` message stay vertically aligned. With one
          // side hidden under "values hidden — unlock to view", the other side
          // would otherwise start its rows higher up.
          SizedBox(
            height: 18,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                missing ?? '',
                style: const TextStyle(fontSize: 11, color: Colors.orange),
              ),
            ),
          ),
          const SizedBox(height: 4),
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
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header row: key name + trailing action.
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (missingInActive)
                const Tooltip(
                  message: 'Missing in active',
                  child: Icon(Icons.warning, color: Colors.orange, size: 14),
                )
              else
                const SizedBox(width: 14),
              const SizedBox(width: 6),
              Expanded(
                child: SelectableText(
                  keyName,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: highlightColor ?? const Color(0xFFE5E7EB),
                  ),
                ),
              ),
              if (onCopy != null)
                IconButton(
                  tooltip: 'Copy to active',
                  icon: const Icon(Icons.arrow_forward, size: 16),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints.tightFor(width: 28, height: 28),
                  onPressed: onCopy,
                )
              else if (onOverwrite != null)
                IconButton(
                  tooltip: 'Overwrite active with source value',
                  icon: const Icon(Icons.refresh, size: 14),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints.tightFor(width: 28, height: 28),
                  onPressed: onOverwrite,
                )
              else
                const SizedBox(width: 28),
            ],
          ),
          const SizedBox(height: 4),
          // Value, indented under the key.
          Padding(
            padding: const EdgeInsets.only(left: 20, right: 4, bottom: 4),
            child: SelectableText(
              masked ? '••••' : value,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.4,
                color: Color(0xFF94A3B8),
              ),
            ),
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
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header row: key name + trailing actions.
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (extraInActive)
                const Tooltip(
                  message: 'Not in source — likely stale',
                  child: Icon(Icons.warning, color: Colors.orange, size: 14),
                )
              else
                const SizedBox(width: 14),
              const SizedBox(width: 6),
              Expanded(
                child: SelectableText(
                  keyName,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFE5E7EB),
                  ),
                ),
              ),
              if (onToggleReveal != null)
                IconButton(
                  tooltip: revealed ? 'Hide value' : 'Reveal value',
                  icon: Icon(
                      revealed ? Icons.visibility_off : Icons.visibility,
                      size: 14),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints.tightFor(width: 28, height: 28),
                  onPressed: onToggleReveal,
                ),
              IconButton(
                tooltip: 'Remove',
                icon: const Icon(Icons.close, size: 14),
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints.tightFor(width: 28, height: 28),
                onPressed: onRemove,
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Value field, indented under the key.
          Padding(
            padding: const EdgeInsets.only(left: 20, right: 4, bottom: 4),
            child: TextField(
              controller: controller,
              obscureText: obscured,
              onChanged: (_) => onChanged(),
              minLines: 1,
              maxLines: obscured ? 1 : 6,
              style: const TextStyle(
                  fontFamily: 'monospace', fontSize: 13, height: 1.4),
              decoration: kEditorFieldDecoration,
            ),
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

/// Shared TextField decoration for the editor's value inputs. Muted border
/// (was a bright `Colors.white` outline by default, visually loud against
/// the dark panels) and tighter vertical padding so the active card's
/// intrinsic height stays close to the source's read-only-text card.
const kEditorFieldDecoration = InputDecoration(
  isDense: true,
  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
  border: OutlineInputBorder(
    borderSide: BorderSide(color: Color(0xFF334155)),
  ),
  enabledBorder: OutlineInputBorder(
    borderSide: BorderSide(color: Color(0xFF334155)),
  ),
  focusedBorder: OutlineInputBorder(
    borderSide: BorderSide(color: Color(0xFF22D3EE)),
  ),
);

/// Visual wrapper around every row in either panel. Same chrome on both
/// sides so the two columns read as a paired card per setting.
class _RowCard extends StatelessWidget {
  final Widget child;
  const _RowCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF111B2D),
        border: Border.all(color: const Color(0xFF1E293B)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: child,
    );
  }
}

/// Convenience constructors so callers don't need to know about loader/saver.
class EnvEditorOpener {
  static Future<void> openEnv(BuildContext context, WidgetRef ref, String serviceId) {
    final api = ref.read(apiClientProvider);
    final cfg = lookupModuleConfig(ref, serviceId);
    return showDialog(
      context: context,
      builder: (_) => EnvEditorDialog(
        title: 'Environment',
        serviceId: serviceId,
        isSecrets: false,
        sourceFile: cfg?.sourceEnvFile,
        activeFile: cfg?.activeEnvFile,
        loader: () => api.getEnv(serviceId),
        saver: (content) => api.setEnv(serviceId, content),
      ),
    );
  }
}

/// Find a service's `ModuleConfig` via the loaded workspace state. Used by
/// the env + secrets openers to render file paths under the panel titles.
ModuleConfig? lookupModuleConfig(WidgetRef ref, String serviceId) {
  final svc = ref
      .read(allServicesProvider)
      .where((s) => s.id == serviceId)
      .firstOrNull;
  return svc?.moduleConfig;
}
