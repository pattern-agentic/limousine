import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../../core/module.dart';
import '../../core/workspace.dart';
import '../api_client.dart';
import 'api_provider.dart';

final workspaceStateProvider =
    AsyncNotifierProvider<WorkspaceStateNotifier, WorkspaceState>(
      WorkspaceStateNotifier.new,
    );

class WorkspaceStateNotifier extends AsyncNotifier<WorkspaceState> {
  WebSocketChannel? _socket;

  @override
  Future<WorkspaceState> build() async {
    final api = ref.watch(apiClientProvider);
    ref.onDispose(() {
      _socket?.sink.close();
      _socket = null;
    });
    _socket = api.openStateSocket();
    _socket!.stream.listen((data) {
      final msg = jsonDecode(data as String) as Map<String, dynamic>;
      if (msg['type'] == 'workspace-changed') refresh();
    });
    return api.getWorkspace();
  }

  Future<void> refresh() async {
    final api = ref.read(apiClientProvider);
    state = AsyncData(await api.getWorkspace());
  }

  Future<void> open(String path) async {
    await ref.read(apiClientProvider).openWorkspace(path);
    await refresh();
  }

  Future<void> close() async {
    await ref.read(apiClientProvider).closeWorkspace();
    await refresh();
  }

  Future<void> saveWorkspace(Workspace ws) async {
    await ref.read(apiClientProvider).saveWorkspace(ws);
    await refresh();
  }

}

/// In-memory only. When true, the sidebar hides module groups that have no
/// running or orphaned services. Deliberately not persisted to the .wksp
/// file — workspace files live in git, and per-dev UI state would cause
/// noisy diffs.
final hideInactiveProvider = StateProvider<bool>((_) => false);

/// In-memory, per-session set of collapsed module names. Resets on page
/// reload. Also deliberately not persisted to the .wksp file (was, until we
/// noticed the git churn).
final collapsedModulesProvider =
    NotifierProvider<CollapsedModulesNotifier, Set<String>>(
  CollapsedModulesNotifier.new,
);

class CollapsedModulesNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void toggle(String name) {
    final next = Set<String>.from(state);
    if (!next.add(name)) next.remove(name);
    state = next;
  }
}

/// Same per-session model as collapsedModules, but for project groups in the
/// sidebar. Resets on reload, not persisted to the .wksp.
final collapsedProjectsProvider =
    NotifierProvider<CollapsedProjectsNotifier, Set<String>>(
  CollapsedProjectsNotifier.new,
);

class CollapsedProjectsNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void toggle(String name) {
    final next = Set<String>.from(state);
    if (!next.add(name)) next.remove(name);
    state = next;
  }
}

final globalConfigProvider = FutureProvider<GlobalConfig>((ref) async {
  return ref.watch(apiClientProvider).getGlobalConfig();
});

class ClientServiceInfo {
  final String id;
  final String projectName;
  final String projectPath;
  final String moduleName;
  final ModuleConfig moduleConfig;
  final String serviceName;
  final Service service;

  ClientServiceInfo({
    required this.id,
    required this.projectName,
    required this.projectPath,
    required this.moduleName,
    required this.moduleConfig,
    required this.serviceName,
    required this.service,
  });

  String get displayName => '$moduleName - $serviceName';
}

final allServicesProvider = Provider<List<ClientServiceInfo>>((ref) {
  final ws = ref.watch(workspaceStateProvider).valueOrNull;
  if (ws == null || !ws.open) return [];
  final result = <ClientServiceInfo>[];
  for (final project in ws.projects.values) {
    if (project.projectData == null) continue;
    for (final module in project.projectData!.modules) {
      for (final entry in module.services.entries) {
        result.add(ClientServiceInfo(
          id: '${module.name}/${entry.key}',
          projectName: project.name,
          projectPath: project.resolvedPath,
          moduleName: module.name,
          moduleConfig: module.config,
          serviceName: entry.key,
          service: entry.value,
        ));
      }
    }
  }
  return result;
});
