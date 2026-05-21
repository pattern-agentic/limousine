import 'package:logging/logging.dart';

final _log = Logger('Module');

class Project {
  final List<Module> modules;
  final List<String> visibleTabs;
  final String? agentGuide;

  Project({required this.modules, this.visibleTabs = const [], this.agentGuide});

  factory Project.fromJson(Map<String, dynamic> json) {
    final modulesRaw = json['modules'];
    List<Module> modules = [];

    if (modulesRaw is List) {
      modules = modulesRaw.map((m) => Module.fromJson(m)).toList();
    } else if (modulesRaw is Map<String, dynamic>) {
      modules = modulesRaw.entries
          .map((e) => Module.fromJsonEntry(e.key, e.value))
          .toList();
    } else if (modulesRaw != null) {
      _log.warning('Unexpected modules type: ${modulesRaw.runtimeType}');
    }

    return Project(
      modules: modules,
      visibleTabs: List<String>.from(json['visible-tabs'] ?? []),
      agentGuide: _parseAgentGuide(json['agent-guide']),
    );
  }

  /// `agent-guide` accepts either a single string or a list of paragraph
  /// strings. JSON has no native multiline string syntax, so the list form
  /// lets humans format guides as readable paragraphs in the source file.
  /// Paragraphs are joined with a blank line so the rendered dialog (uses
  /// SelectableText with default line wrap) reads naturally.
  static String? _parseAgentGuide(dynamic raw) {
    if (raw == null) return null;
    if (raw is String) return raw;
    if (raw is List) {
      return raw.whereType<String>().join('\n\n');
    }
    _log.warning('Unexpected agent-guide type: ${raw.runtimeType}');
    return null;
  }

  Map<String, dynamic> toJson() => {
    'modules': modules.map((m) => m.toJson()).toList(),
    if (visibleTabs.isNotEmpty) 'visible-tabs': visibleTabs,
    if (agentGuide != null) 'agent-guide': agentGuide,
  };
}

class Module {
  final String name;
  final Map<String, Service> services;
  final ModuleConfig config;

  Module({required this.name, required this.services, required this.config});

  factory Module.fromJson(Map<String, dynamic> json) {
    return _build(json['name'] ?? '', json);
  }

  factory Module.fromJsonEntry(String name, dynamic json) {
    if (json is! Map<String, dynamic>) {
      _log.warning('Module $name has unexpected format: ${json.runtimeType}');
      return Module(name: name, services: {}, config: ModuleConfig());
    }
    return _build(name, json);
  }

  static Module _build(String name, Map<String, dynamic> json) {
    final servicesRaw = json['services'];
    Map<String, Service> services = {};
    if (servicesRaw is Map<String, dynamic>) {
      services = servicesRaw.map((k, v) => MapEntry(k, Service.fromJson(k, v)));
    }
    // Distinguish "no `config:` block declared" from "declared but empty".
    // Modules that don't opt into limousine's env model (e.g. studio-frontend
    // which uses Vite's native env loading) should not trigger drift
    // warnings just because we'd default `source-env-file` to `.env.example`
    // and find one sitting in the project root.
    final configJson = json['config'];
    final declared = configJson is Map<String, dynamic>;
    return Module(
      name: name,
      services: services,
      config: ModuleConfig.fromJson(
        declared ? configJson : const <String, dynamic>{},
        declared: declared,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'services': services.map((k, v) => MapEntry(k, v.toJson())),
    'config': config.toJson(),
  };
}

class Service {
  final String name;
  final Map<String, String> commands;

  Service({required this.name, required this.commands});

  factory Service.fromJson(String name, dynamic json) {
    if (json is! Map<String, dynamic>) {
      _log.warning('Service $name has unexpected format: ${json.runtimeType}');
      return Service(name: name, commands: {});
    }
    final commandsRaw = json['commands'];
    Map<String, String> commands = {};
    if (commandsRaw is Map<String, dynamic>) {
      commands = commandsRaw.map((k, v) => MapEntry(k, v.toString()));
    }
    return Service(name: name, commands: commands);
  }

  Map<String, dynamic> toJson() => {'commands': commands};

  String? get runCommand => commands['run'];
}

class ModuleConfig {
  final String activeEnvFile;
  final String activeSecretsEnvFile;
  final String sourceEnvFile;
  final String sourceSecretsFile;
  /// True when the module's limousine.proj declared a `config:` block.
  /// Drift detection (env + secrets) is skipped when this is false — the
  /// module hasn't opted into limousine's env management.
  final bool declared;

  ModuleConfig({
    this.activeEnvFile = '.env',
    this.activeSecretsEnvFile = 'secrets.env',
    this.sourceEnvFile = '.env.example',
    this.sourceSecretsFile = 'secrets.env.example',
    this.declared = false,
  });

  factory ModuleConfig.fromJson(Map<String, dynamic> json, {bool declared = false}) {
    return ModuleConfig(
      declared: declared,
      activeEnvFile: json['active-env-file'] ?? '.env',
      activeSecretsEnvFile: json['active-secrets-env-file'] ?? 'secrets.env',
      sourceEnvFile: json['source-env-file'] ?? '.env.example',
      sourceSecretsFile: json['source-secrets-file'] ?? 'secrets.env.example',
    );
  }

  Map<String, dynamic> toJson() => {
    'active-env-file': activeEnvFile,
    'active-secrets-env-file': activeSecretsEnvFile,
    'source-env-file': sourceEnvFile,
    'source-secrets-file': sourceSecretsFile,
  };
}
