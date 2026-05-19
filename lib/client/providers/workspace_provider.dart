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

  Future<void> toggleCollapsed(String moduleName) async {
    final current = state.valueOrNull?.workspace;
    if (current == null) return;
    final collapsed = Set<String>.from(current.collapsedModules);
    if (!collapsed.add(moduleName)) collapsed.remove(moduleName);
    final updated = current.copyWith(collapsedModules: collapsed.toList());
    state = AsyncData(WorkspaceState(
      open: true,
      path: state.valueOrNull?.path,
      workspace: updated,
      projects: state.valueOrNull?.projects ?? {},
    ));
    await saveWorkspace(updated);
  }
}

final collapsedModulesProvider = Provider<Set<String>>((ref) {
  final ws = ref.watch(workspaceStateProvider).valueOrNull;
  return ws?.workspace?.collapsedModules.toSet() ?? {};
});

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
