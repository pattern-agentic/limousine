import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/dto.dart';
import '../../api_client.dart';
import '../../providers/api_provider.dart';
import '../../providers/git_status_provider.dart';
import '../../providers/services_provider.dart';
import '../../providers/workspace_provider.dart';
import '../../version.dart';
import '../widgets/dashboard/dashboard_tab.dart';
import '../widgets/dialogs/env_editor.dart';
import '../widgets/dialogs/secrets_editor.dart';
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
    final collapsedModules = ref.watch(collapsedModulesProvider);
    final collapsedProjects = ref.watch(collapsedProjectsProvider);

    // Group services first by project, then by module within each project.
    // Preserves insertion order so the sidebar follows the order the
    // workspace + project files declare them in.
    final byProject = <String, Map<String, List<ClientServiceInfo>>>{};
    for (final s in services) {
      byProject
          .putIfAbsent(s.projectName, () => <String, List<ClientServiceInfo>>{})
          .putIfAbsent(s.moduleName, () => <ClientServiceInfo>[])
          .add(s);
    }
    final runningCount = services.where((s) =>
        serviceStates[s.id]?.status == ProcessStatus.running).length;

    // A module is "active" if any of its services is running or orphaned.
    bool moduleIsActive(List<ClientServiceInfo> infos) => infos.any((s) {
          final st = serviceStates[s.id]?.status;
          return st == ProcessStatus.running || st == ProcessStatus.orphaned;
        });

    // Apply the hide-inactive filter at the module level. A project with all
    // its modules filtered out is dropped entirely.
    final visibleByProject =
        <String, Map<String, List<ClientServiceInfo>>>{};
    var totalModules = 0;
    var visibleModules = 0;
    for (final entry in byProject.entries) {
      totalModules += entry.value.length;
      final mods = hideInactive
          ? Map.fromEntries(
              entry.value.entries.where((e) => moduleIsActive(e.value)))
          : entry.value;
      visibleModules += mods.length;
      if (mods.isNotEmpty) {
        visibleByProject[entry.key] = mods;
      }
    }
    final hiddenCount = totalModules - visibleModules;

    return Scaffold(
      appBar: _buildAppBar(),
      body: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(24.0),
            child: Row(
              children: [
                _Sidebar(
                  byProject: visibleByProject,
                  runningCount: runningCount,
                  hideInactive: hideInactive,
                  hiddenCount: hiddenCount,
                  onToggleHideInactive: () =>
                      ref.read(hideInactiveProvider.notifier).state = !hideInactive,
                  collapsedModules: collapsedModules,
                  collapsedProjects: collapsedProjects,
                  onToggleModule: (name) =>
                      ref.read(collapsedModulesProvider.notifier).toggle(name),
                  onToggleProject: (name) =>
                      ref.read(collapsedProjectsProvider.notifier).toggle(name),
                  selectedId: _selectedId,
                  onSelect: (id) => setState(() => _selectedId = id),
                ),
                const SizedBox(width: 16),
                Expanded(child: _content(services)),
              ],
            ),
          ),
          const Positioned(
            right: 10,
            bottom: 6,
            child: IgnorePointer(
              child: Text(
                'v$kLimousineVersion',
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: Color(0xFF64748B),
                ),
              ),
            ),
          ),
        ],
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
  final Map<String, Map<String, List<ClientServiceInfo>>> byProject;
  final int runningCount;
  final bool hideInactive;
  final int hiddenCount;
  final VoidCallback onToggleHideInactive;
  final Set<String> collapsedModules;
  final Set<String> collapsedProjects;
  final void Function(String) onToggleModule;
  final void Function(String) onToggleProject;
  final String? selectedId;
  final void Function(String?) onSelect;

  const _Sidebar({
    required this.byProject,
    required this.runningCount,
    required this.hideInactive,
    required this.hiddenCount,
    required this.onToggleHideInactive,
    required this.collapsedModules,
    required this.collapsedProjects,
    required this.onToggleModule,
    required this.onToggleProject,
    required this.selectedId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      width: 280,
      decoration: BoxDecoration(
        // Darker than the project-card bg (0xFF111A2E) so each card pops
        // visibly against the sidebar — matches the scaffold background.
        color: const Color(0xFF020617),
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
                for (final project in byProject.entries)
                  _ProjectGroup(
                    name: project.key,
                    byModule: project.value,
                    expanded: !collapsedProjects.contains(project.key),
                    onToggleExpanded: () => onToggleProject(project.key),
                    collapsedModules: collapsedModules,
                    onToggleModule: onToggleModule,
                    selectedId: selectedId,
                    onSelect: onSelect,
                  ),
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

class _ProjectGroup extends StatelessWidget {
  final String name;
  final Map<String, List<ClientServiceInfo>> byModule;
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final Set<String> collapsedModules;
  final void Function(String) onToggleModule;
  final String? selectedId;
  final void Function(String?) onSelect;

  const _ProjectGroup({
    required this.name,
    required this.byModule,
    required this.expanded,
    required this.onToggleExpanded,
    required this.collapsedModules,
    required this.onToggleModule,
    required this.selectedId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    // Subtle card around the whole project (header + nested modules + services)
    // so the project boundary is visually distinct from the module headers
    // inside it. One tone lighter than the sidebar background, thin border.
    return Container(
      margin: const EdgeInsets.fromLTRB(6, 0, 6, 11),
      decoration: BoxDecoration(
        color: const Color(0xFF111A2E),
        border: Border.all(color: const Color(0xFF1E293B), width: 1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onToggleExpanded,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
              child: Row(
                children: [
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    size: 18,
                    color: Colors.white.withOpacity(0.85),
                  ),
                  const SizedBox(width: 2),
                  const Icon(
                    Icons.folder_outlined,
                    size: 14,
                    color: Color(0xFF94A3B8),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      name,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                        color: Color(0xFFE5E7EB),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  _ProjectKebab(projectName: name),
                ],
              ),
            ),
          ),
          if (expanded)
            for (final entry in byModule.entries)
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: _ModuleGroup(
                  name: entry.key,
                  services: entry.value,
                  expanded: !collapsedModules.contains(entry.key),
                  onToggleCollapsed: () => onToggleModule(entry.key),
                  selectedId: selectedId,
                  onSelect: onSelect,
                ),
              ),
        ],
      ),
    );
  }
}

class _ProjectKebab extends ConsumerWidget {
  final String projectName;
  const _ProjectKebab({required this.projectName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final project = ref
        .watch(workspaceStateProvider)
        .valueOrNull
        ?.projects[projectName];
    final hasAgentGuide = project?.projectData?.agentGuide != null;

    return SizedBox(
      width: 24,
      height: 24,
      child: PopupMenuButton<String>(
        tooltip: 'Project actions ($projectName)',
        icon: Icon(Icons.more_vert, size: 16, color: Colors.white.withOpacity(0.7)),
        padding: EdgeInsets.zero,
        splashRadius: 14,
        itemBuilder: (_) => [
          const PopupMenuItem(
            value: 'reload',
            child: ListTile(
              leading: Icon(Icons.refresh, size: 18),
              title: Text('Reload project file'),
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          ),
          if (hasAgentGuide)
            const PopupMenuItem(
              value: 'agent-guide',
              child: ListTile(
                leading: Icon(Icons.info_outline, size: 18),
                title: Text('Show agent guide'),
                contentPadding: EdgeInsets.zero,
                dense: true,
              ),
            ),
        ],
        onSelected: (v) {
          if (v == 'reload') _reload(context, ref);
          if (v == 'agent-guide') _showGuide(context, project!);
        },
      ),
    );
  }

  Future<void> _reload(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(apiClientProvider).reloadProject(projectName);
      await ref.read(workspaceStateProvider.notifier).refresh();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$projectName: limousine.proj reloaded')),
      );
    } on ApiException catch (e) {
      if (!context.mounted) return;
      _showReloadBlocked(context, e);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Reload failed: $e')),
      );
    }
  }

  void _showReloadBlocked(BuildContext context, ApiException e) {
    List<String> running = const [];
    String message = e.message;
    try {
      final body = jsonDecode(e.message) as Map<String, dynamic>;
      message = (body['error'] as String?) ?? message;
      final list = body['runningServices'];
      if (list is List) {
        running = list.map((s) => (s as Map)['id'].toString()).toList();
      }
    } catch (_) {}
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reload blocked'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message),
              if (running.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('Running services:',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                const SizedBox(height: 4),
                ...running.map((id) => Text('  • $id',
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12))),
              ],
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

  void _showGuide(BuildContext context, LoadedProjectDto project) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$projectName — Agent Guide'),
        content: SizedBox(
          width: 500,
          child: SelectableText(
            project.projectData!.agentGuide!,
            style: const TextStyle(fontSize: 13, height: 1.5),
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
}

class _ModuleGroup extends ConsumerWidget {
  final String name;
  final List<ClientServiceInfo> services;
  final bool expanded;
  final VoidCallback onToggleCollapsed;
  final String? selectedId;
  final void Function(String?) onSelect;

  const _ModuleGroup({
    required this.name,
    required this.services,
    required this.expanded,
    required this.onToggleCollapsed,
    required this.selectedId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectName = services.isEmpty ? null : services.first.projectName;
    final configDelta = projectName == null
        ? null
        : ref.watch(gitStatusProvider.select((b) {
            final status = b.byProject[projectName];
            if (status == null) return null;
            for (final d in status.configDeltas) {
              if (d.module == name) return d;
            }
            return null;
          }));
    return Column(
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onToggleCollapsed,
          child: Padding(
            // right=8 matches the project header + service rows, so all three
            // trailing widgets (project kebab, module kebab, row action) line
            // up vertically along the same right edge.
            padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
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
                if (configDelta != null && configDelta.hasAny)
                  _ConfigDeltaBadge(delta: configDelta, services: services),
                if (projectName != null)
                  _ModuleKebab(
                    projectName: projectName,
                    services: services,
                  ),
              ],
            ),
          ),
        ),
        if (expanded)
          ...services.map((s) {
            final selected = selectedId == s.id;
            return _ServiceRow(
              service: s,
              selected: selected,
              onTap: () => onSelect(s.id),
            );
          }),
      ],
    );
  }
}

