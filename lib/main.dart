import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'client/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((r) {
    debugPrint('${r.time} ${r.level.name} ${r.loggerName}: ${r.message}');
  });
  runApp(const ProviderScope(child: LimousineApp()));
}
