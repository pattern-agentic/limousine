import 'dart:async';
import 'dart:convert';
import 'package:logging/logging.dart' as logging;
import 'package:mcp_dart/mcp_dart.dart';
import '../core/dto.dart';
import '../core/workspace.dart';
import 'project_status.dart';
import 'service_manager.dart';
import 'workspace_manager.dart';

final _log = logging.Logger('Mcp');

enum McpStatus { stopped, starting, running, error }

class McpState {
  final McpStatus status;
  final int port;
  final String? error;

  const McpState({
    this.status = McpStatus.stopped,
    this.port = 6891,
    this.error,
  });

  Map<String, dynamic> toJson() => {
    'status': status.name,
    'port': port,
    if (error != null) 'error': error,
  };
}

class McpManager {
  final WorkspaceManager workspaceManager;
  final ServiceManager serviceManager;

  StreamableMcpServer? _server;
  McpState _state = const McpState();
  final StreamController<McpState> _changes =
      StreamController<McpState>.broadcast();

  McpManager(this.workspaceManager, this.serviceManager);

  McpState get state => _state;
  Stream<McpState> get changes => _changes.stream;

  void _set(McpState s) {
    _state = s;
    _changes.add(s);
  }

  Future<void> start(McpConfig config) async {
    if (_state.status == McpStatus.running || _state.status == McpStatus.starting) {
      return;
    }
    _set(McpState(status: McpStatus.starting, port: config.port));

    try {
      _server = StreamableMcpServer(
        serverFactory: (_) {
          final s = McpServer(
            Implementation(name: 'limousine', version: '0.2.0'),
            options: McpServerOptions(
              capabilities: ServerCapabilities(tools: ServerCapabilitiesTools()),
            ),
          );
          _registerTools(s);
          return s;
        },
        host: 'localhost',
        port: config.port,
        enableDnsRebindingProtection: false,
        eventStore: InMemoryEventStore(),
      );
      await _server!.start();
      _set(McpState(status: McpStatus.running, port: config.port));
      _log.info('MCP server started on port ${config.port}');
    } catch (e, st) {
      _log.severe('Failed to start MCP server', e, st);
      _server = null;
      _set(McpState(status: McpStatus.error, port: config.port, error: e.toString()));
    }
  }

  Future<void> stop() async {
    try {
      await _server?.stop();
    } catch (e, st) {
      _log.warning('Error stopping MCP server', e, st);
    }
    _server = null;
    _set(McpState(status: McpStatus.stopped, port: _state.port));
    _log.info('MCP server stopped');
  }

  Future<void> dispose() async {
    await stop();
    await _changes.close();
  }

