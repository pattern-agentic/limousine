import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../core/workspace.dart';
import '../core/dto.dart';
import 'env.dart';
import 'git.dart';
import 'mcp.dart';
import 'project_status.dart';
import 'secret_store.dart';
import 'service_manager.dart';
import 'storage.dart';
import 'workspace_manager.dart';

final _log = Logger('Api');

Response _json(Object? body, {int status = 200}) => Response(
      status,
      body: jsonEncode(body),
      headers: {'content-type': 'application/json'},
    );

Response _error(String message, {int status = 400}) =>
    _json({'error': message}, status: status);

/// Pulls the bearer password from `Authorization: Bearer <pw>` and validates
/// it against the secret store's password. Returns the password if valid, or
/// a 401 response. Caller short-circuits on the response.
({String? ageKey, Response? failure}) _requireSecretStoreHeader(
  Request req,
  SecretStore store,
) {
  final auth = req.headers['authorization'];
  if (auth == null || !auth.toLowerCase().startsWith('bearer ')) {
    return (
      ageKey: null,
      failure: _error(
          'Missing Authorization: Bearer <age-private-key> header',
          status: 401),
    );
  }
  final candidate = auth.substring(7);
  if (!store.verifyHeaderKey(candidate)) {
    return (
      ageKey: null,
      failure: _error('Bad age private key', status: 401),
    );
  }
  return (ageKey: candidate, failure: null);
}

