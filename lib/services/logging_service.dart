import 'dart:io';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class LoggingService {
  static late File _logFile;
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;

    final dir = await getApplicationSupportDirectory();
    _logFile = File(p.join(dir.path, 'limousine.log'));

    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen((record) {
      final msg = '${record.time}: ${record.level.name}: ${record.loggerName}: ${record.message}';
      final fullMsg = record.error != null
          ? '$msg\n${record.error}\n${record.stackTrace}'
          : msg;

      stderr.writeln(fullMsg);
      _logFile.writeAsStringSync('$fullMsg\n', mode: FileMode.append);
    });

    _initialized = true;
    Logger('LoggingService').info('Logging initialized to ${_logFile.path}');
  }

  static String get logFilePath => _logFile.path;
}
