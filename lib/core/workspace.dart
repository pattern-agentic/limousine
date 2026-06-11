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

  // MCP is on by default. Workspaces with an explicit `mcp.enabled: false`
  // stay off; workspaces with no `mcp` block at all (see Workspace.fromJson)
  // get a default-enabled config so first-time setups don't need to find
  // the Settings dialog before agents can connect. Devs who don't want it
  // can toggle via the AppBar / Settings.
  McpConfig({this.enabled = true, this.port = 6891, this.token});

  factory McpConfig.fromJson(Map<String, dynamic> json) {
    return McpConfig(
      enabled: json['enabled'] ?? true,
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
  final String? gitSshKeyPath;
  final McpConfig? mcpConfig;

  Workspace({
    required this.name,
    required this.projects,
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
      gitSshKeyPath: json['git-ssh-key-path'],
      // No `mcp` block → default-enabled config. Lets new / pre-existing
      // workspaces light up MCP automatically.
      mcpConfig: json['mcp'] != null ? McpConfig.fromJson(json['mcp']) : McpConfig(),
    );
  }

  // `collapsed-modules` was previously persisted here but caused git churn on
  // every UI interaction. It's now ephemeral (in-memory in the client only),
  // and `toJson` deliberately doesn't emit it. Old .wksp files that still
  // carry it are tolerated on read — the field is just ignored. The next save
  // strips it.
  Map<String, dynamic> toJson() => {
    'name': name,
    'projects': projects.map((k, v) => MapEntry(k, v.toJson())),
    if (gitSshKeyPath != null) 'git-ssh-key-path': gitSshKeyPath,
    if (mcpConfig != null) 'mcp': mcpConfig!.toJson(),
  };

  Workspace copyWith({
    String? gitSshKeyPath,
    bool clearGitSshKeyPath = false,
    McpConfig? mcpConfig,
  }) {
    return Workspace(
      name: name,
      projects: projects,
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
