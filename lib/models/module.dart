import 'package:logging/logging.dart';

final _log = Logger('Module');

class Project {
  final List<Module> modules;
  final List<String> visibleTabs;

  Project({required this.modules, this.visibleTabs = const []});

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
    );
  }

  Map<String, dynamic> toJson() => {
    'modules': modules.map((m) => m.toJson()).toList(),
    if (visibleTabs.isNotEmpty) 'visible-tabs': visibleTabs,
  };
}

class Module {
  final String name;
  final Map<String, Service> services;
  final ModuleConfig config;

  Module({required this.name, required this.services, required this.config});

  factory Module.fromJson(Map<String, dynamic> json) {
    final servicesRaw = json['services'];
    Map<String, Service> services = {};

    if (servicesRaw is Map<String, dynamic>) {
      services = servicesRaw.map((k, v) => MapEntry(k, Service.fromJson(k, v)));
    }

    return Module(
      name: json['name'] ?? '',
      services: services,
      config: ModuleConfig.fromJson(json['config'] ?? {}),
    );
  }

  factory Module.fromJsonEntry(String name, dynamic json) {
    if (json is! Map<String, dynamic>) {
      _log.warning('Module $name has unexpected format: ${json.runtimeType}');
      return Module(name: name, services: {}, config: ModuleConfig());
    }

    final servicesRaw = json['services'];
    Map<String, Service> services = {};

    if (servicesRaw is Map<String, dynamic>) {
      services = servicesRaw.map((k, v) => MapEntry(k, Service.fromJson(k, v)));
    }

    return Module(
      name: name,
      services: services,
      config: ModuleConfig.fromJson(json['config'] ?? {}),
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

  ModuleConfig({
    this.activeEnvFile = '.env',
    this.activeSecretsEnvFile = '.env.secrets',
    this.sourceEnvFile = '.env.example',
    this.sourceSecretsFile = '.env.secrets.example',
  });

  factory ModuleConfig.fromJson(Map<String, dynamic> json) {
    return ModuleConfig(
      activeEnvFile: json['active-env-file'] ?? '.env',
      activeSecretsEnvFile: json['active-secrets-env-file'] ?? '.env.secrets',
      sourceEnvFile: json['source-env-file'] ?? '.env.example',
      sourceSecretsFile: json['source-secrets-file'] ?? '.env.secrets.example',
    );
  }

  Map<String, dynamic> toJson() => {
    'active-env-file': activeEnvFile,
    'active-secrets-env-file': activeSecretsEnvFile,
    'source-env-file': sourceEnvFile,
    'source-secrets-file': sourceSecretsFile,
  };
}
