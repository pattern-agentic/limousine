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
  /// Where relative `path-on-disk` entries in the .wksp resolve against.
  /// Defaults to the workspace file's parent dir; overridden by the server's
  /// `--clone-root` CLI flag. Absolute paths in the .wksp ignore this.
  final String? overrideCloneRoot;

  String? _workspacePath;
  Workspace? _workspace;
  Map<String, LoadedProjectDto> _projects = {};
  final StreamController<void> _changes = StreamController<void>.broadcast();

  WorkspaceManager({this.overrideCloneRoot});

  String? get workspacePath => _workspacePath;
  Workspace? get workspace => _workspace;
  Map<String, LoadedProjectDto> get projects => Map.unmodifiable(_projects);

  /// Effective root for resolving relative project paths.
  String? get cloneRoot {
    if (overrideCloneRoot != null) return overrideCloneRoot;
    final wp = _workspacePath;
    return wp == null ? null : p.dirname(wp);
  }

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
    final root = cloneRoot;
    if (workspacePath == null || workspace == null || root == null) {
      _projects = {};
      return;
    }
    final result = <String, LoadedProjectDto>{};
    for (final entry in workspace.projects.entries) {
      result[entry.key] = await _loadOneProject(entry.key, entry.value, root);
    }
    _projects = result;
    _log.info('Loaded ${_projects.length} project(s)');
  }

  Future<LoadedProjectDto> _loadOneProject(
    String name,
    ProjectRef ref,
    String root,
  ) async {
    final resolvedPath = Storage.resolvePath(root, ref.pathOnDisk);
    final exists = await Storage.projectExistsOnDisk(root, ref.pathOnDisk);
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
    return LoadedProjectDto(
      name: name,
      resolvedPath: resolvedPath,
      gitRepoUrl: ref.gitRepoUrl,
      existsOnDisk: exists,
      projectData: projectData,
      loadError: loadError,
    );
  }

  /// Reload one project's `limousine.proj` without touching the rest of the
  /// workspace. Caller is responsible for checking that no services in the
  /// project are running.
  Future<void> reloadProject(String name) async {
    final workspace = _workspace;
    final root = cloneRoot;
    if (workspace == null || root == null) return;
    final ref = workspace.projects[name];
    if (ref == null) return;
    _projects = {
      ..._projects,
      name: await _loadOneProject(name, ref, root),
    };
    _changes.add(null);
    _log.info('Reloaded project: $name');
  }

  /// Re-read the `.wksp` from disk and compute the diff against the current
  /// in-memory state. Doesn't apply anything — caller decides whether the
  /// diff is safe given current service state, then calls [applyDiff].
  Future<WorkspaceDiff> peekDiff() async {
    final path = _workspacePath;
    final current = _workspace;
    if (path == null || current == null) {
      throw StateError('No workspace open');
    }
    final next = await Storage.loadWorkspace(path);
    final added = <String>[];
    final removed = <String>[];
    final changed = <String>[];
    for (final entry in next.projects.entries) {
      final old = current.projects[entry.key];
      if (old == null) {
        added.add(entry.key);
      } else if (old.pathOnDisk != entry.value.pathOnDisk ||
          old.gitRepoUrl != entry.value.gitRepoUrl) {
        changed.add(entry.key);
      }
    }
    for (final oldKey in current.projects.keys) {
      if (!next.projects.containsKey(oldKey)) removed.add(oldKey);
    }
    return WorkspaceDiff(
      added: added,
      removed: removed,
      changed: changed,
      newWorkspace: next,
    );
  }

  /// Apply a previously-peeked diff. Removed projects are unloaded; added and
  /// changed projects are (re)loaded against the new ProjectRef.
  Future<void> applyDiff(WorkspaceDiff diff) async {
    final root = cloneRoot;
    if (root == null) return;
    _workspace = diff.newWorkspace;
    final next = {..._projects};
    for (final name in diff.removed) {
      next.remove(name);
    }
    for (final name in [...diff.added, ...diff.changed]) {
      final ref = _workspace!.projects[name];
      if (ref != null) next[name] = await _loadOneProject(name, ref, root);
    }
    _projects = next;
    _changes.add(null);
    _log.info(
      'Workspace reload applied: +${diff.added.length} -${diff.removed.length} ~${diff.changed.length}',
    );
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

class WorkspaceDiff {
  final List<String> added;
  final List<String> removed;
  final List<String> changed;
  final Workspace newWorkspace;

  WorkspaceDiff({
    required this.added,
    required this.removed,
    required this.changed,
    required this.newWorkspace,
  });

  bool get hasChanges =>
      added.isNotEmpty || removed.isNotEmpty || changed.isNotEmpty;
}
