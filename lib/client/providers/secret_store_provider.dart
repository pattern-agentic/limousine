import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'api_provider.dart';

enum SecretStoreStatus { missingPassword, verified, newStamp, mismatch, unknown }

SecretStoreStatus _parse(String? name) {
  return switch (name) {
    'missingPassword' => SecretStoreStatus.missingPassword,
    'verified' => SecretStoreStatus.verified,
    'newStamp' => SecretStoreStatus.newStamp,
    'mismatch' => SecretStoreStatus.mismatch,
    _ => SecretStoreStatus.unknown,
  };
}

final secretStoreProvider =
    NotifierProvider<SecretStoreNotifier, SecretStoreStatus>(
  SecretStoreNotifier.new,
);

class SecretStoreNotifier extends Notifier<SecretStoreStatus> {
  @override
  SecretStoreStatus build() {
    ref.watch(apiClientProvider);
    _hydrate();
    return SecretStoreStatus.unknown;
  }

  Future<void> _hydrate() async {
    final base = ref.read(apiBaseUriProvider);
    try {
      final r = await http.get(base.resolve('api/secret-store/status'));
      if (r.statusCode == 200) {
        final json = jsonDecode(r.body) as Map<String, dynamic>;
        state = _parse(json['status'] as String?);
      }
    } catch (_) {}
  }

  void applyFromSocket(Map<String, dynamic> json) {
    state = _parse(json['status'] as String?);
  }
}
