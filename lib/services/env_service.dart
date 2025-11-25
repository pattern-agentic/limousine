import 'dart:io';

class EnvService {
  static Future<Map<String, String>> loadEnvFile(String path) async {
    final file = File(path);
    if (!await file.exists()) return {};
    final lines = await file.readAsLines();
    return parseEnvLines(lines);
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
    env['TERM'] = 'xterm-256color';
    env['COLORTERM'] = 'truecolor';
    env['FORCE_COLOR'] = '1';
    env['CLICOLOR_FORCE'] = '1';
    if (activeEnvPath != null) {
      env.addAll(await loadEnvFile(activeEnvPath));
    }
    if (activeSecretsPath != null) {
      env.addAll(await loadEnvFile(activeSecretsPath));
    }
    return env;
  }

  static Future<EnvComparison> compareEnvFiles(
    String activePath,
    String sourcePath,
  ) async {
    final active = await loadEnvFile(activePath);
    final source = await loadEnvFile(sourcePath);
    final activeFile = File(activePath);
    final sourceFile = File(sourcePath);

    return EnvComparison(
      activeExists: await activeFile.exists(),
      sourceExists: await sourceFile.exists(),
      activeKeys: active.keys.toSet(),
      sourceKeys: source.keys.toSet(),
      activeContent: active,
      sourceContent: source,
    );
  }
}

class EnvComparison {
  final bool activeExists;
  final bool sourceExists;
  final Set<String> activeKeys;
  final Set<String> sourceKeys;
  final Map<String, String> activeContent;
  final Map<String, String> sourceContent;

  EnvComparison({
    required this.activeExists,
    required this.sourceExists,
    required this.activeKeys,
    required this.sourceKeys,
    required this.activeContent,
    required this.sourceContent,
  });

  Set<String> get missingInActive => sourceKeys.difference(activeKeys);
  Set<String> get extraInActive => activeKeys.difference(sourceKeys);
}
