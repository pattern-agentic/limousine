import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../api_client.dart';

final apiBaseUriProvider = Provider<Uri>((ref) {
  if (kIsWeb) {
    // Same origin as the page that served the Flutter web app.
    return Uri.base;
  }
  return Uri.parse('http://127.0.0.1:7891');
});

final apiClientProvider = Provider<ApiClient>((ref) {
  final client = ApiClient(baseUri: ref.watch(apiBaseUriProvider));
  ref.onDispose(client.close);
  return client;
});
