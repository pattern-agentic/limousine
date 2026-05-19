import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/api_provider.dart';
import '../../providers/workspace_provider.dart';

class StartupScreen extends ConsumerStatefulWidget {
  const StartupScreen({super.key});

  @override
  ConsumerState<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends ConsumerState<StartupScreen> {
  String? _error;

  @override
  Widget build(BuildContext context) {
    final configAsync = ref.watch(globalConfigProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Limousine')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: configAsync.when(
            data: (config) => _body(config.workspacePaths),
            loading: () => const CircularProgressIndicator(),
            error: (e, _) => Text('Error: $e'),
          ),
        ),
      ),
    );
  }

  Widget _body(List<String> paths) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.directions_car, size: 64),
          const SizedBox(height: 24),
          const Text(
            'Open a Workspace',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          if (paths.isEmpty)
            const Text(
              'No workspaces yet. Enter the absolute path to a .wksp file on the server.',
              textAlign: TextAlign.center,
            )
          else
            ...paths.map((path) => _WorkspaceItem(path: path)),
          const SizedBox(height: 24),
          _OpenByPathField(onError: (msg) => setState(() => _error = msg)),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Color(0xFFF43F5E))),
          ],
        ],
      ),
    );
  }
}

class _WorkspaceItem extends ConsumerWidget {
  final String path;
  const _WorkspaceItem({required this.path});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.folder),
        title: Text(path.split('/').last, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          path,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline),
          onPressed: () async {
            await ref.read(apiClientProvider).removeGlobalWorkspace(path);
            ref.invalidate(globalConfigProvider);
          },
        ),
        onTap: () =>
            ref.read(workspaceStateProvider.notifier).open(path),
      ),
    );
  }
}

class _OpenByPathField extends ConsumerStatefulWidget {
  final void Function(String) onError;
  const _OpenByPathField({required this.onError});

  @override
  ConsumerState<_OpenByPathField> createState() => _OpenByPathFieldState();
}

class _OpenByPathFieldState extends ConsumerState<_OpenByPathField> {
  final _controller = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    final path = _controller.text.trim();
    if (path.isEmpty) return;
    setState(() => _busy = true);
    try {
      final api = ref.read(apiClientProvider);
      await api.addGlobalWorkspace(path);
      ref.invalidate(globalConfigProvider);
      await ref.read(workspaceStateProvider.notifier).open(path);
    } catch (e) {
      widget.onError(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            enabled: !_busy,
            decoration: const InputDecoration(
              hintText: '/absolute/path/to/workspace.wksp',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            onSubmitted: (_) => _open(),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: _busy ? null : _open,
          icon: const Icon(Icons.folder_open),
          label: Text(_busy ? 'Opening…' : 'Open'),
        ),
      ],
    );
  }
}
