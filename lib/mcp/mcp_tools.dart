import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mcp_dart/mcp_dart.dart';
import '../models/service_state.dart';
import '../providers/workspace_provider.dart';
import '../providers/services_provider.dart';

void registerTools(McpServer server, Ref ref) {
  server.registerTool(
    'list_services',
    description: 'List all services with their current status',
    callback: (args, extra) async {
      final services = ref.read(allServicesProvider);
      final states = ref.read(serviceStatesProvider);

      final result = services.map((s) {
        final state = states[s.id];
        return {
          'id': s.id,
          'project': s.projectName,
          'module': s.moduleName,
          'service': s.serviceName,
          'status': (state?.status ?? ProcessStatus.stopped).name,
          'pid': state?.pid,
          'commands': s.service.commands.keys.toList(),
          if (state?.startTime != null)
            'startTime': state!.startTime!.toIso8601String(),
        };
      }).toList();

      return CallToolResult(
        content: [TextContent(text: const JsonEncoder.withIndent('  ').convert(result))],
      );
    },
  );

  server.registerTool(
    'start_service',
    description: 'Start a service by ID. Optionally specify a command name (must be one of the service\'s defined commands).',
    inputSchema: ToolInputSchema(
      properties: {
        'serviceId': JsonSchema.string(description: 'Service ID in format "module/service"'),
        'command': JsonSchema.string(description: 'Command name key (e.g. "start", "run"). Must match a defined command. Defaults to first available.'),
      },
      required: ['serviceId'],
    ),
    callback: (args, extra) async {
      final serviceId = args['serviceId'] as String;
      final commandName = args['command'] as String?;

      final services = ref.read(allServicesProvider);
      final info = services.where((s) => s.id == serviceId).firstOrNull;
      if (info == null) {
        return CallToolResult(
          content: [TextContent(text: 'Service not found: $serviceId')],
          isError: true,
        );
      }

      if (info.service.commands.isEmpty) {
        return CallToolResult(
          content: [TextContent(text: 'Service has no commands defined')],
          isError: true,
        );
      }

      final states = ref.read(serviceStatesProvider);
      final state = states[serviceId];
      if (state?.status == ProcessStatus.running) {
        return CallToolResult(
          content: [TextContent(text: 'Service is already running')],
          isError: true,
        );
      }

      String resolvedCommand;
      if (commandName != null) {
        final cmd = info.service.commands[commandName];
        if (cmd == null) {
          return CallToolResult(
            content: [TextContent(text: 'Unknown command "$commandName". Available: ${info.service.commands.keys.join(', ')}')],
            isError: true,
          );
        }
        resolvedCommand = cmd;
      } else {
        resolvedCommand = info.service.commands.values.first;
      }

      await ref.read(serviceStatesProvider.notifier).startService(info, resolvedCommand);

      return CallToolResult(
        content: [TextContent(text: 'Started service $serviceId')],
      );
    },
  );

  server.registerTool(
    'stop_service',
    description: 'Stop a running service by ID',
    inputSchema: ToolInputSchema(
      properties: {
        'serviceId': JsonSchema.string(description: 'Service ID in format "module/service"'),
      },
      required: ['serviceId'],
    ),
    callback: (args, extra) async {
      final serviceId = args['serviceId'] as String;

      final states = ref.read(serviceStatesProvider);
      final state = states[serviceId];
      if (state == null || state.status != ProcessStatus.running) {
        return CallToolResult(
          content: [TextContent(text: 'Service is not running: $serviceId')],
          isError: true,
        );
      }

      await ref.read(serviceStatesProvider.notifier).stopService(serviceId);

      return CallToolResult(
        content: [TextContent(text: 'Stop signal sent to $serviceId')],
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
      final serviceId = args['serviceId'] as String;
      final requestedLines = (args['lines'] as int?) ?? 50;
      final maxLines = requestedLines.clamp(1, 500);

      final states = ref.read(serviceStatesProvider);
      final state = states[serviceId];
      if (state == null) {
        return CallToolResult(
          content: [TextContent(text: 'Service not found: $serviceId')],
          isError: true,
        );
      }

      final buffer = state.terminal.buffer;
      final totalLines = buffer.lines.length;
      final startLine = (totalLines - maxLines).clamp(0, totalLines);

      final lines = <String>[];
      for (var i = startLine; i < totalLines; i++) {
        final line = buffer.lines[i];
        final text = line.getText();
        lines.add(text.trimRight());
      }

      while (lines.isNotEmpty && lines.last.isEmpty) {
        lines.removeLast();
      }

      return CallToolResult(
        content: [TextContent(text: lines.join('\n'))],
      );
    },
  );

  server.registerTool(
    'get_project_info',
    description: 'Get project info including the agent guide with service orchestration instructions (startup order, dependencies, tips)',
    inputSchema: ToolInputSchema(
      properties: {
        'projectName': JsonSchema.string(description: 'Project name. Omit to get info for all projects.'),
      },
    ),
    callback: (args, extra) async {
      final projectName = args['projectName'] as String?;
      final projects = await ref.read(projectsProvider.future);

      final entries = projectName != null
          ? {if (projects.containsKey(projectName)) projectName: projects[projectName]!}
          : projects;

      if (entries.isEmpty) {
        return CallToolResult(
          content: [TextContent(text: projectName != null ? 'Project not found: $projectName' : 'No projects loaded')],
          isError: projectName != null,
        );
      }

      final result = entries.map((name, p) {
        final data = p.projectData;
        return MapEntry(name, {
          'path': p.resolvedPath,
          'existsOnDisk': p.existsOnDisk,
          if (data?.agentGuide != null) 'agentGuide': data!.agentGuide,
          if (data != null) 'modules': data.modules.map((m) => {
            'name': m.name,
            'services': m.services.map((k, v) => MapEntry(k, {
              'commands': v.commands.keys.toList(),
            })),
          }).toList(),
        });
      });

      return CallToolResult(
        content: [TextContent(text: const JsonEncoder.withIndent('  ').convert(result))],
      );
    },
  );
}
