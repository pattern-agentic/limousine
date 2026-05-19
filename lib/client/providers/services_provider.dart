import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../../core/dto.dart';
import '../api_client.dart';
import 'api_provider.dart';

final serviceStatesProvider =
    NotifierProvider<ServiceStatesNotifier, Map<String, ServiceStateDto>>(
      ServiceStatesNotifier.new,
    );

class ServiceStatesNotifier extends Notifier<Map<String, ServiceStateDto>> {
  WebSocketChannel? _socket;

  @override
  Map<String, ServiceStateDto> build() {
    final api = ref.watch(apiClientProvider);
    ref.onDispose(() {
      _socket?.sink.close();
      _socket = null;
    });
    _connect(api);
    _hydrate(api);
    return {};
  }

  Future<void> _hydrate(ApiClient api) async {
    try {
      final initial = await api.getServiceStates();
      state = {...initial};
    } catch (_) {}
  }

  void _connect(ApiClient api) {
    _socket = api.openStateSocket();
    _socket!.stream.listen(
      (data) {
        final msg = jsonDecode(data as String) as Map<String, dynamic>;
        switch (msg['type']) {
          case 'snapshot':
            final states = msg['states'] as Map<String, dynamic>;
            state = {
              for (final entry in states.entries)
                entry.key: ServiceStateDto.fromJson(
                    entry.value as Map<String, dynamic>),
            };
            break;
          case 'state':
            final dto = ServiceStateDto.fromJson(
                msg['state'] as Map<String, dynamic>);
            state = {...state, dto.serviceId: dto};
            break;
        }
      },
      onError: (_) {},
    );
  }

  Future<void> start(String serviceId, {String? command}) =>
      ref.read(apiClientProvider).startService(serviceId, command: command);

  Future<void> stop(String serviceId) =>
      ref.read(apiClientProvider).stopService(serviceId);

  Future<void> killOrphan(String serviceId) =>
      ref.read(apiClientProvider).killOrphan(serviceId);
}
