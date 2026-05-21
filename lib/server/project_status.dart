import 'package:path/path.dart' as p;
import '../core/dto.dart';
import 'env.dart';
import 'git.dart';
import 'workspace_manager.dart';

/// Combines git state (branch/sha/dirty/behind-upstream/behind-main) with
/// per-module env+secrets file drift. Used by both the HTTP API and the MCP
/// server so they return consistent shapes. All operations are local-file +
/// `git` CLI; no extra processes spawned.
class ProjectStatus {
  /// Populate [status] with per-module config deltas computed from the
  /// project's modules. Cheap — just file reads. Returns the input if the
  /// project has no `limousine.proj` loaded.
  static Future<GitStatusDto> withConfigDeltas(
    GitStatusDto status,
    LoadedProjectDto loaded,
  ) async {
    final data = loaded.projectData;
    if (data == null) return status;

    final deltas = <ConfigDeltaDto>[];
    for (final module in data.modules) {
      final cfg = module.config;
      // Modules that didn't declare a `config:` block in limousine.proj have
      // opted out of env management — don't compare against the defaults.
      if (!cfg.declared) continue;
      final envActive = p.join(loaded.resolvedPath, cfg.activeEnvFile);
      final envSource = p.join(loaded.resolvedPath, cfg.sourceEnvFile);
      final secActive = p.join(loaded.resolvedPath, cfg.activeSecretsEnvFile);
      final secSource = p.join(loaded.resolvedPath, cfg.sourceSecretsFile);

      final envCmp = await Env.compareEnvFiles(envActive, envSource);
      final secCmp = await Env.compareEnvFiles(secActive, secSource);

      // The active secrets file is sops-encrypted dotenv on disk. Its body
      // contains the real secret keys AND sops's own metadata keys (sops_mac,
      // sops_version, sops_age__list_0__map_*, sops_lastmodified, …). Those
      // metadata keys aren't in the source template; without filtering them
      // they'd surface as "extra in active" and confuse the drift badge.
      // We strip them here rather than invoking `sops -d` so the delta can
      // be computed without the age key being loaded.
      bool isSopsMeta(String k) => k.startsWith('sops_');
      final secActiveKeys =
          secCmp.activeKeys.where((k) => !isSopsMeta(k)).toSet();
      final secSourceKeys = secCmp.sourceKeys;
      final secMissing = secSourceKeys.difference(secActiveKeys).length;
      final secExtra = secActiveKeys.difference(secSourceKeys).length;

      deltas.add(ConfigDeltaDto(
        module: module.name,
        envActiveExists: envCmp.activeExists,
        envSourceExists: envCmp.sourceExists,
        envMissingInActive: envCmp.missingInActive.length,
        envExtraInActive: envCmp.extraInActive.length,
        secretsActiveExists: secCmp.activeExists,
        secretsSourceExists: secCmp.sourceExists,
        secretsMissingInActive: secMissing,
        secretsExtraInActive: secExtra,
      ));
    }
    return GitStatusDto(
      project: status.project,
      exists: status.exists,
      branch: status.branch,
      shortSha: status.shortSha,
      subject: status.subject,
      dirtyFiles: status.dirtyFiles,
      upstream: status.upstream,
      behindUpstream: status.behindUpstream,
      aheadUpstream: status.aheadUpstream,
      mainBranch: status.mainBranch,
      behindMain: status.behindMain,
      lastFetched: status.lastFetched,
      error: status.error,
      configDeltas: deltas,
    );
  }

  /// One-shot read for a single project. Local-only — call [refresh] first
  /// if you need fresh upstream comparisons.
  static Future<GitStatusDto> read(
    String name,
    LoadedProjectDto loaded,
  ) async {
    final git = await Git.status(name, loaded.resolvedPath);
    return withConfigDeltas(git, loaded);
  }

  /// Refresh = `git fetch --prune` for one project, then read.
  static Future<GitStatusDto> refresh(
    String name,
    LoadedProjectDto loaded,
  ) async {
    final git = await Git.refresh(name, loaded.resolvedPath);
    return withConfigDeltas(git, loaded);
  }

