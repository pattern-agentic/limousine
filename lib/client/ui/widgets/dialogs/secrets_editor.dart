import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/dto.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/secret_store_provider.dart';
import 'env_editor.dart' show EnvEditorPanel, kEditorFieldDecoration;

/// Two-phase dialog:
///   Phase 1: keys-only preview, no password sent. Shows what is currently
///            encrypted on disk + what the source template expects.
///   Phase 2: full editor, after the user types the secret-store password in the
///            inline gate. Password is held in this widget's state only and
///            sent as an Authorization header on each value-bearing call.
class SecretsEditorDialog extends ConsumerStatefulWidget {
  final String serviceId;
  final String? sourceFile;
  final String? activeFile;
  const SecretsEditorDialog({
    super.key,
    required this.serviceId,
    this.sourceFile,
    this.activeFile,
  });

  @override
  ConsumerState<SecretsEditorDialog> createState() => _SecretsEditorDialogState();
}

class _SecretsEditorDialogState extends ConsumerState<SecretsEditorDialog> {
  // Phase 1 state
  SecretsKeysDto? _keys;
  String? _keysError;
  bool _loadingKeys = true;

  // Phase 2 state
  String? _password; // in-memory for this dialog instance only
  EnvComparisonDto? _values;
  String? _unlockError;
  bool _unlocking = false;
  bool _saving = false;
  bool _dirty = false;

  final Map<String, TextEditingController> _controllers = {};
  final List<String> _order = [];
  final Set<String> _revealed = {};

  // Sync the two panels' scroll positions. See env_editor.dart for the
  // pattern — clamped jumpTo + a guard to break listener loops. Once the
  // shorter side hits its bottom, the longer one keeps scrolling alone.
  final ScrollController _scrollSource = ScrollController();
  final ScrollController _scrollActive = ScrollController();
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _scrollSource.addListener(() => _mirror(_scrollSource, _scrollActive));
    _scrollActive.addListener(() => _mirror(_scrollActive, _scrollSource));
    _loadKeys();
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
    // Best-effort: drop the password from this widget's memory.
    _password = null;
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Phase 1: keys-only
  // ---------------------------------------------------------------------------

