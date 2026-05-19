import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart';
import 'api_provider.dart';

class ServiceTerminal {
  final Terminal terminal;
  final WebSocketChannel socket;

  ServiceTerminal({required this.terminal, required this.socket});
}

final serviceTerminalProvider =
    Provider.family<ServiceTerminal, String>((ref, serviceId) {
  final api = ref.watch(apiClientProvider);
  final terminal = Terminal(maxLines: 5000);
  final socket = api.openServiceSocket(serviceId);

  socket.stream.listen(
    (data) {
      final msg = jsonDecode(data as String) as Map<String, dynamic>;
      switch (msg['type']) {
        case 'snapshot':
          final chunks = (msg['chunks'] as List).cast<String>();
          for (final c in chunks) {
            terminal.write(c);
          }
          break;
        case 'output':
          terminal.write(msg['chunk'] as String);
          break;
        case 'closed':
          break;
      }
    },
    onError: (_) {},
  );

  terminal.onOutput = (data) {
    socket.sink.add(jsonEncode({'type': 'stdin', 'data': data}));
  };

  ref.onDispose(() {
    socket.sink.close();
  });

  return ServiceTerminal(terminal: terminal, socket: socket);
});
