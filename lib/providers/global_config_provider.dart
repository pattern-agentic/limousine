import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/workspace.dart';
import '../services/storage_service.dart';

final globalConfigProvider =
    AsyncNotifierProvider<GlobalConfigNotifier, GlobalConfig>(
      GlobalConfigNotifier.new,
    );

class GlobalConfigNotifier extends AsyncNotifier<GlobalConfig> {
  @override
  Future<GlobalConfig> build() async {
    return StorageService.loadGlobalConfig();
  }

  Future<void> addWorkspace(String path) async {
    final config = await future;
    if (config.workspacePaths.contains(path)) return;
    final updated = config.copyWith(
      workspacePaths: [...config.workspacePaths, path],
    );
    await StorageService.saveGlobalConfig(updated);
    state = AsyncData(updated);
  }

  Future<void> removeWorkspace(String path) async {
    final config = await future;
    final updated = config.copyWith(
      workspacePaths: config.workspacePaths.where((p) => p != path).toList(),
    );
    await StorageService.saveGlobalConfig(updated);
    state = AsyncData(updated);
  }
}
