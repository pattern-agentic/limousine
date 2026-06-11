/// Build-time version stamp, populated by the Makefile via
/// `--dart-define=LIMOUSINE_VERSION=...` (extracted from pubspec.yaml).
/// Falls back to "dev" if the build was run without the define (e.g. ad-hoc
/// `flutter run`), so the UI never crashes — the corner label just reads
/// "vdev" in that case.
const kLimousineVersion =
    String.fromEnvironment('LIMOUSINE_VERSION', defaultValue: 'dev');
