import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'clipboard_stub.dart' if (dart.library.html) 'clipboard_web.dart'
    as platform;

Future<void> copyToClipboard(String text) async {
  if (kIsWeb) {
    platform.webCopy(text);
    return;
  }
  await Clipboard.setData(ClipboardData(text: text));
}
