import 'dart:convert';
import 'dart:io';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import '../core/workspace.dart';
import '../core/module.dart';

final _log = Logger('Storage');

class Storage {
  static String get globalConfigPath =>
      p.join(Platform.environment['HOME']!, '.limousine.json');

  static String pidsDir(String workspacePath) =>
      p.join(p.dirname(workspacePath), '.limousine', 'pids');

  static Future<GlobalConfig> loadGlobalConfig() async {
    final file = File(globalConfigPath);
    if (!await file.exists()) return GlobalConfig();
    return GlobalConfig.fromJson(jsonDecode(await file.readAsString()));
  }

  static Future<void> saveGlobalConfig(GlobalConfig config) async {
    await File(globalConfigPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(config.toJson()),
    );
  }

  static Future<Workspace> loadWorkspace(String path) async {
    final content = await File(path).readAsString();
    _log.info('Loading workspace from $path');
    try {
      return Workspace.fromJson(jsonDecode(content));
    } on FormatException catch (e, st) {
      _log.severe('Invalid JSON in $path:\n${jsonErrorSnippet(content, e.offset)}', e, st);
      rethrow;
    }
  }

  static Future<void> saveWorkspace(String path, Workspace workspace) async {
    await File(path).writeAsString(
      const JsonEncoder.withIndent('  ').convert(workspace.toJson()),
    );
  }

  static Future<Project?> loadProject(String projectPath) async {
    final projFile = File(p.join(projectPath, 'limousine.proj'));
    if (!await projFile.exists()) return null;
    final content = await projFile.readAsString();
    _log.info('Loading project from ${projFile.path}');
    return Project.fromJson(jsonDecode(content));
  }

  static Future<void> saveProject(String projectPath, Project project) async {
    final projFile = File(p.join(projectPath, 'limousine.proj'));
    await projFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(project.toJson()),
    );
  }

  /// "Present" = the directory exists AND contains at least one entry other
  /// than `.git`. An empty directory or one that has only a `.git/` left over
  /// from a failed clone counts as *not* present — the UI shows the clone
  /// button, `Git.clone` moves the partial directory aside before retrying.
  static Future<bool> projectExistsOnDisk(
    String rootDir,
    String pathOnDisk,
  ) async {
    final dir = Directory(resolvePath(rootDir, pathOnDisk));
    if (!await dir.exists()) return false;
    await for (final entity in dir.list(followLinks: false)) {
      if (p.basename(entity.path) != '.git') return true;
    }
    return false;
  }

  /// Resolve a workspace-relative `path-on-disk` against [rootDir]. Absolute
  /// paths in the .wksp bypass this and are returned as-is. [rootDir] is
  /// either the parent of the workspace file (default) or `--clone-root` if
  /// the server was started with one.
  static String resolvePath(String rootDir, String pathOnDisk) {
    if (p.isAbsolute(pathOnDisk)) return pathOnDisk;
    return p.normalize(p.join(rootDir, pathOnDisk));
  }

  static String _sanitize(String serviceId) => serviceId.replaceAll('/', '_');
  static String _unsanitize(String filename) => filename.replaceAll('_', '/');

  static Future<void> writePidFile(String workspacePath, String serviceId, int pid) async {
    final dir = Directory(pidsDir(workspacePath));
    if (!await dir.exists()) await dir.create(recursive: true);
    await File(p.join(dir.path, '${_sanitize(serviceId)}.pid')).writeAsString(pid.toString());
  }

  static Future<void> deletePidFile(String workspacePath, String serviceId) async {
    final file = File(p.join(pidsDir(workspacePath), '${_sanitize(serviceId)}.pid'));
    if (await file.exists()) await file.delete();
  }

  static Future<Map<String, int>> loadAllPidFiles(String workspacePath) async {
    final dir = Directory(pidsDir(workspacePath));
    if (!await dir.exists()) return {};
    final result = <String, int>{};
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.pid')) {
        final filename = p.basenameWithoutExtension(entity.path);
        final pid = int.tryParse((await entity.readAsString()).trim());
        if (pid != null) result[_unsanitize(filename)] = pid;
      }
    }
    return result;
  }

  static String jsonErrorSnippet(String content, int? offset) {
    if (offset == null) return content.length > 200 ? '${content.substring(0, 200)}...' : content;
    final lines = content.split('\n');
    var charCount = 0;
    var errorLine = 0;
    for (var i = 0; i < lines.length; i++) {
      charCount += lines[i].length + 1;
      if (charCount > offset) {
        errorLine = i;
        break;
      }
    }
    final start = (errorLine - 3).clamp(0, lines.length);
    final end = (errorLine + 4).clamp(0, lines.length);
    final numbered = <String>[];
    for (var i = start; i < end; i++) {
      final marker = i == errorLine ? '>>>' : '   ';
      numbered.add('$marker ${i + 1} | ${lines[i]}');
    }
    return numbered.join('\n');
  }
}