Router buildApiRouter(
  WorkspaceManager wsm,
  ServiceManager sm,
  McpManager mcp,
  SecretStore secretStore,
) {
  final router = Router();

  router.get('/api/health', (Request _) => _json({'ok': true}));

  router.get('/api/workspace', (Request _) async {
    final ws = wsm.workspace;
    if (ws == null) return _json({'open': false});
    return _json({
      'open': true,
      'path': wsm.workspacePath,
      'workspace': ws.toJson(),
      'projects': wsm.projects.map((k, v) => MapEntry(k, v.toJson())),
    });
  });

  router.post('/api/workspace/open', (Request req) async {
    final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final path = body['path'] as String?;
    if (path == null) return _error('path required');
    try {
      await wsm.open(path);
      await sm.scanOrphans();
      return _json({'ok': true});
    } catch (e, st) {
      _log.warning('Failed to open workspace $path', e, st);
      return _error('Failed to open: $e', status: 500);
    }
  });

  router.post('/api/workspace/close', (Request _) async {
    await wsm.close();
    return _json({'ok': true});
  });

  router.put('/api/workspace', (Request req) async {
    final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final current = wsm.workspace;
    if (current == null) return _error('No workspace open', status: 409);
    final updated = Workspace.fromJson(body);
    await wsm.saveWorkspace(Workspace(
      name: current.name,
      projects: current.projects,
      gitSshKeyPath: updated.gitSshKeyPath,
      mcpConfig: updated.mcpConfig,
    ));
    return _json({'ok': true});
  });

  router.get('/api/global-config', (Request _) async {
    return _json((await Storage.loadGlobalConfig()).toJson());
  });

  router.post('/api/global-config/workspaces', (Request req) async {
    final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final path = body['path'] as String?;
    if (path == null) return _error('path required');
    final cfg = await Storage.loadGlobalConfig();
    if (!cfg.workspacePaths.contains(path)) {
      await Storage.saveGlobalConfig(
        cfg.copyWith(workspacePaths: [...cfg.workspacePaths, path]),
      );
    }
    return _json({'ok': true});
  });

  router.delete('/api/global-config/workspaces', (Request req) async {
    final path = req.url.queryParameters['path'];
    if (path == null) return _error('path required');
    final cfg = await Storage.loadGlobalConfig();
    await Storage.saveGlobalConfig(
      cfg.copyWith(
        workspacePaths: cfg.workspacePaths.where((x) => x != path).toList(),
      ),
    );
    return _json({'ok': true});
  });

  router.post('/api/projects/<name>/clone', (Request _, String name) async {
    final ws = wsm.workspace;
    if (ws == null) return _error('No workspace open', status: 409);
    final ref = ws.projects[name];
    if (ref == null) return _error('Project not found: $name', status: 404);
    if (ref.gitRepoUrl == null) {
      return _error('Project has no git URL', status: 400);
    }
    final loaded = wsm.projects[name];
    if (loaded != null && loaded.existsOnDisk) {
      return _error('Project already exists on disk', status: 409);
    }
    final targetPath = loaded?.resolvedPath ??
        Storage.resolvePath(wsm.cloneRoot!, ref.pathOnDisk);
    final result = await Git.clone(
      ref.gitRepoUrl!,
      targetPath,
      sshKeyPath: ws.gitSshKeyPath,
    );
    if (!result.success) {
      return _error(
        'git clone failed (exit ${result.exitCode}):\n${result.stderr}',
        status: 500,
      );
    }
    await wsm.reloadProjects();
    return _json({'ok': true, 'stdout': result.stdout, 'stderr': result.stderr});
  });

  router.get('/api/git/projects/<name>/status', (Request _, String name) async {
    final loaded = wsm.projects[name];
    if (loaded == null) return _error('Project not found: $name', status: 404);
    final dto = await Git.status(name, loaded.resolvedPath);
    return _json((await ProjectStatus.withConfigDeltas(dto, loaded)).toJson());
  });

  router.post('/api/git/projects/<name>/refresh', (Request _, String name) async {
    final loaded = wsm.projects[name];
    if (loaded == null) return _error('Project not found: $name', status: 404);
    final dto = await Git.refresh(name, loaded.resolvedPath);
    return _json((await ProjectStatus.withConfigDeltas(dto, loaded)).toJson());
  });

  router.post('/api/git/projects/<name>/pull', (Request _, String name) async {
    final loaded = wsm.projects[name];
    if (loaded == null) return _error('Project not found: $name', status: 404);
    final result = await Git.pullFfOnly(name, loaded.resolvedPath);
    // Pull may have updated source files (env.example, secrets.env.example).
    // Recompute deltas against the post-pull tree before responding.
    final withDeltas = await ProjectStatus.withConfigDeltas(result.status, loaded);
    return _json({
      'ok': result.success,
      'message': result.message,
      'status': withDeltas.toJson(),
    }, status: result.success ? 200 : 409);
  });

  router.post('/api/projects/<name>/reload', (Request _, String name) async {
    final loaded = wsm.projects[name];
    if (loaded == null) return _error('Project not found: $name', status: 404);
    final blocking = wsm
        .allServices()
        .where((s) => s.projectName == name)
        .where((s) {
          final st = sm.states[s.id];
          return st != null && st.status != ProcessStatus.stopped;
        })
        .map((s) => {'id': s.id, 'status': sm.states[s.id]!.status.name})
        .toList();
    if (blocking.isNotEmpty) {
      return _json({
        'error': 'Project has active services. Stop them first.',
        'runningServices': blocking,
      }, status: 409);
    }
    await wsm.reloadProject(name);
    return _json({'ok': true});
  });

  router.post('/api/workspace/reload', (Request _) async {
    final WorkspaceDiff diff;
    try {
      diff = await wsm.peekDiff();
    } catch (e) {
      return _error('Failed to re-read workspace: $e', status: 500);
    }

    // Blocked: any removed-or-changed project that still has a running /
    // orphaned service. Unchanged projects (and new ones) are always safe.
    final blocking = <Map<String, String>>[];
    final affectedProjects = {...diff.removed, ...diff.changed};
    for (final s in wsm.allServices()) {
      if (!affectedProjects.contains(s.projectName)) continue;
      final st = sm.states[s.id];
      if (st != null && st.status != ProcessStatus.stopped) {
        blocking.add({
          'id': s.id,
          'status': st.status.name,
          'project': s.projectName,
        });
      }
    }
    if (blocking.isNotEmpty) {
      return _json({
        'error': 'Workspace reload would touch projects with running services. '
            'Stop them first or quit and restart limousine.',
        'runningServices': blocking,
        'added': diff.added,
        'removed': diff.removed,
        'changed': diff.changed,
      }, status: 409);
    }

    await wsm.applyDiff(diff);
    return _json({
      'ok': true,
      'added': diff.added,
      'removed': diff.removed,
      'changed': diff.changed,
    });
  });

  router.get('/api/services', (Request _) {
    final services = wsm.allServices().map((s) => s.toJson()).toList();
    return _json(services);
  });

  router.get('/api/services/states', (Request _) {
    return _json(sm.states.map((k, v) => MapEntry(k, v.toJson())));
  });

  router.post('/api/services/<id|.*>/start', (Request req, String id) async {
    final raw = await req.readAsString();
    final body = raw.isEmpty
        ? <String, dynamic>{}
        : (jsonDecode(raw) as Map<String, dynamic>? ?? {});
    try {
      await sm.startService(id, commandName: body['command'] as String?);
      return _json({'ok': true});
    } catch (e) {
      return _error(e.toString(), status: 409);
    }
  });

  router.post('/api/services/<id|.*>/stop', (Request _, String id) async {
    try {
      await sm.stopService(id);
      return _json({'ok': true});
    } catch (e) {
      return _error(e.toString(), status: 409);
    }
  });

  router.post('/api/services/<id|.*>/kill-orphan', (Request _, String id) async {
    await sm.killOrphan(id);
    return _json({'ok': true});
  });

  router.get('/api/services/<id|.*>/env', (Request req, String id) async {
    final info = wsm.findService(id);
    if (info == null) return _error('Service not found', status: 404);
    final activePath = p.join(info.projectPath, info.moduleConfig.activeEnvFile);
    final sourcePath = p.join(info.projectPath, info.moduleConfig.sourceEnvFile);
    return _json((await Env.compareEnvFiles(activePath, sourcePath)).toJson());
  });

  router.put('/api/services/<id|.*>/env', (Request req, String id) async {
    final info = wsm.findService(id);
    if (info == null) return _error('Service not found', status: 404);
    final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final content = (body['content'] as Map<String, dynamic>?)
            ?.map((k, v) => MapEntry(k, v.toString())) ??
        const <String, String>{};
    final activePath = p.join(info.projectPath, info.moduleConfig.activeEnvFile);
    try {
      await Env.writeEnvFile(activePath, content);
    } catch (e) {
      return _error(e.toString(), status: 400);
    }
    return _json({'ok': true});
  });

  // Secret-store status — no auth, returns enough for the UI to render the
  // indicator and decide whether to prompt for a password before opening the
  // editor.
  router.get('/api/secret-store/status', (Request _) {
    return _json({'status': secretStore.status.name});
  });

  // Keys-only view of an active secrets file. Uses the server's stored
  // password (already proven correct via the stamp). Safe to expose without
  // a password header: key names aren't typically the sensitive part.
  router.get('/api/services/<id|.*>/secrets/keys', (Request _, String id) async {
    final info = wsm.findService(id);
    if (info == null) return _error('Service not found', status: 404);
    final activePath = p.join(info.projectPath, info.moduleConfig.activeSecretsEnvFile);
    final sourcePath = p.join(info.projectPath, info.moduleConfig.sourceSecretsFile);
    final sourceExists = await File(sourcePath).exists();
    final activeExists = await File(activePath).exists();

    Map<String, String> sourceContent = const {};
    if (sourceExists) {
      sourceContent = await Env.loadEnvFile(sourcePath); // template, not a secret
    }

    List<String> activeKeys = const [];
    String? readError;
    if (activeExists) {
      try {
        final m = await secretStore.loadSecrets(activePath);
        activeKeys = m.keys.toList();
      } on SecretStoreLockedException catch (e) {
        readError = e.message;
      } catch (e) {
        readError = 'Failed to decrypt: $e';
      }
    }

    return _json({
      'activeExists': activeExists,
      'sourceExists': sourceExists,
      'activeKeys': activeKeys,
      'sourceContent': sourceContent,
      if (readError != null) 'readError': readError,
    });
  });

  // Full values for the active secrets file — password header required.
  router.get('/api/services/<id|.*>/secrets', (Request req, String id) async {
    final auth = _requireSecretStoreHeader(req, secretStore);
    if (auth.failure != null) return auth.failure!;
    final info = wsm.findService(id);
    if (info == null) return _error('Service not found', status: 404);
    final activePath = p.join(info.projectPath, info.moduleConfig.activeSecretsEnvFile);
    final sourcePath = p.join(info.projectPath, info.moduleConfig.sourceSecretsFile);

    Map<String, String> activeContent = const {};
    bool activeExists = await File(activePath).exists();
    if (activeExists) {
      try {
        activeContent = await secretStore.loadSecrets(activePath);
      } on SecretStoreLockedException catch (e) {
        return _error(e.message, status: 423);
      } catch (e) {
        return _error('Failed to decrypt: $e', status: 500);
      }
    }
    final sourceContent =
        await File(sourcePath).exists() ? await Env.loadEnvFile(sourcePath) : <String, String>{};

    return _json(EnvComparisonDto(
      activeExists: activeExists,
      sourceExists: await File(sourcePath).exists(),
      activeContent: activeContent,
      sourceContent: sourceContent,
    ).toJson());
  });

  // Write a new (always-encrypted) secrets file — password header required.
  router.put('/api/services/<id|.*>/secrets', (Request req, String id) async {
    final auth = _requireSecretStoreHeader(req, secretStore);
    if (auth.failure != null) return auth.failure!;
    final info = wsm.findService(id);
    if (info == null) return _error('Service not found', status: 404);
    final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final content = (body['content'] as Map<String, dynamic>?)
            ?.map((k, v) => MapEntry(k, v.toString())) ??
        const <String, String>{};
    final activePath = p.join(info.projectPath, info.moduleConfig.activeSecretsEnvFile);
    try {
      await secretStore.saveSecrets(activePath, content);
    } on SecretStoreLockedException catch (e) {
      return _error(e.message, status: 423);
    } catch (e) {
      return _error(e.toString(), status: 400);
    }
    return _json({'ok': true});
  });

  router.get('/api/services/<id|.*>/buffer', (Request _, String id) {
    final buffer = sm.bufferedOutput(id);
    return _json({'chunks': buffer});
  });

  router.get('/api/mcp', (Request _) {
    return _json({
      'state': mcp.state.toJson(),
      'config': wsm.workspace?.mcpConfig?.toJson(),
    });
  });

  router.post('/api/mcp/start', (Request req) async {
    final ws = wsm.workspace;
    if (ws == null) return _error('No workspace open', status: 409);
    final raw = await req.readAsString();
    final body = raw.isEmpty
        ? <String, dynamic>{}
        : (jsonDecode(raw) as Map<String, dynamic>? ?? {});
    final config = McpConfig(
      enabled: true,
      port: (body['port'] as int?) ?? ws.mcpConfig?.port ?? 6891,
      token: (body['token'] as String?) ?? ws.mcpConfig?.token,
    );
    await wsm.saveWorkspace(ws.copyWith(mcpConfig: config));
    await mcp.start(config);
    return _json(mcp.state.toJson());
  });

  router.post('/api/mcp/stop', (Request _) async {
    await mcp.stop();
    final ws = wsm.workspace;
    if (ws != null && ws.mcpConfig != null) {
      await wsm.saveWorkspace(
        ws.copyWith(mcpConfig: ws.mcpConfig!.copyWith(enabled: false)),
      );
    }
    return _json(mcp.state.toJson());
  });

  router.get('/ws/services/<id|.*>', (Request req, String id) {
    final handler = webSocketHandler((WebSocketChannel ws, _) {
      _handleServiceSocket(ws, id, sm);
    });
    return handler(req);
  });

  router.get('/ws/state', (Request req) {
    final handler = webSocketHandler((WebSocketChannel ws, _) {
      _handleStateSocket(ws, sm, wsm, mcp, secretStore);
    });
    return handler(req);
  });

  return router;
}

