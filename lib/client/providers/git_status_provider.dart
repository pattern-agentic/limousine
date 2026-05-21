import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/dto.dart';
import '../api_client.dart';
import 'api_provider.dart';

/// Per-project git status keyed by project name. `inFlight` tracks which
/// projects currently have a status / refresh / pull in progress so each
/// card can show its own spinner without blocking siblings. Cards trigger
/// their own loads via [load] on mount — no global auto-watch.
class GitStatusBundle {
  final Map<String, GitStatusDto> byProject;
  final Set<String> inFlight;
  const GitStatusBundle({required this.byProject, required this.inFlight});

  GitStatusBundle copyWith({
    Map<String, GitStatusDto>? byProject,
    Set<String>? inFlight,
  }) =>
      GitStatusBundle(
        byProject: byProject ?? this.byProject,
        inFlight: inFlight ?? this.inFlight,
      );

  static const empty = GitStatusBundle(byProject: {}, inFlight: {});
}

final gitStatusProvider =
    NotifierProvider<GitStatusNotifier, GitStatusBundle>(GitStatusNotifier.new);

class GitStatusNotifier extends Notifier<GitStatusBundle> {
  @override
  GitStatusBundle build() => GitStatusBundle.empty;

  ApiClient get _api => ref.read(apiClientProvider);

  void _setStatus(String name, GitStatusDto dto) {
    state = state.copyWith(
      byProject: {...state.byProject, name: dto},
      inFlight: {...state.inFlight}..remove(name),
    );
  }

  void _markInFlight(String name) {
    state = state.copyWith(inFlight: {...state.inFlight, name});
  }

  /// Local-only status load. Cheap; safe to call on every card mount.
  Future<void> load(String name) async {
    if (state.inFlight.contains(name)) return;
    _markInFlight(name);
    try {
      final dto = await _api.getGitStatus(name);
      _setStatus(name, dto);
    } catch (e) {
      _setStatus(
        name,
        GitStatusDto(project: name, exists: false, error: e.toString()),
      );
    }
  }

  /// `git fetch` for one repo, then update its row. Network op.
  Future<void> refresh(String name) async {
    if (state.inFlight.contains(name)) return;
    _markInFlight(name);
    try {
      final dto = await _api.refreshGitStatus(name);
      _setStatus(name, dto);
    } catch (e) {
      _setStatus(
        name,
        GitStatusDto(project: name, exists: false, error: e.toString()),
      );
    }
  }

  /// Fire `git fetch` in parallel across every project we already know about.
  /// Skips ones currently in-flight.
  Future<void> refreshAll() async {
    final names = state.byProject.keys
        .where((n) => !state.inFlight.contains(n))
        .toList();
    await Future.wait(names.map(refresh));
  }

  /// `git pull --ff-only`. Returns the recomputed status + result message.
  Future<GitPullResultDto> pull(String name) async {
    _markInFlight(name);
    try {
      final result = await _api.gitPull(name);
      _setStatus(name, result.status);
      return result;
    } catch (e) {
      _setStatus(
        name,
        GitStatusDto(project: name, exists: false, error: e.toString()),
      );
      rethrow;
    }
  }
}
