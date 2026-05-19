class GlobalConfig {
  final List<String> workspacePaths;

  GlobalConfig({this.workspacePaths = const []});

  factory GlobalConfig.fromJson(Map<String, dynamic> json) {
    return GlobalConfig(
      workspacePaths: List<String>.from(json['limousine-workspaces'] ?? []),
    );
  }

  Map<String, dynamic> toJson() => {'limousine-workspaces': workspacePaths};

  GlobalConfig copyWith({List<String>? workspacePaths}) {
    return GlobalConfig(workspacePaths: workspacePaths ?? this.workspacePaths);
  }
}

class McpConfig {
  final bool enabled;
  final int port;
  final String? token;

  McpConfig({this.enabled = false, this.port = 6891, this.token});

  factory McpConfig.fromJson(Map<String, dynamic> json) {
    return McpConfig(
      enabled: json['enabled'] ?? false,
      port: json['port'] ?? 6891,
      token: json['token'],
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'port': port,
    if (token != null && token!.isNotEmpty) 'token': token,
  };

  McpConfig copyWith({bool? enabled, int? port, String? token, bool clearToken = false}) {
    return McpConfig(
      enabled: enabled ?? this.enabled,
      port: port ?? this.port,
      token: clearToken ? null : (token ?? this.token),
    );
  }
}

class Workspace {
  final String name;
  final Map<String, ProjectRef> projects;
  final List<String> collapsedModules;
  final String? gitSshKeyPath;
  final McpConfig? mcpConfig;

  Workspace({
    required this.name,
    required this.projects,
    this.collapsedModules = const [],
    this.gitSshKeyPath,
    this.mcpConfig,
  });

  factory Workspace.fromJson(Map<String, dynamic> json) {
    final projectsJson = json['projects'] as Map<String, dynamic>? ?? {};
    return Workspace(
      name: json['name'] ?? '',
      projects: projectsJson.map(
        (k, v) => MapEntry(k, ProjectRef.fromJson(k, v)),
      ),
      collapsedModules: List<String>.from(json['collapsed-modules'] ?? []),
      gitSshKeyPath: json['git-ssh-key-path'],
      mcpConfig: json['mcp'] != null ? McpConfig.fromJson(json['mcp']) : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'projects': projects.map((k, v) => MapEntry(k, v.toJson())),
    'collapsed-modules': collapsedModules,
    if (gitSshKeyPath != null) 'git-ssh-key-path': gitSshKeyPath,
    if (mcpConfig != null) 'mcp': mcpConfig!.toJson(),
  };

  Workspace copyWith({
    List<String>? collapsedModules,
    String? gitSshKeyPath,
    bool clearGitSshKeyPath = false,
    McpConfig? mcpConfig,
  }) {
    return Workspace(
      name: name,
      projects: projects,
      collapsedModules: collapsedModules ?? this.collapsedModules,
      gitSshKeyPath: clearGitSshKeyPath ? null : (gitSshKeyPath ?? this.gitSshKeyPath),
      mcpConfig: mcpConfig ?? this.mcpConfig,
    );
  }
}

class ProjectRef {
  final String name;
  final String pathOnDisk;
  final String? gitRepoUrl;

  ProjectRef({required this.name, required this.pathOnDisk, this.gitRepoUrl});

  factory ProjectRef.fromJson(String name, Map<String, dynamic> json) {
    return ProjectRef(
      name: name,
      pathOnDisk: json['path-on-disk'] ?? '',
      gitRepoUrl: json['optional-git-repo-url'],
    );
  }

  Map<String, dynamic> toJson() => {
    'path-on-disk': pathOnDisk,
    if (gitRepoUrl != null) 'optional-git-repo-url': gitRepoUrl,
  };
}
