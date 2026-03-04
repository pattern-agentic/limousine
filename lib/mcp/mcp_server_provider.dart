import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart' as logging;
import 'package:mcp_dart/mcp_dart.dart';
import 'mcp_config.dart';
import 'mcp_tools.dart';

final _log = logging.Logger('McpServer');

enum McpServerStatus { stopped, starting, running, error }

class McpServerState {
  final McpServerStatus status;
  final int port;
  final String? error;

  const McpServerState({
    this.status = McpServerStatus.stopped,
    this.port = 6891,
    this.error,
  });

  McpServerState copyWith({McpServerStatus? status, int? port, String? error, bool clearError = false}) {
    return McpServerState(
      status: status ?? this.status,
      port: port ?? this.port,
      error: clearError ? null : (error ?? this.error),
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

  Future<void> start(McpConfig config) async {
    if (state.status == McpServerStatus.running) return;

    state = state.copyWith(status: McpServerStatus.starting, port: config.port, clearError: true);

    try {
      _server = StreamableMcpServer(
        serverFactory: (sessionId) {
          final server = McpServer(
            Implementation(name: 'limousine', version: '0.1.0'),
            options: McpServerOptions(
              capabilities: ServerCapabilities(
                tools: ServerCapabilitiesTools(),
              ),
            ),
          );

          registerTools(server, ref);

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