class _ServiceRow extends ConsumerWidget {
  final ClientServiceInfo service;
  final bool selected;
  final VoidCallback onTap;

  const _ServiceRow({
    required this.service,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state =
        ref.watch(serviceStatesProvider.select((m) => m[service.id]));
    final status = state?.status ?? ProcessStatus.stopped;
    final running = status == ProcessStatus.running;

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
              _ServiceRowAction(
                service: service,
                status: status,
                state: state,
                onActed: onTap,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Inline action button at the trailing edge of each sidebar service row.
/// Click opens a popdown — the menu acts as the confirmation surface so the
/// mouse never has to leave the row to start/stop.
class _ServiceRowAction extends ConsumerWidget {
  final ClientServiceInfo service;
  final ProcessStatus status;
  final ServiceStateDto? state;
  // Called after the user picks a start/stop/kill action, so the row also
  // selects itself — switching the right pane to this service's output is
  // almost always what you want next.
  final VoidCallback onActed;

  const _ServiceRowAction({
    required this.service,
    required this.status,
    required this.state,
    required this.onActed,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(serviceStatesProvider.notifier);

    switch (status) {
      case ProcessStatus.running:
        final signal = state?.nextSignal ?? StopSignal.sigint;
        return _IconPopup<String>(
          icon: Icons.stop_circle_outlined,
          // Dull red — visible but doesn't pull the eye across the sidebar.
          color: const Color(0xFFEF4444).withOpacity(0.55),
          tooltip: 'Stop ${service.serviceName}',
          items: [
            PopupMenuItem(
              value: 'stop',
              height: 36,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.stop_circle,
                      size: 14, color: Color(0xFFEF4444)),
                  const SizedBox(width: 8),
                  Text(
                    'Stop (${signal.name.toUpperCase()})',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
          onSelected: (_) {
            onActed();
            notifier.stop(service.id);
          },
        );
      case ProcessStatus.orphaned:
        return _IconPopup<String>(
          icon: Icons.warning_amber_outlined,
          color: const Color(0xFFF97316).withOpacity(0.7),
          tooltip: 'Kill orphan ${service.serviceName}',
          items: [
            const PopupMenuItem(
              value: 'kill',
              height: 36,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.dangerous_outlined,
                      size: 14, color: Color(0xFFF97316)),
                  SizedBox(width: 8),
                  Text('Kill orphan', style: TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ],
          onSelected: (_) {
            onActed();
            notifier.killOrphan(service.id);
          },
        );
      case ProcessStatus.stopped:
        final commands = service.service.commands;
        if (commands.isEmpty) return const SizedBox(width: 24);
        return _IconPopup<String>(
          icon: Icons.play_arrow_outlined,
          // Boring grey — present, but doesn't make the sidebar feel busy.
          color: Colors.white.withOpacity(0.35),
          tooltip: 'Start ${service.serviceName}',
          items: [
            for (final name in commands.keys)
              PopupMenuItem(
                value: name,
                height: 36,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.play_arrow,
                        size: 14, color: Color(0xFF22C55E)),
                    const SizedBox(width: 8),
                    Text(name, style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
          ],
          onSelected: (cmd) {
            onActed();
            notifier.start(service.id, command: cmd);
          },
        );
    }
  }
}

class _IconPopup<T> extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final List<PopupMenuEntry<T>> items;
  final ValueChanged<T> onSelected;

  const _IconPopup({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.items,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 24,
      height: 24,
      child: PopupMenuButton<T>(
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        iconSize: 16,
        splashRadius: 14,
        icon: Icon(icon, size: 16, color: color),
        color: const Color(0xFF0B1120),
        itemBuilder: (_) => items,
        onSelected: onSelected,
      ),
    );
  }
}

class _ConfigDeltaBadge extends ConsumerWidget {
  final ConfigDeltaDto delta;
  final List<ClientServiceInfo> services;
  const _ConfigDeltaBadge({required this.delta, required this.services});

  String _detailLine(int missing, int extra, bool activeExists) => [
        if (missing > 0) '$missing missing',
        if (extra > 0) '$extra extra',
        if (!activeExists) 'no active file',
      ].join(', ');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (services.isEmpty) return const SizedBox.shrink();
    final serviceId = services.first.id;

    final envDetail = delta.hasEnvDelta
        ? _detailLine(
            delta.envMissingInActive,
            delta.envExtraInActive,
            delta.envActiveExists,
          )
        : null;
    final secretsDetail = delta.hasSecretsDelta
        ? _detailLine(
            delta.secretsMissingInActive,
            delta.secretsExtraInActive,
            delta.secretsActiveExists,
          )
        : null;

    final tooltip = [
      'Config drift between active and source files.',
      if (envDetail != null) 'env: $envDetail',
      if (secretsDetail != null) 'secrets: $secretsDetail',
      'Tap to open the relevant editor.',
    ].join('\n');

    return PopupMenuButton<String>(
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      iconSize: 14,
      icon: const Icon(
        Icons.sync_problem,
        size: 14,
        color: Color(0xFFEAB308),
      ),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'env',
          child: _MenuLine(
            title: 'Environment editor',
            subtitle: envDetail ?? 'no drift',
            dimmed: false,
          ),
        ),
        PopupMenuItem(
          value: 'secrets',
          child: _MenuLine(
            title: 'Secrets editor',
            subtitle: secretsDetail ?? 'no drift',
            dimmed: false,
          ),
        ),
      ],
      onSelected: (v) {
        if (v == 'env') {
          EnvEditorOpener.openEnv(context, ref, serviceId);
        } else if (v == 'secrets') {
          final cfg = lookupModuleConfig(ref, serviceId);
          showDialog(
            context: context,
            builder: (_) => SecretsEditorDialog(
              serviceId: serviceId,
              sourceFile: cfg?.sourceSecretsFile,
              activeFile: cfg?.activeSecretsEnvFile,
            ),
          );
        }
      },
    );
  }
}

class _MenuLine extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool dimmed;
  const _MenuLine({
    required this.title,
    required this.subtitle,
    required this.dimmed,
  });

  @override
  Widget build(BuildContext context) {
    final color =
        dimmed ? const Color(0xFF64748B) : const Color(0xFFE5E7EB);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: TextStyle(fontSize: 13, color: color)),
        Text(subtitle,
            style: const TextStyle(
                fontSize: 11, color: Color(0xFF94A3B8))),
      ],
    );
  }
}

class _ModuleKebab extends ConsumerWidget {
  final String projectName;
  final List<ClientServiceInfo> services;
  const _ModuleKebab({required this.projectName, required this.services});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Env/secrets are module-level config — any service of the module works
    // since the API resolves the module from the service id. Project-level
    // actions (reload, agent guide) live on the project header's kebab.
    final firstServiceId = services.isEmpty ? null : services.first.id;
    if (firstServiceId == null) return const SizedBox(width: 24, height: 24);

    return SizedBox(
      width: 24,
      height: 24,
      child: PopupMenuButton<String>(
        tooltip: 'Module actions',
        icon: Icon(Icons.more_vert, size: 16, color: Colors.white.withOpacity(0.7)),
        padding: EdgeInsets.zero,
        splashRadius: 14,
        itemBuilder: (_) => [
          const PopupMenuItem(
            value: 'env',
            child: ListTile(
              leading: Icon(Icons.tune, size: 18),
              title: Text('Environment variables…'),
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          ),
          const PopupMenuItem(
            value: 'secrets',
            child: ListTile(
              leading: Icon(Icons.key, size: 18),
              title: Text('Secrets…'),
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          ),
        ],
        onSelected: (v) {
          if (v == 'env') {
            EnvEditorOpener.openEnv(context, ref, firstServiceId);
          } else if (v == 'secrets') {
            final cfg = lookupModuleConfig(ref, firstServiceId);
            showDialog(
              context: context,
              builder: (_) => SecretsEditorDialog(
                serviceId: firstServiceId,
                sourceFile: cfg?.sourceSecretsFile,
                activeFile: cfg?.activeSecretsEnvFile,
              ),
            );
          }
        },
      ),
    );
  }
}