  /// Bulk read for every project the workspace knows about. Parallel fan-out;
  /// failures land as the per-project `error` field, not exceptions. Skips
  /// missing-on-disk projects with a brief stub entry.
  static Future<List<Map<String, dynamic>>> readAll(
    WorkspaceManager wsm,
  ) async {
    final entries = wsm.projects.entries.toList();
    final futures = entries.map((entry) async {
      final name = entry.key;
      final loaded = entry.value;
      if (!loaded.existsOnDisk) {
        return _notClonedSummary(name, loaded);
      }
      try {
        final dto = await read(name, loaded);
        return _toAgentSummary(dto, loaded);
      } catch (e) {
        return {
          'name': name,
          'existsOnDisk': true,
          'path': loaded.resolvedPath,
          'error': e.toString(),
        };
      }
    });
    return Future.wait(futures);
  }

  static Map<String, dynamic> _notClonedSummary(
    String name,
    LoadedProjectDto loaded,
  ) =>
      {
        'name': name,
        'existsOnDisk': false,
        'path': loaded.resolvedPath,
        if (loaded.gitRepoUrl != null) 'gitRepoUrl': loaded.gitRepoUrl,
        'note': 'Not cloned. Use the dashboard "Clone" button on the project '
            'card, or `git clone ${loaded.gitRepoUrl ?? "<repo-url>"} '
            '${loaded.resolvedPath}` from a terminal.',
      };

  /// Agent-friendly flattening: compact, no nulls, with a derived
  /// `summary` line per project for quick scanning. The full DTO is also
  /// embedded under `details` for programmatic consumers.
  static Map<String, dynamic> _toAgentSummary(
    GitStatusDto s,
    LoadedProjectDto loaded,
  ) {
    final flags = <String>[];
    if (s.dirtyCode > 0) flags.add('${s.dirtyCode} code dirty');
    if (s.dirtyLock > 0) flags.add('${s.dirtyLock} lock dirty');
    if (s.upstream == null) flags.add('no upstream');
    if ((s.behindUpstream ?? 0) > 0) flags.add('↓${s.behindUpstream} upstream');
    if ((s.aheadUpstream ?? 0) > 0) flags.add('↑${s.aheadUpstream} upstream');
    if ((s.behindMain ?? 0) > 0) {
      flags.add('↓${s.behindMain} ${s.mainBranch ?? "main"}');
    }
    final driftedModules = s.configDeltas.where((d) => d.hasAny).toList();
    if (driftedModules.isNotEmpty) {
      final names = driftedModules.map((d) => d.module).join(', ');
      flags.add('config drift: $names');
    }
    final summary = flags.isEmpty
        ? '${s.branch ?? "?"} @ ${s.shortSha ?? "?"} — clean'
        : '${s.branch ?? "?"} @ ${s.shortSha ?? "?"} — ${flags.join("; ")}';

    return {
      'name': s.project,
      'existsOnDisk': true,
      'path': loaded.resolvedPath,
      'summary': summary,
      'branch': s.branch,
      'shortSha': s.shortSha,
      if (s.subject != null) 'lastCommit': s.subject,
      'dirty': {
        'total': s.dirty,
        'code': s.dirtyCode,
        'lock': s.dirtyLock,
        'files': s.dirtyFiles.map((f) => f.toJson()).toList(),
      },
      if (s.upstream != null) 'upstream': s.upstream,
      if (s.behindUpstream != null) 'behindUpstream': s.behindUpstream,
      if (s.aheadUpstream != null) 'aheadUpstream': s.aheadUpstream,
      if (s.mainBranch != null) 'mainBranch': s.mainBranch,
      if (s.behindMain != null) 'behindMain': s.behindMain,
      if (s.lastFetched != null)
        'lastFetched': s.lastFetched!.toIso8601String(),
      'configDeltas': [
        for (final d in s.configDeltas)
          {
            'module': d.module,
            'envDrift': d.hasEnvDelta,
            'secretsDrift': d.hasSecretsDelta,
            if (d.envMissingInActive > 0)
              'envMissingInActive': d.envMissingInActive,
            if (d.envExtraInActive > 0) 'envExtraInActive': d.envExtraInActive,
            if (d.secretsMissingInActive > 0)
              'secretsMissingInActive': d.secretsMissingInActive,
            if (d.secretsExtraInActive > 0)
              'secretsExtraInActive': d.secretsExtraInActive,
          },
      ],
      if (s.error != null) 'error': s.error,
    };
  }

  /// Public flattener for the per-project agent summary. Used by the MCP
  /// `git_fetch` tool's response (which already has a fresh DTO in hand).
  static Map<String, dynamic> toAgentSummary(
    GitStatusDto s,
    LoadedProjectDto loaded,
  ) =>
      s.exists ? _toAgentSummary(s, loaded) : _notClonedSummary(s.project, loaded);
}
