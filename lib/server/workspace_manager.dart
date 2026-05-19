import 'dart:async';
import 'dart:io';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import '../core/dto.dart';
import '../core/module.dart';
import '../core/workspace.dart';
import 'service_manager.dart';
import 'storage.dart';

final _log = Logger('WorkspaceManager');

class WorkspaceManager {
  String? _workspacePath;
  Workspace? _workspace;
  Map<String, LoadedProjectDto> _projects = {};
  final StreamController<void> _changes = StreamController<void>.broadcast();

  String? get workspacePath => _workspacePath;
  Workspace? get workspace => _workspace;
  Map<String, LoadedProjectDto> get projects => Map.unmodifiable(_projects);

  Stream<void> get changes => _changes.stream;

  Future<void> open(String path) async {
    _workspacePath = path;
    _workspace = await Storage.loadWorkspace(path);
    await _reloadProjects();
    _changes.add(null);
  }

  Future<void> close() async {
    _workspacePath = null;
    _workspace = null;
    _projects = {};
    _changes.add(null);
  }

  Future<void> reloadProjects() async {
    if (_workspace == null) return;
    await _reloadProjects();
    _changes.add(null);
  }

  Future<void> _reloadProjects() async {
    final workspacePath = _workspacePath;
    final workspace = _workspace;
    if (workspacePath == null || workspace == null) {
      _projects = {};
      return;
    }
    final result = <String, LoadedProjectDto>{};
    for (final entry in workspace.projects.entries) {
      final resolvedPath = Storage.resolvePath(workspacePath, entry.value.pathOnDisk);
      final exists = await Storage.projectExistsOnDisk(workspacePath, entry.value.pathOnDisk);
      Project? projectData;
      String? loadError;
      if (exists) {
        try {
          projectData = await Storage.loadProject(resolvedPath);
        } on FormatException catch (e) {
          final snippet = Storage.jsonErrorSnippet(
            await File(p.join(resolvedPath, 'limousine.proj')).readAsString(),
            e.offset,
          );
          loadError = 'Invalid JSON in limousine.proj:\n$snippet';
        } catch (e) {
          loadError = 'Failed to load project: $e';
        }
      }
      result[entry.key] = LoadedProjectDto(
        name: entry.key,
        resolvedPath: resolvedPath,
        gitRepoUrl: entry.value.gitRepoUrl,
        existsOnDisk: exists,
        projectData: projectData,
        loadError: loadError,
      );
    }
    _projects = result;
    _log.info('Loaded ${_projects.length} project(s)');
  }

  List<ServiceInfo> allServices() {
    final result = <ServiceInfo>[];
    for (final project in _projects.values) {
      if (project.projectData == null) continue;
      for (final module in project.projectData!.modules) {
        for (final entry in module.services.entries) {
          result.add(ServiceInfo(
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
  }

  ServiceInfo? findService(String serviceId) {
    return allServices().where((s) => s.id == serviceId).firstOrNull;
  }

  Future<void> saveWorkspace(Workspace updated) async {
    final path = _workspacePath;
    if (path == null) return;
    await Storage.saveWorkspace(path, updated);
    _workspace = updated;
    _changes.add(null);
  }

  Future<void> dispose() async {
    await _changes.close();
  }
}
