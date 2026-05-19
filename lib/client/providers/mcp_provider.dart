import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'api_provider.dart';

enum McpStatus { stopped, starting, running, error, unknown }

class McpClientState {
  final McpStatus status;
  final int port;
  final String? error;

  const McpClientState({
    this.status = McpStatus.unknown,
    this.port = 6891,
    this.error,
  });

  factory McpClientState.fromJson(Map<String, dynamic> json) {
    final raw = json['status'] as String?;
    final status = McpStatus.values.firstWhere(
      (s) => s.name == raw,
      orElse: () => McpStatus.unknown,
    );
    return McpClientState(
      status: status,
      port: json['port'] ?? 6891,
      error: json['error'],
    );
  }
}

final mcpProvider = NotifierProvider<McpNotifier, McpClientState>(McpNotifier.new);

class McpNotifier extends Notifier<McpClientState> {
  @override
  McpClientState build() {
    final api = ref.watch(apiClientProvider);
    // Hydrate via REST. Live updates flow through serviceStatesProvider's WS
    // (which also receives mcp pushes); for simplicity here we also expose
    // direct fetch/start/stop and let the state socket call refresh().
    _hydrate(api);
    return const McpClientState();
  }

  Future<void> _hydrate(dynamic api) async {
    try {
      final r = await http.get(
        Uri.parse('${ref.read(apiBaseUriProvider)}api/mcp'),
      );
      if (r.statusCode == 200) {
        final json = jsonDecode(r.body) as Map<String, dynamic>;
        state = McpClientState.fromJson(json['state'] as Map<String, dynamic>);
      }
    } catch (_) {}
  }

  void applyFromSocket(Map<String, dynamic> json) {
    state = McpClientState.fromJson(json);
  }

  Future<void> start({int? port, String? token}) async {
    final r = await http.post(
      Uri.parse('${ref.read(apiBaseUriProvider)}api/mcp/start'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({
        if (port != null) 'port': port,
        if (token != null && token.isNotEmpty) 'token': token,
      }),
    );
    if (r.statusCode >= 400) {
      state = McpClientState(status: McpStatus.error, port: state.port, error: r.body);
      return;
    }
    state = McpClientState.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<void> stop() async {
    final r = await http.post(
      Uri.parse('${ref.read(apiBaseUriProvider)}api/mcp/stop'),
    );
    if (r.statusCode >= 400) {
      state = McpClientState(status: McpStatus.error, port: state.port, error: r.body);
      return;
    }
    state = McpClientState.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }
}
