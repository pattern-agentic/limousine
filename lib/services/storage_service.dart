import 'dart:convert';
import 'dart:io';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import '../models/workspace.dart';
import '../models/module.dart';

final _log = Logger('StorageService');

class StorageService {
  static String get globalConfigPath =>
      p.join(Platform.environment['HOME']!, '.limousine.json');

  static String pidsDir(String workspacePath) =>
      p.join(p.dirname(workspacePath), '.limousine', 'pids');

  static Future<GlobalConfig> loadGlobalConfig() async {
    try {
      final file = File(globalConfigPath);
      if (!await file.exists()) {
        return GlobalConfig();
      }
      final content = await file.readAsString();
      return GlobalConfig.fromJson(jsonDecode(content));
    } catch (e, st) {
      _log.severe('Failed to load global config', e, st);
      rethrow;
    }
  }

  static Future<void> saveGlobalConfig(GlobalConfig config) async {
    try {
      final file = File(globalConfigPath);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(config.toJson()),
      );
    } catch (e, st) {
      _log.severe('Failed to save global config', e, st);
      rethrow;
    }
  }

  static Future<Workspace> loadWorkspace(String path) async {
    try {
      final file = File(path);
      final content = await file.readAsString();
      _log.info('Loading workspace from $path');
      return Workspace.fromJson(jsonDecode(content));
    } catch (e, st) {
      _log.severe('Failed to load workspace from $path', e, st);
      rethrow;
    }
  }

  static Future<void> saveWorkspace(String path, Workspace workspace) async {
    try {
      final file = File(path);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(workspace.toJson()),
      );
    } catch (e, st) {
      _log.severe('Failed to save workspace to $path', e, st);
      rethrow;
    }
  }

  static Future<Project?> loadProject(String projectPath) async {
    final projFile = File(p.join(projectPath, 'limousine.proj'));
    if (!await projFile.exists()) return null;
    try {
      final content = await projFile.readAsString();
      _log.info('Loading project from ${projFile.path}');
      return Project.fromJson(jsonDecode(content));
    } catch (e, st) {
      _log.severe('Failed to load project from ${projFile.path}', e, st);
      rethrow;
    }
  }

  static Future<void> saveProject(String projectPath, Project project) async {
    final projFile = File(p.join(projectPath, 'limousine.proj'));
    try {
      await projFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(project.toJson()),
      );
    } catch (e, st) {
      _log.severe('Failed to save project to ${projFile.path}', e, st);
      rethrow;
    }
  }

  static Future<bool> projectExistsOnDisk(
    String workspacePath,
    String pathOnDisk,
  ) async {
    final resolvedPath = resolvePath(workspacePath, pathOnDisk);
    return Directory(resolvedPath).exists();
  }

  static String resolvePath(String workspacePath, String pathOnDisk) {
    if (p.isAbsolute(pathOnDisk)) return pathOnDisk;
    return p.normalize(p.join(p.dirname(workspacePath), pathOnDisk));
  }

  static String _sanitizeServiceId(String serviceId) =>
      serviceId.replaceAll('/', '_');

  static String _unsanitizeServiceId(String filename) =>
      filename.replaceAll('_', '/');

  static Future<void> writePidFile(
    String workspacePath,
    String serviceId,
    int pid,
  ) async {
    final dir = Directory(pidsDir(workspacePath));
    if (!await dir.exists()) await dir.create(recursive: true);
    final safeId = _sanitizeServiceId(serviceId);
    final file = File(p.join(dir.path, '$safeId.pid'));
    await file.writeAsString(pid.toString());
  }

  static Future<void> deletePidFile(
    String workspacePath,
    String serviceId,
  ) async {
    final safeId = _sanitizeServiceId(serviceId);
    final file = File(p.join(pidsDir(workspacePath), '$safeId.pid'));
    if (await file.exists()) await file.delete();
  }

  static Future<Map<String, int>> loadAllPidFiles(String workspacePath) async {
    final dir = Directory(pidsDir(workspacePath));
    if (!await dir.exists()) return {};
    final result = <String, int>{};
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.pid')) {
        final filename = p.basenameWithoutExtension(entity.path);
        final serviceId = _unsanitizeServiceId(filename);
        final content = await entity.readAsString();
        final pid = int.tryParse(content.trim());
        if (pid != null) result[serviceId] = pid;
      }
    }
    return result;
  }
}