  Future<void> _loadKeys() async {
    try {
      final dto = await ref.read(apiClientProvider).getSecretsKeys(widget.serviceId);
      if (!mounted) return;
      setState(() {
        _keys = dto;
        _loadingKeys = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _keysError = e.toString();
        _loadingKeys = false;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Phase 2: unlock + edit
  // ---------------------------------------------------------------------------

  Future<void> _unlock(String password) async {
    setState(() {
      _unlocking = true;
      _unlockError = null;
    });
    try {
      final cmp = await ref.read(apiClientProvider).getSecretsValues(widget.serviceId, password);
      if (!mounted) return;
      setState(() {
        _password = password;
        _values = cmp;
        _initEditorFromComparison(cmp);
        _unlocking = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _unlockError = e.toString();
        _unlocking = false;
      });
    }
  }

  void _initEditorFromComparison(EnvComparisonDto cmp) {
    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();
    _order.clear();
    for (final entry in cmp.activeContent.entries) {
      _controllers[entry.key] = TextEditingController(text: entry.value);
      _order.add(entry.key);
    }
    _dirty = false;
    _revealed.clear();
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  void _copyFromSource(String key) {
    final values = _values;
    if (values == null) return;
    final v = values.sourceContent[key] ?? '';
    setState(() {
      if (_controllers.containsKey(key)) {
        _controllers[key]!.text = v;
      } else {
        _controllers[key] = TextEditingController(text: v);
        _order.add(key);
      }
      _dirty = true;
    });
  }

  void _copyAllMissing() {
    final cmp = _values;
    if (cmp == null) return;
    for (final k in cmp.missingInActive) {
      _copyFromSource(k);
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
      builder: (_) => const _NewKeyPrompt(),
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
    final pw = _password;
    if (pw == null) return;
    setState(() => _saving = true);
    final content = <String, String>{
      for (final k in _order)
        if (_controllers[k] != null) k: _controllers[k]!.text,
    };
    try {
      await ref.read(apiClientProvider).setSecrets(widget.serviceId, pw, content);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Secrets saved (encrypted)')),
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

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

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
        const Icon(Icons.lock_outline, size: 20),
        const SizedBox(width: 8),
        Text('Secrets', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(width: 12),
        _secretStoreChip(),
        const Spacer(),
        IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
      ],
    );
  }

  Widget _secretStoreChip() {
    final s = ref.watch(secretStoreProvider);
    final (label, color) = switch (s) {
      SecretStoreStatus.verified => ('store verified', Color(0xFF22C55E)),
      SecretStoreStatus.newStamp => ('new store', Color(0xFF22D3EE)),
      SecretStoreStatus.mismatch =>
        ('store mismatch — restart server', Color(0xFFF43F5E)),
      SecretStoreStatus.missingPassword =>
        ('store locked at startup', Colors.grey),
      SecretStoreStatus.unknown => ('store …', Colors.grey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.16),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, color: color)),
    );
  }

  Widget _body() {
    if (_loadingKeys) return const Center(child: CircularProgressIndicator());
    if (_keysError != null) return Center(child: Text('Error: $_keysError'));
    final keys = _keys!;
    if (_password == null) return _previewBody(keys);
    return _editorBody(keys);
  }

  /// Keys-only view + inline password gate.
  Widget _previewBody(SecretsKeysDto keys) {
    final sourceEntries = keys.sourceContent.entries.toList();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: EnvEditorPanel(
            title: 'Source · ${sourceEntries.length} key${sourceEntries.length == 1 ? '' : 's'}',
            filePath: widget.sourceFile,
            missing: keys.sourceExists ? null : 'source file not found',
            child: ListView.builder(
              controller: _scrollSource,
              padding: const EdgeInsets.all(8),
              itemCount: sourceEntries.length,
              itemBuilder: (_, i) => _RowCard(
                child: _ReadOnlyKvRow(
                  keyName: sourceEntries[i].key,
                  value: sourceEntries[i].value,
                  masked: false,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: EnvEditorPanel(
            title: 'Active · ${keys.activeKeys.length} key${keys.activeKeys.length == 1 ? '' : 's'}',
            filePath: widget.activeFile,
            missing: keys.activeExists
                ? (keys.readError ?? 'values hidden — unlock to view')
                : 'no encrypted file yet (will be created on first save)',
            child: Column(
              children: [
                Expanded(
                  child: ListView.builder(
                    controller: _scrollActive,
                    padding: const EdgeInsets.all(8),
                    itemCount: keys.activeKeys.length,
                    itemBuilder: (_, i) => _RowCard(
                      child: _ReadOnlyKvRow(
                        keyName: keys.activeKeys[i],
                        value: '••••••••',
                        masked: true,
                      ),
                    ),
                  ),
                ),
                const Divider(height: 1),
                _UnlockGate(
                  busy: _unlocking,
                  error: _unlockError,
                  onSubmit: _unlock,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Post-unlock editor view.
  Widget _editorBody(SecretsKeysDto keys) {
    final cmp = _values!;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _sourceEditorPanel(cmp)),
        const SizedBox(width: 12),
        Expanded(child: _activeEditorPanel(cmp)),
      ],
    );
  }

  Widget _sourceEditorPanel(EnvComparisonDto cmp) {
    final entries = cmp.sourceContent.entries.toList();
    return EnvEditorPanel(
      title: 'Source · ${entries.length} key${entries.length == 1 ? '' : 's'}',
      filePath: widget.sourceFile,
      missing: cmp.sourceExists ? null : 'source file not found',
      child: ListView.builder(
        controller: _scrollSource,
        padding: const EdgeInsets.all(8),
        itemCount: entries.length,
        itemBuilder: (_, i) {
          final e = entries[i];
          final isMissingInActive = !_controllers.containsKey(e.key);
          return _RowCard(
            child: _SourceActionRow(
              keyName: e.key,
              value: e.value,
              missingInActive: isMissingInActive,
              onCopy: isMissingInActive ? () => _copyFromSource(e.key) : null,
              onOverwrite:
                  !isMissingInActive ? () => _copyFromSource(e.key) : null,
            ),
          );
        },
      ),
    );
  }

  Widget _activeEditorPanel(EnvComparisonDto cmp) {
    final extra = _order.where((k) => !cmp.sourceContent.containsKey(k)).length;
    return EnvEditorPanel(
      title: 'Active · ${_order.length} key${_order.length == 1 ? '' : 's'}'
          '${extra > 0 ? ' · $extra extra' : ''}',
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
                final isExtra = !cmp.sourceContent.containsKey(key);
                final revealed = _revealed.contains(key);
                return _RowCard(
                  child: _SecretEditRow(
                    keyName: key,
                    controller: _controllers[key]!,
                    revealed: revealed,
                    extra: isExtra,
                    onToggleReveal: () => setState(() {
                      revealed ? _revealed.remove(key) : _revealed.add(key);
                    }),
                    onChanged: _markDirty,
                    onRemove: () => _removeKey(key),
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
    final cmp = _values;
    final missingCount = cmp == null ? 0 : cmp.missingInActive.length;
    final inEditor = _password != null;
    return Row(
      children: [
        if (inEditor && missingCount > 0)
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
        if (inEditor) ...[
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: (_dirty && !_saving) ? _save : null,
            icon: _saving
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save, size: 16),
            label: const Text('Save (encrypts)'),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Row & gate widgets
// ---------------------------------------------------------------------------

class _ReadOnlyKvRow extends StatelessWidget {
  final String keyName;
  final String value;
  final bool masked;
  const _ReadOnlyKvRow({required this.keyName, required this.value, required this.masked});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
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
              const SizedBox(width: 28),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 20, right: 4, bottom: 4),
            child: SelectableText(
              value,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.4,
                color: masked ? Colors.white60 : const Color(0xFF94A3B8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SourceActionRow extends StatelessWidget {
  final String keyName;
  final String value;
  final bool missingInActive;
  final VoidCallback? onCopy;
  final VoidCallback? onOverwrite;

  const _SourceActionRow({
    required this.keyName,
    required this.value,
    required this.missingInActive,
    this.onCopy,
    this.onOverwrite,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
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
                    color: missingInActive
                        ? Colors.orange
                        : const Color(0xFFE5E7EB),
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
          Padding(
            padding: const EdgeInsets.only(left: 20, right: 4, bottom: 4),
            child: SelectableText(
              value,
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

class _SecretEditRow extends StatelessWidget {
  final String keyName;
  final TextEditingController controller;
  final bool revealed;
  final bool extra;
  final VoidCallback onToggleReveal;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  const _SecretEditRow({
    required this.keyName,
    required this.controller,
    required this.revealed,
    required this.extra,
    required this.onToggleReveal,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final obscured = !revealed;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (extra)
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

class _UnlockGate extends StatefulWidget {
  final bool busy;
  final String? error;
  final void Function(String) onSubmit;
  const _UnlockGate({required this.busy, required this.error, required this.onSubmit});

  @override
  State<_UnlockGate> createState() => _UnlockGateState();
}

class _UnlockGateState extends State<_UnlockGate> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _controller.text;
    if (v.isEmpty) return;
    widget.onSubmit(v);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  obscureText: true,
                  autofocus: true,
                  enabled: !widget.busy,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'Secret-store password',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  ),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  onSubmitted: (_) => _submit(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: widget.busy ? null : _submit,
                icon: widget.busy
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.lock_open, size: 16),
                label: const Text('Unlock'),
              ),
            ],
          ),
          if (widget.error != null) ...[
            const SizedBox(height: 6),
            Text(
              widget.error!,
              style: const TextStyle(fontSize: 11, color: Color(0xFFF43F5E)),
            ),
          ],
        ],
      ),
    );
  }
}

class _NewKeyPrompt extends StatefulWidget {
  const _NewKeyPrompt();

  @override
  State<_NewKeyPrompt> createState() => _NewKeyPromptState();
}

class _NewKeyPromptState extends State<_NewKeyPrompt> {
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
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('Add'),
        ),
      ],
    );
  }
}

/// Visual wrapper around every row in either panel — mirrors env_editor.dart.
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