void _handleServiceSocket(WebSocketChannel ws, String serviceId, ServiceManager sm) {
  ws.sink.add(jsonEncode({'type': 'snapshot', 'chunks': sm.bufferedOutput(serviceId)}));

  final outSub = sm.outputStream(serviceId).listen(
    (chunk) => ws.sink.add(jsonEncode({'type': 'output', 'chunk': chunk})),
  );

  final stateSub = sm.stateChanges
      .where((s) => s.serviceId == serviceId)
      .listen((s) => ws.sink.add(jsonEncode({'type': 'state', 'state': s.toJson()})));

  ws.stream.listen(
    (data) {
      if (data is! String) return;
      try {
        final msg = jsonDecode(data) as Map<String, dynamic>;
        switch (msg['type']) {
          case 'stdin':
            sm.writeStdin(serviceId, msg['data'] as String);
            break;
          case 'stop':
            sm.stopService(serviceId).ignore();
            break;
          case 'start':
            sm.startService(serviceId, commandName: msg['command'] as String?).ignore();
            break;
        }
      } catch (e, st) {
        _log.warning('Bad WS message: $data', e, st);
      }
    },
    onDone: () {
      outSub.cancel();
      stateSub.cancel();
    },
    onError: (_) {
      outSub.cancel();
      stateSub.cancel();
    },
  );
}

