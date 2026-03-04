import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart' as logging;
import 'package:mcp_dart/mcp_dart.dart';
import 'mcp_config.dart';
import 'mcp_tools.dart';

final _log = logging.Logger('McpServer');

enum McpServerStatus { stopped, starting, running, error }

class McpLogEntry {
  final DateTime timestamp;
  final String direction;
  final String method;
  final String body;

  McpLogEntry({required this.direction, required this.method, required this.body})
      : timestamp = DateTime.now();
}

class McpServerState {
  final McpServerStatus status;
  final int port;
  final String? error;
  final bool verboseLogging;
  final List<McpLogEntry> logs;

  const McpServerState({
    this.status = McpServerStatus.stopped,
    this.port = 6891,
    this.error,
    this.verboseLogging = false,
    this.logs = const [],
  });

  McpServerState copyWith({
    McpServerStatus? status,
    int? port,
    String? error,
    bool clearError = false,
    bool? verboseLogging,
    List<McpLogEntry>? logs,
  }) {
    return McpServerState(
      status: status ?? this.status,
      port: port ?? this.port,
      error: clearError ? null : (error ?? this.error),
      verboseLogging: verboseLogging ?? this.verboseLogging,
      logs: logs ?? this.logs,
    );
  }
}

final mcpServerProvider = NotifierProvider<McpServerNotifier, McpServerState>(
  McpServerNotifier.new,
);

class McpServerNotifier extends Notifier<McpServerState> {
  StreamableMcpServer? _server;

  @override
  McpServerState build() {
    ref.onDispose(() async {
      await _server?.stop();
      _server = null;
    });
    return const McpServerState();
  }

  void _addLog(String direction, String method, String body) {
    if (!state.verboseLogging) return;
    final entry = McpLogEntry(direction: direction, method: method, body: body);
    final logs = [...state.logs, entry];
    final trimmed = logs.length > 200 ? logs.sublist(logs.length - 200) : logs;
    state = state.copyWith(logs: trimmed);
  }

  void setVerboseLogging(bool enabled) {
    state = state.copyWith(verboseLogging: enabled);
  }

  void clearLogs() {
    state = state.copyWith(logs: []);
  }

  Future<void> start(McpConfig config) async {
    if (state.status == McpServerStatus.running) return;

    state = state.copyWith(status: McpServerStatus.starting, port: config.port, clearError: true);

    try {
      _server = StreamableMcpServer(
        serverFactory: (sessionId) {
          _log.info('MCP session created: $sessionId');
          _addLog('SYS', 'SESSION', 'Created: $sessionId');

          final server = McpServer(
            Implementation(name: 'limousine', version: '0.1.0'),
            options: McpServerOptions(
              capabilities: ServerCapabilities(
                tools: ServerCapabilitiesTools(),
              ),
            ),
          );

          server.onError = (e) {
            _log.severe('MCP server error in session $sessionId', e);
            _addLog('ERR', 'SERVER', e.toString());
          };

          registerTools(server, ref, onToolCall: (name, args) {
            _log.info('MCP tool call: $name');
            _addLog('REQ', 'tools/call', '$name($args)');
          });

          return server;
        },
        host: 'localhost',
        port: config.port,
        enableDnsRebindingProtection: false,
        eventStore: InMemoryEventStore(),
      );

      await _server!.start();
      state = state.copyWith(status: McpServerStatus.running);
      _log.info('MCP server started on port ${config.port}');
    } catch (e) {
      _log.severe('Failed to start MCP server', e);
      state = state.copyWith(status: McpServerStatus.error, error: e.toString());
      _server = null;
    }
  }

  Future<void> stop() async {
    _log.info('MCP server stopping...');
    try {
      await _server?.stop();
    } catch (e) {
      _log.warning('Error stopping MCP server', e);
    }
    _server = null;
    state = state.copyWith(status: McpServerStatus.stopped, clearError: true);
    _log.info('MCP server stopped');
  }
}
