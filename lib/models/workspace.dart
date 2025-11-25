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

class Workspace {
  final String name;
  final Map<String, ProjectRef> projects;
  final List<String> collapsedModules;
  final String? gitSshKeyPath;

  Workspace({
    required this.name,
    required this.projects,
    this.collapsedModules = const [],
    this.gitSshKeyPath,
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
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'projects': projects.map((k, v) => MapEntry(k, v.toJson())),
    'collapsed-modules': collapsedModules,
    if (gitSshKeyPath != null) 'git-ssh-key-path': gitSshKeyPath,
  };

  Workspace copyWith({
    List<String>? collapsedModules,
    String? gitSshKeyPath,
    bool clearGitSshKeyPath = false,
  }) {
    return Workspace(
      name: name,
      projects: projects,
      collapsedModules: collapsedModules ?? this.collapsedModules,
      gitSshKeyPath: clearGitSshKeyPath ? null : (gitSshKeyPath ?? this.gitSshKeyPath),
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
