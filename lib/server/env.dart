import 'dart:io';
import '../core/dto.dart';

class Env {
  static const _extraPaths = [
    '/usr/local/bin',
    '/opt/homebrew/bin',
    '/opt/homebrew/sbin',
    '/home/linuxbrew/.linuxbrew/bin',
    '/snap/bin',
  ];

  static Future<Map<String, String>> loadEnvFile(String path) async {
    final file = File(path);
    if (!await file.exists()) return {};
    return parseEnvLines(await file.readAsLines());
  }

  static Map<String, String> parseEnvLines(List<String> lines) {
    final result = <String, String>{};
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final eqIndex = trimmed.indexOf('=');
      if (eqIndex == -1) continue;
      final key = trimmed.substring(0, eqIndex).trim();
      var value = trimmed.substring(eqIndex + 1).trim();
      if ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'"))) {
        value = value.substring(1, value.length - 1);
      }
      result[key] = value;
    }
    return result;
  }

  static Future<Map<String, String>> buildProcessEnv(
    String? activeEnvPath,
    String? activeSecretsPath,
  ) async {
    final env = Map<String, String>.from(Platform.environment);

    final currentPath = env['PATH'] ?? '';
    final pathsToAdd = _extraPaths.where((p) => !currentPath.contains(p)).join(':');
    if (pathsToAdd.isNotEmpty) {
      env['PATH'] = '$currentPath:$pathsToAdd';
    }

    env['TERM'] = 'xterm-256color';
    env['COLORTERM'] = 'truecolor';
    env['FORCE_COLOR'] = '1';
    env['CLICOLOR_FORCE'] = '1';
    if (activeEnvPath != null) env.addAll(await loadEnvFile(activeEnvPath));
    if (activeSecretsPath != null) env.addAll(await loadEnvFile(activeSecretsPath));
    return env;
  }

  static Future<EnvComparisonDto> compareEnvFiles(
    String activePath,
    String sourcePath,
  ) async {
    final active = await loadEnvFile(activePath);
    final source = await loadEnvFile(sourcePath);
    return EnvComparisonDto(
      activeExists: await File(activePath).exists(),
      sourceExists: await File(sourcePath).exists(),
      activeContent: active,
      sourceContent: source,
    );
  }
}