void _handleStateSocket(
  WebSocketChannel ws,
  ServiceManager sm,
  WorkspaceManager wsm,
  McpManager mcp,
  SecretStore secretStore,
) {
  ws.sink.add(jsonEncode({
    'type': 'snapshot',
    'states': sm.states.map((k, v) => MapEntry(k, v.toJson())),
    'mcp': mcp.state.toJson(),
    'secret-store': {'status': secretStore.status.name},
  }));

  final stateSub = sm.stateChanges.listen(
    (s) => ws.sink.add(jsonEncode({'type': 'state', 'state': s.toJson()})),
  );
  final wsSub = wsm.changes.listen(
    (_) => ws.sink.add(jsonEncode({'type': 'workspace-changed'})),
  );
  final mcpSub = mcp.changes.listen(
    (s) => ws.sink.add(jsonEncode({'type': 'mcp', 'mcp': s.toJson()})),
  );
  final storeSub = secretStore.changes.listen(
    (s) => ws.sink.add(jsonEncode({
      'type': 'secret-store',
      'secret-store': {'status': s.name},
    })),
  );

  ws.stream.listen(
    (_) {},
    onDone: () {
      stateSub.cancel();
      wsSub.cancel();
      mcpSub.cancel();
      storeSub.cancel();
    },
  );
}

Handler addCors(Handler inner) {
  return (Request request) async {
    if (request.method == 'OPTIONS') {
      return Response.ok('', headers: _corsHeaders);
    }
    final response = await inner(request);
    return response.change(headers: {...response.headers, ..._corsHeaders});
  };
}

const _corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-methods': 'GET,POST,PUT,DELETE,OPTIONS',
  'access-control-allow-headers': 'content-type',
};

Handler staticFallback(Handler primary, Handler fallback) {
  return (Request req) async {
    final response = await primary(req);
    if (response.statusCode == 404) {
      return fallback(req);
    }
    return response;
  };
}

bool isLoopback(InternetAddress addr) =>
    addr.isLoopback || addr.address == '127.0.0.1' || addr.address == '::1';


