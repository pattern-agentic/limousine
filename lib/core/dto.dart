import 'module.dart';

enum ProcessStatus { stopped, running, orphaned }

enum StopSignal { sigint, sigterm, sigkill }

class ServiceStateDto {
  final String serviceId;
  final ProcessStatus status;
  final int? pid;
  final DateTime? startTime;
  final StopSignal nextSignal;

  ServiceStateDto({
    required this.serviceId,
    this.status = ProcessStatus.stopped,
    this.pid,
    this.startTime,
    this.nextSignal = StopSignal.sigint,
  });

  Map<String, dynamic> toJson() => {
    'serviceId': serviceId,
    'status': status.name,
    if (pid != null) 'pid': pid,
    if (startTime != null) 'startTime': startTime!.toIso8601String(),
    'nextSignal': nextSignal.name,
  };

  factory ServiceStateDto.fromJson(Map<String, dynamic> json) {
    return ServiceStateDto(
      serviceId: json['serviceId'],
      status: ProcessStatus.values.byName(json['status']),
      pid: json['pid'],
      startTime: json['startTime'] != null ? DateTime.parse(json['startTime']) : null,
      nextSignal: StopSignal.values.byName(json['nextSignal'] ?? 'sigint'),
    );
  }
}

class LoadedProjectDto {
  final String name;
  final String resolvedPath;
  final String? gitRepoUrl;
  final bool existsOnDisk;
  final Project? projectData;
  final String? loadError;

  LoadedProjectDto({
    required this.name,
    required this.resolvedPath,
    this.gitRepoUrl,
    required this.existsOnDisk,
    this.projectData,
    this.loadError,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'resolvedPath': resolvedPath,
    if (gitRepoUrl != null) 'gitRepoUrl': gitRepoUrl,
    'existsOnDisk': existsOnDisk,
    if (projectData != null) 'projectData': projectData!.toJson(),
    if (loadError != null) 'loadError': loadError,
  };

  factory LoadedProjectDto.fromJson(Map<String, dynamic> json) {
    return LoadedProjectDto(
      name: json['name'],
      resolvedPath: json['resolvedPath'],
      gitRepoUrl: json['gitRepoUrl'],
      existsOnDisk: json['existsOnDisk'],
      projectData: json['projectData'] != null
          ? Project.fromJson(json['projectData'])
          : null,
      loadError: json['loadError'],
    );
  }
}

/// Keys-only view of a secrets file. Returned by /secrets/keys without a
/// password header: just the key names, not the values. Used by the secrets
/// editor to render its skeleton before the user supplies the secret-store password.
class SecretsKeysDto {
  final bool activeExists;
  final bool sourceExists;
  final List<String> activeKeys;
  final Map<String, String> sourceContent; // template, not secret
  final String? readError;

  SecretsKeysDto({
    required this.activeExists,
    required this.sourceExists,
    required this.activeKeys,
    required this.sourceContent,
    this.readError,
  });

  factory SecretsKeysDto.fromJson(Map<String, dynamic> json) {
    return SecretsKeysDto(
      activeExists: json['activeExists'] as bool,
      sourceExists: json['sourceExists'] as bool,
      activeKeys: (json['activeKeys'] as List).cast<String>(),
      sourceContent: Map<String, String>.from(json['sourceContent'] as Map),
      readError: json['readError'] as String?,
    );
  }
}

class EnvComparisonDto {
  final bool activeExists;
  final bool sourceExists;
  final Map<String, String> activeContent;
  final Map<String, String> sourceContent;

  EnvComparisonDto({
    required this.activeExists,
    required this.sourceExists,
    required this.activeContent,
    required this.sourceContent,
  });

  Set<String> get activeKeys => activeContent.keys.toSet();
  Set<String> get sourceKeys => sourceContent.keys.toSet();
  Set<String> get missingInActive => sourceKeys.difference(activeKeys);
  Set<String> get extraInActive => activeKeys.difference(sourceKeys);

  Map<String, dynamic> toJson() => {
    'activeExists': activeExists,
    'sourceExists': sourceExists,
    'activeContent': activeContent,
    'sourceContent': sourceContent,
  };

  factory EnvComparisonDto.fromJson(Map<String, dynamic> json) {
    return EnvComparisonDto(
      activeExists: json['activeExists'],
      sourceExists: json['sourceExists'],
      activeContent: Map<String, String>.from(json['activeContent']),
      sourceContent: Map<String, String>.from(json['sourceContent']),
    );
  }
}
