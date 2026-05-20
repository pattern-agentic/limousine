import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../core/dto.dart';
import '../core/workspace.dart';

final _log = Logger('ApiClient');

class ApiException implements Exception {
  final int statusCode;
  final String message;
  ApiException(this.statusCode, this.message);
  @override
  String toString() => 'ApiException($statusCode): $message';
}

class WorkspaceState {
  final bool open;
  final String? path;
  final Workspace? workspace;
  final Map<String, LoadedProjectDto> projects;

  WorkspaceState({
    required this.open,
    this.path,
    this.workspace,
    this.projects = const {},
  });

  factory WorkspaceState.fromJson(Map<String, dynamic> json) {
    if (json['open'] != true) return WorkspaceState(open: false);
    final projectsJson = json['projects'] as Map<String, dynamic>? ?? {};
    return WorkspaceState(
      open: true,
      path: json['path'],
      workspace: Workspace.fromJson(json['workspace']),
      projects: projectsJson.map(
        (k, v) => MapEntry(k, LoadedProjectDto.fromJson(v)),
      ),
    );
  }
}

class ServiceSummary {
  final String id;
  final String projectName;
  final String moduleName;
  final String serviceName;
  final Map<String, String> commands;

  ServiceSummary({
    required this.id,
    required this.projectName,
    required this.moduleName,
    required this.serviceName,
    required this.commands,
  });

  factory ServiceSummary.fromJson(Map<String, dynamic> json) {
    return ServiceSummary(
      id: json['id'],
      projectName: json['projectName'],
      moduleName: json['moduleName'],
      serviceName: json['serviceName'],
      commands: Map<String, String>.from(json['commands']),
    );
  }

  String? get runCommand => commands['run'];
}

class ApiClient {
  final Uri baseUri;
  final http.Client _http = http.Client();

  ApiClient({required this.baseUri});

  Uri _u(String path) => baseUri.resolve(path);

  Future<Map<String, dynamic>> _get(String path) async {
    final r = await _http.get(_u(path));
    if (r.statusCode >= 400) throw ApiException(r.statusCode, r.body);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<List<dynamic>> _getList(String path) async {
    final r = await _http.get(_u(path));
    if (r.statusCode >= 400) throw ApiException(r.statusCode, r.body);
    return jsonDecode(r.body) as List<dynamic>;
  }

  Future<void> _post(String path, [Map<String, dynamic>? body]) async {
    final r = await _http.post(
      _u(path),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode(body ?? {}),
    );
    if (r.statusCode >= 400) throw ApiException(r.statusCode, r.body);
  }

  Future<void> _put(String path, Map<String, dynamic> body) async {
    final r = await _http.put(
      _u(path),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode(body),
    );
    if (r.statusCode >= 400) throw ApiException(r.statusCode, r.body);
  }

  Future<void> _delete(String path) async {
    final r = await _http.delete(_u(path));
    if (r.statusCode >= 400) throw ApiException(r.statusCode, r.body);
  }

  Future<WorkspaceState> getWorkspace() async =>
      WorkspaceState.fromJson(await _get('/api/workspace'));

  Future<void> openWorkspace(String path) =>
      _post('/api/workspace/open', {'path': path});

  Future<void> closeWorkspace() => _post('/api/workspace/close');

  Future<void> saveWorkspace(Workspace workspace) =>
      _put('/api/workspace', workspace.toJson());

  Future<GlobalConfig> getGlobalConfig() async =>
      GlobalConfig.fromJson(await _get('/api/global-config'));

  Future<void> addGlobalWorkspace(String path) =>
      _post('/api/global-config/workspaces', {'path': path});

  Future<void> removeGlobalWorkspace(String path) =>
      _delete('/api/global-config/workspaces?path=${Uri.encodeQueryComponent(path)}');

  Future<List<ServiceSummary>> listServices() async {
    final list = await _getList('/api/services');
    return list.map((j) => ServiceSummary.fromJson(j as Map<String, dynamic>)).toList();
  }

  Future<Map<String, ServiceStateDto>> getServiceStates() async {
    final json = await _get('/api/services/states');
    return json.map((k, v) =>
        MapEntry(k, ServiceStateDto.fromJson(v as Map<String, dynamic>)));
  }

  Future<void> startService(String serviceId, {String? command}) =>
      _post('/api/services/$serviceId/start',
          command != null ? {'command': command} : null);

  Future<void> stopService(String serviceId) =>
      _post('/api/services/$serviceId/stop');

  Future<void> killOrphan(String serviceId) =>
      _post('/api/services/$serviceId/kill-orphan');

  Future<EnvComparisonDto> getEnv(String serviceId) async =>
      EnvComparisonDto.fromJson(await _get('/api/services/$serviceId/env'));

  Future<void> setEnv(String serviceId, Map<String, String> content) =>
      _put('/api/services/$serviceId/env', {'content': content});

  Future<void> cloneProject(String projectName) =>
      _post('/api/projects/$projectName/clone');

  /// Reload one project's `limousine.proj`. Throws [ApiException] with a JSON
  /// body listing running services on 409.
  Future<void> reloadProject(String projectName) =>
      _post('/api/projects/$projectName/reload');

  /// Re-read the .wksp from disk. Throws [ApiException] with a JSON body on
  /// 409 (some removed/changed project still has running services).
  /// Returns the diff on success.
  Future<Map<String, dynamic>> reloadWorkspace() async {
    final r = await _http.post(
      _u('/api/workspace/reload'),
      headers: const {'content-type': 'application/json'},
      body: '{}',
    );
    if (r.statusCode >= 400) throw ApiException(r.statusCode, r.body);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<SecretsKeysDto> getSecretsKeys(String serviceId) async {
    final json = await _get('/api/services/$serviceId/secrets/keys');
    return SecretsKeysDto.fromJson(json);
  }

  Future<EnvComparisonDto> getSecretsValues(String serviceId, String password) async {
    final r = await _http.get(
      _u('/api/services/$serviceId/secrets'),
      headers: {'authorization': 'Bearer $password'},
    );
    if (r.statusCode == 401) {
      throw ApiException(401, 'Bad secret-store password');
    }
    if (r.statusCode >= 400) throw ApiException(r.statusCode, r.body);
    return EnvComparisonDto.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<void> setSecrets(
    String serviceId,
    String password,
    Map<String, String> content,
  ) async {
    final r = await _http.put(
      _u('/api/services/$serviceId/secrets'),
      headers: {
        'content-type': 'application/json',
        'authorization': 'Bearer $password',
      },
      body: jsonEncode({'content': content}),
    );
    if (r.statusCode == 401) {
      throw ApiException(401, 'Bad secret-store password');
    }
    if (r.statusCode >= 400) throw ApiException(r.statusCode, r.body);
  }

  Uri _wsUri(String path) {
    final scheme = baseUri.scheme == 'https' ? 'wss' : 'ws';
    return Uri(
      scheme: scheme,
      host: baseUri.host,
      port: baseUri.hasPort ? baseUri.port : null,
      path: path,
    );
  }

  WebSocketChannel openServiceSocket(String serviceId) {
    final uri = _wsUri('/ws/services/$serviceId');
    _log.fine('Opening service socket: $uri');
    return WebSocketChannel.connect(uri);
  }

  WebSocketChannel openStateSocket() {
    final uri = _wsUri('/ws/state');
    _log.fine('Opening state socket: $uri');
    return WebSocketChannel.connect(uri);
  }

  void close() => _http.close();
}