  void _registerTools(McpServer server) {
    server.registerTool(
      'list_services',
      description: 'List all services with their current status',
      callback: (args, extra) async {
        final services = workspaceManager.allServices();
        final states = serviceManager.states;
        final result = services.map((s) {
          final st = states[s.id];
          return {
            'id': s.id,
            'project': s.projectName,
            'module': s.moduleName,
            'service': s.serviceName,
            'status': (st?.status ?? ProcessStatus.stopped).name,
            'pid': st?.pid,
            'commands': s.service.commands.keys.toList(),
            if (st?.startTime != null) 'startTime': st!.startTime!.toIso8601String(),
          };
        }).toList();
        return CallToolResult(
          content: [TextContent(text: const JsonEncoder.withIndent('  ').convert(result))],
        );
      },
    );

    server.registerTool(
      'start_service',
      description:
          'Start a service by ID. Optionally specify a command name (must be one of the service\'s defined commands).',
      inputSchema: ToolInputSchema(
        properties: {
          'serviceId': JsonSchema.string(description: 'Service ID in format "module/service"'),
          'command': JsonSchema.string(
              description: 'Command name key (e.g. "start", "run"). Defaults to "run" if present, else first available.'),
        },
        required: ['serviceId'],
      ),
      callback: (args, extra) async {
        final id = args['serviceId'] as String;
        final command = args['command'] as String?;
        try {
          await serviceManager.startService(id, commandName: command);
          return CallToolResult(content: [TextContent(text: 'Started service $id')]);
        } catch (e) {
          return CallToolResult(content: [TextContent(text: e.toString())], isError: true);
        }
      },
    );

    server.registerTool(
      'stop_service',
      description:
          'Stop a running service by ID. Sends escalating signals (SIGINT → SIGTERM → SIGKILL), polling between each. Waits up to ~15s.',
      inputSchema: ToolInputSchema(
        properties: {
          'serviceId': JsonSchema.string(description: 'Service ID in format "module/service"'),
        },
        required: ['serviceId'],
      ),
      callback: (args, extra) async {
        final id = args['serviceId'] as String;
        final state = serviceManager.states[id];
        if (state == null || state.status != ProcessStatus.running) {
          return CallToolResult(
            content: [TextContent(text: 'Service is not running: $id')],
            isError: true,
          );
        }
        final stopped = await serviceManager.stopServiceEscalating(id);
        return CallToolResult(
          content: [TextContent(text: stopped ? 'Service $id stopped' : 'Service $id did not stop after ~15s')],
          isError: !stopped,
        );
      },
    );

    server.registerTool(
      'get_service_logs',
      description: 'Get recent terminal output for a service',
      inputSchema: ToolInputSchema(
        properties: {
          'serviceId': JsonSchema.string(description: 'Service ID in format "module/service"'),
          'lines': JsonSchema.integer(description: 'Number of lines to return (default 50, max 500)'),
        },
        required: ['serviceId'],
      ),
      callback: (args, extra) async {
        final id = args['serviceId'] as String;
        final requested = (args['lines'] as int?) ?? 50;
        final maxLines = requested.clamp(1, 500);
        final buffer = serviceManager.bufferedOutput(id);
        if (buffer.isEmpty && serviceManager.states[id] == null) {
          return CallToolResult(
            content: [TextContent(text: 'Service not found: $id')],
            isError: true,
          );
        }
        final text = buffer.join();
        final lines = const LineSplitter().convert(text);
        while (lines.isNotEmpty && lines.last.isEmpty) {
          lines.removeLast();
        }
        final start = (lines.length - maxLines).clamp(0, lines.length);
        return CallToolResult(
          content: [TextContent(text: lines.sublist(start).join('\n'))],
        );
      },
    );

    server.registerTool(
      'get_project_info',
      description:
          'Get project info including the agent guide with service orchestration instructions (startup order, dependencies, tips)',
      inputSchema: ToolInputSchema(
        properties: {
          'projectName': JsonSchema.string(description: 'Project name. Omit to get info for all projects.'),
        },
      ),
      callback: (args, extra) async {
        final name = args['projectName'] as String?;
        final all = workspaceManager.projects;
        final entries = name != null
            ? {if (all.containsKey(name)) name: all[name]!}
            : all;
        if (entries.isEmpty) {
          return CallToolResult(
            content: [TextContent(text: name != null ? 'Project not found: $name' : 'No projects loaded')],
            isError: name != null,
          );
        }
        final result = entries.map((k, p) {
          final data = p.projectData;
          return MapEntry(k, {
            'path': p.resolvedPath,
            'existsOnDisk': p.existsOnDisk,
            if (data?.agentGuide != null) 'agentGuide': data!.agentGuide,
            if (data != null)
              'modules': data.modules.map((m) => {
                'name': m.name,
                'services': m.services.map((sk, sv) => MapEntry(sk, {
                  'commands': sv.commands.keys.toList(),
                })),
              }).toList(),
          });
        });
        return CallToolResult(
          content: [TextContent(text: const JsonEncoder.withIndent('  ').convert(result))],
        );
      },
    );

    server.registerTool(
      'get_git_status',
      description:
          'Get a git + config-state snapshot for every project in the open '
          'workspace (or one project if `projectName` is provided). Reports: '
          'whether the project is cloned, current branch + commit, dirty '
          'files split into code vs lockfile counts, behind/ahead of upstream, '
          'behind the project\'s main branch, and per-module env/secrets '
          'drift (keys missing or extra in the dev\'s active files vs the '
          'committed template). Local-only — does not run `git fetch`. Call '
          '`git_fetch` first if you need fresh upstream comparisons.',
      inputSchema: ToolInputSchema(
        properties: {
          'projectName': JsonSchema.string(
              description:
                  'Project name. Omit to get status for every project.'),
        },
      ),
      callback: (args, extra) async {
        final filter = args['projectName'] as String?;
        try {
          final all = await ProjectStatus.readAll(workspaceManager);
          final filtered = filter == null
              ? all
              : all.where((m) => m['name'] == filter).toList();
          if (filter != null && filtered.isEmpty) {
            return CallToolResult(
              content: [TextContent(text: 'Project not found: $filter')],
              isError: true,
            );
          }
          return CallToolResult(
            content: [
              TextContent(
                  text: const JsonEncoder.withIndent('  ').convert(filtered)),
            ],
          );
        } catch (e) {
          return CallToolResult(
            content: [TextContent(text: 'Failed to read git status: $e')],
            isError: true,
          );
        }
      },
    );

    server.registerTool(
      'git_fetch',
      description:
          'Run `git fetch --prune` on one project (`projectName`) or every '
          'cloned project (no arg). Updates the upstream comparison; does '
          'not touch the working tree. Returns the refreshed status snapshot '
          'in the same shape as `get_git_status`.',
      inputSchema: ToolInputSchema(
        properties: {
          'projectName': JsonSchema.string(
              description:
                  'Project name. Omit to fetch every cloned project in parallel.'),
        },
      ),
      callback: (args, extra) async {
        final filter = args['projectName'] as String?;
        try {
          if (filter != null) {
            final loaded = workspaceManager.projects[filter];
            if (loaded == null) {
              return CallToolResult(
                content: [TextContent(text: 'Project not found: $filter')],
                isError: true,
              );
            }
            if (!loaded.existsOnDisk) {
              return CallToolResult(
                content: [
                  TextContent(text: 'Project $filter is not cloned; nothing to fetch'),
                ],
                isError: true,
              );
            }
            final dto = await ProjectStatus.refresh(filter, loaded);
            return CallToolResult(
              content: [
                TextContent(
                  text: const JsonEncoder.withIndent('  ')
                      .convert(ProjectStatus.toAgentSummary(dto, loaded)),
                ),
              ],
            );
          }
          // Fan-out fetch for every cloned project.
          final cloned = workspaceManager.projects.entries
              .where((e) => e.value.existsOnDisk)
              .toList();
          final results = await Future.wait(cloned.map((e) async {
            try {
              final dto = await ProjectStatus.refresh(e.key, e.value);
              return ProjectStatus.toAgentSummary(dto, e.value);
            } catch (err) {
              return {'name': e.key, 'error': err.toString()};
            }
          }));
          return CallToolResult(
            content: [
              TextContent(
                  text: const JsonEncoder.withIndent('  ').convert(results)),
            ],
          );
        } catch (e) {
          return CallToolResult(
            content: [TextContent(text: 'git fetch failed: $e')],
            isError: true,
          );
        }
      },
    );
  }
}
