import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/dto.dart';
import '../../api_client.dart';
import '../../providers/api_provider.dart';
import '../../providers/services_provider.dart';
import '../../providers/workspace_provider.dart';
import '../widgets/dashboard/dashboard_tab.dart';
import '../widgets/dialogs/settings_dialog.dart';
import '../widgets/mcp_status_indicator.dart';
import '../widgets/secret_store_status_indicator.dart';
import '../widgets/service_tab/service_tab.dart';

class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen> {
  String? _selectedId;

  @override
  Widget build(BuildContext context) {
    final services = ref.watch(allServicesProvider);
    final serviceStates = ref.watch(serviceStatesProvider);
    final hideInactive = ref.watch(hideInactiveProvider);
    final collapsed = ref.watch(collapsedModulesProvider);

    final byModule = <String, List<ClientServiceInfo>>{};
    for (final s in services) {
      byModule.putIfAbsent(s.moduleName, () => []).add(s);
    }
    final runningCount = services.where((s) =>
        serviceStates[s.id]?.status == ProcessStatus.running).length;

    // A module is "active" if any of its services is currently running or
    // orphaned. Stopped-only modules get filtered out when hideInactive is on.
    final activeByModule = {
      for (final entry in byModule.entries)
        entry.key: entry.value.any((s) {
          final st = serviceStates[s.id]?.status;
          return st == ProcessStatus.running || st == ProcessStatus.orphaned;
        }),
    };
    final visibleByModule = hideInactive
        ? Map.fromEntries(byModule.entries.where((e) => activeByModule[e.key]!))
        : byModule;
    final hiddenCount = byModule.length - visibleByModule.length;

    return Scaffold(
      appBar: _buildAppBar(),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Row(
          children: [
            _Sidebar(
              byModule: visibleByModule,
              states: serviceStates,
              runningCount: runningCount,
              hideInactive: hideInactive,
              hiddenCount: hiddenCount,
              onToggleHideInactive: () =>
                  ref.read(hideInactiveProvider.notifier).state = !hideInactive,
              collapsed: collapsed,
              onToggleCollapsed: (name) =>
                  ref.read(collapsedModulesProvider.notifier).toggle(name),
              selectedId: _selectedId,
              onSelect: (id) => setState(() => _selectedId = id),
            ),
            const SizedBox(width: 16),
            Expanded(child: _content(services)),
          ],
        ),
      ),
    );
  }

  Widget _content(List<ClientServiceInfo> services) {
    if (_selectedId == null) return const DashboardTab();
    final service = services.where((s) => s.id == _selectedId).firstOrNull;
    if (service == null) return const DashboardTab();
    return ServiceTab(key: ValueKey(_selectedId), service: service);
  }

  PreferredSizeWidget _buildAppBar() {
    return PreferredSize(
      preferredSize: const Size.fromHeight(56),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF020617),
          border: Border(
            bottom: BorderSide(color: Theme.of(context).dividerColor),
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0),
            child: Row(
              children: [
                Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: const Color(0xFF22D3EE),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(width: 8),
                _Title(),
                const Spacer(),
                const SecretStoreStatusIndicator(),
                const McpStatusIndicator(),
                IconButton(
                  tooltip: 'Reload workspace',
                  onPressed: _reloadWorkspace,
                  icon: const Icon(Icons.refresh),
                ),
                IconButton(
                  tooltip: 'Settings',
                  onPressed: () => showDialog(
                    context: context,
                    builder: (_) => const SettingsDialog(),
                  ),
                  icon: const Icon(Icons.settings_outlined),
                ),
                IconButton(
                  tooltip: 'Close workspace',
                  onPressed: _confirmClose,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _reloadWorkspace() async {
    try {
      final diff = await ref.read(apiClientProvider).reloadWorkspace();
      await ref.read(workspaceStateProvider.notifier).refresh();
      if (!mounted) return;
      final added = (diff['added'] as List).cast<String>();
      final removed = (diff['removed'] as List).cast<String>();
      final changed = (diff['changed'] as List).cast<String>();
      final summary = _summariseDiff(added, removed, changed);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Workspace reloaded · $summary')),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      _showWorkspaceReloadBlocked(e);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Reload failed: $e')),
      );
    }
  }

  String _summariseDiff(List<String> added, List<String> removed, List<String> changed) {
    if (added.isEmpty && removed.isEmpty && changed.isEmpty) return 'no changes';
    final parts = <String>[];
    if (added.isNotEmpty) parts.add('+${added.length}: ${added.join(", ")}');
    if (removed.isNotEmpty) parts.add('-${removed.length}: ${removed.join(", ")}');
    if (changed.isNotEmpty) parts.add('~${changed.length}: ${changed.join(", ")}');
    return parts.join(' · ');
  }

  void _showWorkspaceReloadBlocked(ApiException e) {
    String message = e.message;
    List<Map<String, dynamic>> running = const [];
    List<String> added = const [], removed = const [], changed = const [];
    try {
      final body = jsonDecode(e.message) as Map<String, dynamic>;
      message = (body['error'] as String?) ?? message;
      final list = body['runningServices'];
      if (list is List) running = list.cast<Map<String, dynamic>>();
      added = (body['added'] as List?)?.cast<String>() ?? const [];
      removed = (body['removed'] as List?)?.cast<String>() ?? const [];
      changed = (body['changed'] as List?)?.cast<String>() ?? const [];
    } catch (_) {}
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Workspace reload blocked'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message),
              if (running.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('Running services in affected projects:',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                const SizedBox(height: 4),
                ...running.map((s) => Text(
                    '  • ${s['id']}  (${s['status']})',
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12))),
              ],
              const SizedBox(height: 12),
              const Text('Pending changes on disk:',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
              const SizedBox(height: 4),
              if (added.isNotEmpty) Text('  added: ${added.join(", ")}'),
              if (removed.isNotEmpty) Text('  removed: ${removed.join(", ")}'),
              if (changed.isNotEmpty) Text('  changed: ${changed.join(", ")}'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _confirmClose() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Close Workspace'),
        content: const Text('Close the active workspace?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await ref.read(workspaceStateProvider.notifier).close();
              if (mounted) setState(() => _selectedId = null);
            },
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

class _Title extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ws = ref.watch(workspaceStateProvider).valueOrNull?.workspace;
    return Text(
      ws?.name ?? 'Limousine',
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    );
  }
}

class _Sidebar extends ConsumerWidget {
  final Map<String, List<ClientServiceInfo>> byModule;
  final Map<String, ServiceStateDto> states;
  final int runningCount;
  final bool hideInactive;
  final int hiddenCount;
  final VoidCallback onToggleHideInactive;
  final Set<String> collapsed;
  final void Function(String) onToggleCollapsed;
  final String? selectedId;
  final void Function(String?) onSelect;

  const _Sidebar({
    required this.byModule,
    required this.states,
    required this.runningCount,
    required this.hideInactive,
    required this.hiddenCount,
    required this.onToggleHideInactive,
    required this.collapsed,
    required this.onToggleCollapsed,
    required this.selectedId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      width: 280,
      decoration: BoxDecoration(
        color: const Color(0xFF0B1120),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Row(
              children: [
                const Text('Services',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                const Spacer(),
                Text(
                  '$runningCount running',
                  style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.6)),
                ),
                IconButton(
                  tooltip: hideInactive
                      ? 'Showing only active modules — click to show all'
                      : 'Hide inactive modules',
                  icon: Icon(
                    hideInactive ? Icons.filter_alt : Icons.filter_alt_outlined,
                    size: 16,
                    color: hideInactive
                        ? const Color(0xFF22D3EE)
                        : Colors.white.withOpacity(0.7),
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                  onPressed: onToggleHideInactive,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                _DashboardItem(
                  selected: selectedId == null,
                  onTap: () => onSelect(null),
                ),
                ...byModule.entries.map((entry) => _ModuleGroup(
                      name: entry.key,
                      services: entry.value,
                      states: states,
                      expanded: !collapsed.contains(entry.key),
                      onToggleCollapsed: () => onToggleCollapsed(entry.key),
                      selectedId: selectedId,
                      onSelect: onSelect,
                    )),
              ],
            ),
          ),
          if (hideInactive && hiddenCount > 0) ...[
            const Divider(height: 1),
            InkWell(
              onTap: onToggleHideInactive,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    Icon(Icons.visibility_outlined,
                        size: 14, color: Colors.white.withOpacity(0.6)),
                    const SizedBox(width: 6),
                    Text(
                      '+ $hiddenCount inactive · show all',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withOpacity(0.7),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _DashboardItem extends StatelessWidget {
  final bool selected;
  final VoidCallback onTap;
  const _DashboardItem({required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 16.0, right: 8.0, bottom: 4.0),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: selected ? const Color(0x1A22D3EE) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 32,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: selected ? const Color(0xFF22D3EE) : Colors.transparent,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const Icon(Icons.dashboard_outlined, size: 16),
              const SizedBox(width: 8),
              const Text('Dashboard', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModuleGroup extends StatelessWidget {
  final String name;
  final List<ClientServiceInfo> services;
  final Map<String, ServiceStateDto> states;
  final bool expanded;
  final VoidCallback onToggleCollapsed;
  final String? selectedId;
  final void Function(String?) onSelect;

  const _ModuleGroup({
    required this.name,
    required this.services,
    required this.states,
    required this.expanded,
    required this.onToggleCollapsed,
    required this.selectedId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onToggleCollapsed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
            child: Row(
              children: [
                Icon(
                  expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right,
                  size: 18,
                  color: Colors.white.withOpacity(0.7),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    name,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xF00F172A),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${services.length}',
                    style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.7)),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (expanded)
          ...services.map((s) {
            final running = states[s.id]?.status == ProcessStatus.running;
            final selected = selectedId == s.id;
            return _ServiceRow(
              service: s,
              selected: selected,
              running: running,
              onTap: () => onSelect(s.id),
            );
          }),
      ],
    );
  }
}

class _ServiceRow extends StatelessWidget {
  final ClientServiceInfo service;
  final bool selected;
  final bool running;
  final VoidCallback onTap;

  const _ServiceRow({
    required this.service,
    required this.selected,
    required this.running,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 16.0, right: 8.0, bottom: 4.0),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: selected ? const Color(0x1A22D3EE) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 32,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: selected ? const Color(0xFF22D3EE) : Colors.transparent,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              if (running)
                const Text('▶ ',
                    style: TextStyle(fontSize: 10, color: Color(0xFF22C55E)))
              else
                const SizedBox(width: 14),
              Expanded(
                child: Text(
                  service.serviceName,
                  style: const TextStyle(fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}
