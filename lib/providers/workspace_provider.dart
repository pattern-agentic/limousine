import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/workspace.dart';
import '../models/module.dart';
import '../services/storage_service.dart';

final currentWorkspacePathProvider = StateProvider<String?>((ref) => null);

final workspaceProvider = FutureProvider<Workspace?>((ref) async {
  final path = ref.watch(currentWorkspacePathProvider);
  if (path == null) return null;
  return StorageService.loadWorkspace(path);
});

final projectsProvider =
    AsyncNotifierProvider<ProjectsNotifier, Map<String, LoadedProject>>(
      ProjectsNotifier.new,
    );

class LoadedProject {
  final String name;
  final String resolvedPath;
  final String? gitRepoUrl;
  final bool existsOnDisk;
  final Project? projectData;

  LoadedProject({
    required this.name,
    required this.resolvedPath,
    this.gitRepoUrl,
    required this.existsOnDisk,
    this.projectData,
  });
}

class ProjectsNotifier extends AsyncNotifier<Map<String, LoadedProject>> {
  @override
  Future<Map<String, LoadedProject>> build() async {
    final workspacePath = ref.watch(currentWorkspacePathProvider);
    final workspace = await ref.watch(workspaceProvider.future);
    if (workspacePath == null || workspace == null) return {};

    final result = <String, LoadedProject>{};
    for (final entry in workspace.projects.entries) {
      final resolvedPath = StorageService.resolvePath(
        workspacePath,
        entry.value.pathOnDisk,
      );
      final exists = await StorageService.projectExistsOnDisk(
        workspacePath,
        entry.value.pathOnDisk,
      );
      Project? projectData;
      if (exists) {
        projectData = await StorageService.loadProject(resolvedPath);
      }
      result[entry.key] = LoadedProject(
        name: entry.key,
        resolvedPath: resolvedPath,
        gitRepoUrl: entry.value.gitRepoUrl,
        existsOnDisk: exists,
        projectData: projectData,
      );
    }
    return result;
  }

  Future<void> refresh() async {
    ref.invalidateSelf();
  }

  Future<void> updateProjectVisibleTabs(
    String projectName,
    List<String> tabs,
  ) async {
    final projects = await future;
    final project = projects[projectName];
    if (project?.projectData == null) return;

    final updated = Project(
      modules: project!.projectData!.modules,
      visibleTabs: tabs,
    );
    await StorageService.saveProject(project.resolvedPath, updated);
    ref.invalidateSelf();
  }
}

final collapsedModulesProvider =
    NotifierProvider<CollapsedModulesNotifier, Set<String>>(
      CollapsedModulesNotifier.new,
    );

class CollapsedModulesNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    final workspace = ref.watch(workspaceProvider);
    return workspace.when(
      data: (ws) => ws?.collapsedModules.toSet() ?? {},
      loading: () => {},
      error: (_, __) => {},
    );
  }

  void toggle(String moduleName) {
    if (state.contains(moduleName)) {
      state = Set.from(state)..remove(moduleName);
    } else {
      state = Set.from(state)..add(moduleName);
    }
    _persist();
  }

  Future<void> _persist() async {
    final path = ref.read(currentWorkspacePathProvider);
    final workspace = await ref.read(workspaceProvider.future);
    if (path == null || workspace == null) return;

    final updated = workspace.copyWith(collapsedModules: state.toList());
    await StorageService.saveWorkspace(path, updated);
  }
}

final allServicesProvider = Provider<List<ServiceInfo>>((ref) {
  final projects = ref.watch(projectsProvider);
  return projects.when(
    data: (data) {
      final services = <ServiceInfo>[];
      for (final project in data.values) {
        if (project.projectData == null) continue;
        for (final module in project.projectData!.modules) {
          for (final service in module.services.entries) {
            services.add(
              ServiceInfo(
                projectName: project.name,
                projectPath: project.resolvedPath,
                moduleName: module.name,
                moduleConfig: module.config,
                serviceName: service.key,
                service: service.value,
              ),
            );
          }
        }
      }
      return services;
    },
    loading: () => [],
    error: (_, __) => [],
  );
});

class ServiceInfo {
  final String projectName;
  final String projectPath;
  final String moduleName;
  final ModuleConfig moduleConfig;
  final String serviceName;
  final Service service;

  ServiceInfo({
    required this.projectName,
    required this.projectPath,
    required this.moduleName,
    required this.moduleConfig,
    required this.serviceName,
    required this.service,
  });

  String get id => '$moduleName/$serviceName';
  String get displayName => '$moduleName - $serviceName';
}
