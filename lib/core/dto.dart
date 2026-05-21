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

/// Per-module env/secrets file drift between active (per-dev) and source
/// (committed template). Computed locally — does the committed template
/// list keys that aren't yet in the dev's active copy? Or vice versa?
class ConfigDeltaDto {
  final String module;
  final bool envActiveExists;
  final bool envSourceExists;
  final int envMissingInActive;
  final int envExtraInActive;
  final bool secretsActiveExists;
  final bool secretsSourceExists;
  final int secretsMissingInActive;
  final int secretsExtraInActive;

  ConfigDeltaDto({
    required this.module,
    this.envActiveExists = false,
    this.envSourceExists = false,
    this.envMissingInActive = 0,
    this.envExtraInActive = 0,
    this.secretsActiveExists = false,
    this.secretsSourceExists = false,
    this.secretsMissingInActive = 0,
    this.secretsExtraInActive = 0,
  });

  bool get hasEnvDelta =>
      envSourceExists &&
      (envMissingInActive > 0 || envExtraInActive > 0 || !envActiveExists);

  bool get hasSecretsDelta =>
      secretsSourceExists &&
      (secretsMissingInActive > 0 ||
          secretsExtraInActive > 0 ||
          !secretsActiveExists);

  bool get hasAny => hasEnvDelta || hasSecretsDelta;

  Map<String, dynamic> toJson() => {
        'module': module,
        'envActiveExists': envActiveExists,
        'envSourceExists': envSourceExists,
        'envMissingInActive': envMissingInActive,
        'envExtraInActive': envExtraInActive,
        'secretsActiveExists': secretsActiveExists,
        'secretsSourceExists': secretsSourceExists,
        'secretsMissingInActive': secretsMissingInActive,
        'secretsExtraInActive': secretsExtraInActive,
      };

  factory ConfigDeltaDto.fromJson(Map<String, dynamic> json) => ConfigDeltaDto(
        module: json['module'],
        envActiveExists: json['envActiveExists'] ?? false,
        envSourceExists: json['envSourceExists'] ?? false,
        envMissingInActive: json['envMissingInActive'] ?? 0,
        envExtraInActive: json['envExtraInActive'] ?? 0,
        secretsActiveExists: json['secretsActiveExists'] ?? false,
        secretsSourceExists: json['secretsSourceExists'] ?? false,
        secretsMissingInActive: json['secretsMissingInActive'] ?? 0,
        secretsExtraInActive: json['secretsExtraInActive'] ?? 0,
      );
}

class DirtyFileDto {
  final String path;
  final String status;   // 2-char porcelain code, e.g. " M", "??", "MM"
  final bool isLockFile; // matched against the known lock-file basenames
  DirtyFileDto({required this.path, required this.status, required this.isLockFile});

  Map<String, dynamic> toJson() =>
      {'path': path, 'status': status, 'isLockFile': isLockFile};

  factory DirtyFileDto.fromJson(Map<String, dynamic> json) => DirtyFileDto(
        path: json['path'],
        status: json['status'],
        isLockFile: json['isLockFile'] ?? false,
      );
}

/// Per-project git status. All upstream/main counts come from local refs only
/// (no network); call the /refresh endpoint to update them after a fetch.
class GitStatusDto {
  final String project;
  final bool exists;            // false → project dir / .git not present
  final String? branch;         // null only if exists is false; "HEAD" if detached
  final String? shortSha;
  final String? subject;        // last commit subject
  final List<DirtyFileDto> dirtyFiles;
  final String? upstream;       // e.g. "origin/feature/foo"; null if branch has no upstream
  final int? behindUpstream;
  final int? aheadUpstream;
  final String? mainBranch;     // resolved default branch ("main" / "master")
  final int? behindMain;        // null when branch == mainBranch
  final DateTime? lastFetched;
  final String? error;
  final List<ConfigDeltaDto> configDeltas;

  GitStatusDto({
    required this.project,
    required this.exists,
    this.branch,
    this.shortSha,
    this.subject,
    this.dirtyFiles = const [],
    this.upstream,
    this.behindUpstream,
    this.aheadUpstream,
    this.mainBranch,
    this.behindMain,
    this.lastFetched,
    this.error,
    this.configDeltas = const [],
  });

  int get dirty => dirtyFiles.length;
  int get dirtyCode => dirtyFiles.where((f) => !f.isLockFile).length;
  int get dirtyLock => dirtyFiles.where((f) => f.isLockFile).length;
  List<DirtyFileDto> get lockFiles =>
      dirtyFiles.where((f) => f.isLockFile).toList();
  List<DirtyFileDto> get codeFiles =>
      dirtyFiles.where((f) => !f.isLockFile).toList();

  Map<String, dynamic> toJson() => {
        'project': project,
        'exists': exists,
        if (branch != null) 'branch': branch,
        if (shortSha != null) 'shortSha': shortSha,
        if (subject != null) 'subject': subject,
        'dirtyFiles': dirtyFiles.map((f) => f.toJson()).toList(),
        if (upstream != null) 'upstream': upstream,
        if (behindUpstream != null) 'behindUpstream': behindUpstream,
        if (aheadUpstream != null) 'aheadUpstream': aheadUpstream,
        if (mainBranch != null) 'mainBranch': mainBranch,
        if (behindMain != null) 'behindMain': behindMain,
        if (lastFetched != null) 'lastFetched': lastFetched!.toIso8601String(),
        if (error != null) 'error': error,
        'configDeltas': configDeltas.map((c) => c.toJson()).toList(),
      };

  factory GitStatusDto.fromJson(Map<String, dynamic> json) {
    return GitStatusDto(
      project: json['project'],
      exists: json['exists'],
      branch: json['branch'],
      shortSha: json['shortSha'],
      subject: json['subject'],
      dirtyFiles: ((json['dirtyFiles'] as List?) ?? const [])
          .map((j) => DirtyFileDto.fromJson(j as Map<String, dynamic>))
          .toList(),
      upstream: json['upstream'],
      behindUpstream: json['behindUpstream'],
      aheadUpstream: json['aheadUpstream'],
      mainBranch: json['mainBranch'],
      behindMain: json['behindMain'],
      lastFetched: json['lastFetched'] != null
          ? DateTime.parse(json['lastFetched'])
          : null,
      error: json['error'],
      configDeltas: ((json['configDeltas'] as List?) ?? const [])
          .map((j) => ConfigDeltaDto.fromJson(j as Map<String, dynamic>))
          .toList(),
    );
  }
}

class GitPullResultDto {
  final bool ok;
  final String message;
  final GitStatusDto status;
  GitPullResultDto({required this.ok, required this.message, required this.status});

  factory GitPullResultDto.fromJson(Map<String, dynamic> json) => GitPullResultDto(
        ok: json['ok'] ?? false,
        message: json['message'] ?? '',
        status: GitStatusDto.fromJson(json['status']),
      );
}
