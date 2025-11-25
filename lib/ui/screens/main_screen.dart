import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/service_state.dart';
import '../../providers/workspace_provider.dart';
import '../../providers/services_provider.dart';
import '../widgets/dashboard/dashboard_tab.dart';
import '../widgets/service_tab/service_tab.dart';
import '../widgets/dialogs/settings_dialog.dart';

class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen> {
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(serviceStatesProvider.notifier).loadOrphanedProcesses();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final services = ref.watch(allServicesProvider);
    final serviceStates = ref.watch(serviceStatesProvider);
    final collapsedModules = ref.watch(collapsedModulesProvider);

    final servicesByModule = <String, List<ServiceInfo>>{};
    for (final s in services) {
      servicesByModule.putIfAbsent(s.moduleName, () => []).add(s);
    }

    final runningCount = services.where((s) {
      final state = serviceStates[s.id];
      return state?.status == ProcessStatus.running;
    }).length;

    return Scaffold(
      appBar: _buildAppBar(context),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Row(
          children: [
            _buildSidebar(servicesByModule, serviceStates, collapsedModules, runningCount),
            const SizedBox(width: 16),
            Expanded(child: _buildContent(services)),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return PreferredSize(
      preferredSize: const Size.fromHeight(56),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF020617),
          border: Border(
            bottom: BorderSide(
              color: Theme.of(context).dividerColor,
              width: 1,
            ),
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
                _buildTitle(ref),
                const Spacer(),
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
                  onPressed: () => _confirmCloseWorkspace(context, ref),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSidebar(
    Map<String, List<ServiceInfo>> servicesByModule,
    Map<String, ServiceState> serviceStates,
    Set<String> collapsedModules,
    int runningCount,
  ) {
    return Container(
      width: 280,
      decoration: BoxDecoration(
        color: const Color(0xFF0B1120),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).dividerColor,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.35),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            child: Row(
              children: [
                const Text(
                  'Services',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Text(
                  '$runningCount running',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withOpacity(0.6),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                _buildDashboardItem(),
                ...servicesByModule.entries.map((entry) {
                  return _buildGroup(
                    entry.key,
                    entry.value,
                    serviceStates,
                    collapsedModules,
                  );
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDashboardItem() {
    final selected = _selectedId == null;
    return Padding(
      padding: const EdgeInsets.only(left: 16.0, right: 8.0, bottom: 4.0),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => setState(() => _selectedId = null),
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

  Widget _buildGroup(
    String moduleName,
    List<ServiceInfo> services,
    Map<String, ServiceState> serviceStates,
    Set<String> collapsedModules,
  ) {
    final isExpanded = !collapsedModules.contains(moduleName);
    return Column(
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            ref.read(collapsedModulesProvider.notifier).toggle(moduleName);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
            child: Row(
              children: [
                Icon(
                  isExpanded
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_right,
                  size: 18,
                  color: Colors.white.withOpacity(0.7),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    moduleName,
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
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withOpacity(0.7),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (isExpanded)
          Padding(
            padding: const EdgeInsets.only(top: 2.0),
            child: Column(
              children: services.map((s) {
                final state = serviceStates[s.id];
                final isRunning = state?.status == ProcessStatus.running;
                final selected = _selectedId == s.id;
                return _buildServiceRow(s, selected, isRunning);
              }).toList(),
            ),
          ),
      ],
    );
  }

  Widget _buildServiceRow(ServiceInfo service, bool selected, bool isRunning) {
    return Padding(
      padding: const EdgeInsets.only(left: 16.0, right: 8.0, bottom: 4.0),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => setState(() => _selectedId = service.id),
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
              if (isRunning)
                const Text('▶ ', style: TextStyle(fontSize: 10, color: Color(0xFF22C55E)))
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

  Widget _buildContent(List<ServiceInfo> services) {
    if (_selectedId == null) {
      return const DashboardTab();
    }
    final service = services.where((s) => s.id == _selectedId).firstOrNull;
    if (service == null) {
      return const DashboardTab();
    }
    return ServiceTab(key: ValueKey(_selectedId), serviceInfo: service);
  }

  Widget _buildTitle(WidgetRef ref) {
    final workspace = ref.watch(workspaceProvider);
    return workspace.when(
      data: (ws) => Text(
        ws?.name ?? 'Limousine',
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      loading: () => const Text('Loading...'),
      error: (_, __) => const Text('Limousine'),
    );
  }

  void _confirmCloseWorkspace(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Close Workspace'),
        content: const Text('Are you sure you want to close this workspace?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(currentWorkspacePathProvider.notifier).state = null;
            },
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
