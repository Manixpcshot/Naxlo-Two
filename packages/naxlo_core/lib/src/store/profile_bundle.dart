import 'dart:convert';

import '../config/ranking_config.dart';
import '../config/runtime_settings.dart';
import '../json/json_utils.dart';
import '../models/profile.dart';
import '../models/server_node.dart';
import '../ranking/metrics.dart';
import '../ranking/sample_point.dart';
import '../ranking/selection.dart';

/// The whole on-disk state of the app, in one file, versioned.
///
/// One document (instead of scattered prefs) means: an export/import is a
/// single copy, a broken write can't half-migrate, and `git diff` of a test
/// fixture shows exactly what the ranker remembered. Writes go through
/// [encode] → atomic rename in `app/`.
class ProfileBundle {
  const ProfileBundle({
    this.schemaVersion = kSchemaVersion,
    this.profiles = const <Profile>[],
    this.activeProfileId = '',
    this.metricsByServer = const <String, ServerMetrics>{},
    this.selectionByProfile = const <String, SelectionState>{},
    this.recentSamplesByServer = const <String, List<SamplePoint>>{},
    this.settings = RuntimeSettings.defaults,
    this.ranking = RankingConfig.defaults,
    this.savedAtMs = 0,
  });

  /// Bump when the layout changes incompatibly; [fromJson] migrates older
  /// versions instead of discarding the file.
  static const int kSchemaVersion = 3;

  final int schemaVersion;
  final List<Profile> profiles;
  final String activeProfileId;

  /// Keyed by server id. Survives profile edits so history is not lost when a
  /// node is renamed.
  final Map<String, ServerMetrics> metricsByServer;
  final Map<String, SelectionState> selectionByProfile;

  /// Raw samples, kept short ([RankingConfig.maxSamplesKept]) and used for the
  /// sparkline and for re-scoring with new weights.
  final Map<String, List<SamplePoint>> recentSamplesByServer;
  final RuntimeSettings settings;
  final RankingConfig ranking;
  final int savedAtMs;

  Profile? get active {
    for (final p in profiles) {
      if (p.id == activeProfileId) return p;
    }
    return profiles.isEmpty ? null : profiles.first;
  }

  bool get hasProfiles => profiles.isNotEmpty;

  /// All nodes across all profiles — what the servers screen shows when no
  /// profile filter is active, and what the global probe round walks.
  List<ServerNode> get allServers => <ServerNode>[
        for (final p in profiles) ...p.servers,
      ];

  Map<String, ServerNode> get serverIndex {
    final out = <String, ServerNode>{};
    for (final p in profiles) {
      for (final s in p.servers) {
        out[s.id] = s;
      }
    }
    return out;
  }

  ProfileBundle copyWith({
    List<Profile>? profiles,
    String? activeProfileId,
    Map<String, ServerMetrics>? metricsByServer,
    Map<String, SelectionState>? selectionByProfile,
    Map<String, List<SamplePoint>>? recentSamplesByServer,
    RuntimeSettings? settings,
    RankingConfig? ranking,
    int? savedAtMs,
  }) {
    return ProfileBundle(
      schemaVersion: schemaVersion,
      profiles: profiles ?? this.profiles,
      activeProfileId: activeProfileId ?? this.activeProfileId,
      metricsByServer: metricsByServer ?? this.metricsByServer,
      selectionByProfile: selectionByProfile ?? this.selectionByProfile,
      recentSamplesByServer: recentSamplesByServer ?? this.recentSamplesByServer,
      settings: settings ?? this.settings,
      ranking: ranking ?? this.ranking,
      savedAtMs: savedAtMs ?? this.savedAtMs,
    );
  }

  /// Prune metrics/selection entries that no longer point at a live node, and
  /// drop sample history older than the retention window. Called at launch.
  ProfileBundle pruned({int? nowMs, int? keepDays}) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final days = keepDays ?? settings.keepRankingHistoryDays;
    final alive = serverIndex.keys.toSet();
    final cutoff = days <= 0 ? 0 : now - days * 24 * 60 * 60 * 1000;

    final metrics = <String, ServerMetrics>{};
    metricsByServer.forEach((id, m) {
      if (!alive.contains(id)) return;
      if (cutoff > 0 && m.lastSampleAtMs > 0 && m.lastSampleAtMs < cutoff) return;
      metrics[id] = m;
    });

    final samples = <String, List<SamplePoint>>{};
    recentSamplesByServer.forEach((id, list) {
      if (!alive.contains(id)) return;
      final kept = <SamplePoint>[
        for (final s in list)
          if (cutoff == 0 || s.atMs >= cutoff) s,
      ];
      if (kept.isNotEmpty) samples[id] = kept;
    });

    final selection = <String, SelectionState>{};
    selectionByProfile.forEach((id, st) {
      if (!metrics.containsKey(st.currentServerId) && st.currentServerId.isNotEmpty) {
        // The node we were pinned to is gone; forget the pin but keep timings so
        // the anti-flap cooldown still applies to the next choice.
        selection[id] = SelectionState(
          currentServerId: '',
          switchedAtMs: st.switchedAtMs,
          lastProbeRoundAtMs: st.lastProbeRoundAtMs,
          consecutiveSwitches: st.consecutiveSwitches,
          lastReason: 'previous node removed; history pruned',
        );
        return;
      }
      selection[id] = st;
    });

    return ProfileBundle(
      schemaVersion: schemaVersion,
      profiles: profiles,
      activeProfileId: activeProfileId,
      metricsByServer: metrics,
      selectionByProfile: selection,
      recentSamplesByServer: samples,
      settings: settings,
      ranking: ranking,
      savedAtMs: savedAtMs,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'schema': schemaVersion,
        'activeProfileId': activeProfileId,
        'profiles': <Object?>[for (final p in profiles) p.toJson()],
        'metrics': <String, Object?>{
          for (final e in metricsByServer.entries) e.key: e.value.toJson(),
        },
        'selection': <String, Object?>{
          for (final e in selectionByProfile.entries) e.key: e.value.toJson(),
        },
        'samples': <String, Object?>{
          for (final e in recentSamplesByServer.entries)
            e.key: <Object?>[for (final s in e.value) s.toJson()],
        },
        'settings': settings.toJson(),
        'ranking': ranking.toJson(),
        'savedAt': savedAtMs,
      };

  String encode({bool pretty = true}) {
    return pretty
        ? const JsonEncoder.withIndent('  ').convert(toJson())
        : json.encode(toJson());
  }

  static ProfileBundle fromJson(Map<String, Object?> jsonIn) {
    final version = asInt(jsonIn['schema'], fallback: 1);
    final migrated = _migrate(jsonIn, version);
    return ProfileBundle(
      schemaVersion: kSchemaVersion,
      profiles: <Profile>[
        for (final raw in asList(migrated['profiles'])) Profile.fromJson(asMap(raw)),
      ],
      activeProfileId: asString(migrated['activeProfileId']),
      metricsByServer: <String, ServerMetrics>{
        for (final e in asMap(migrated['metrics']).entries) e.key: ServerMetrics.fromJson(asMap(e.value)),
      },
      selectionByProfile: <String, SelectionState>{
        for (final e in asMap(migrated['selection']).entries) e.key: SelectionState.fromJson(asMap(e.value)),
      },
      recentSamplesByServer: <String, List<SamplePoint>>{
        for (final e in asMap(migrated['samples']).entries)
          e.key: <SamplePoint>[
            for (final raw in asList(e.value)) SamplePoint.fromJson(asMap(raw)),
          ],
      },
      settings: RuntimeSettings.fromJson(asMap(migrated['settings'])),
      ranking: RankingConfig.fromJson(asMap(migrated['ranking'])),
      savedAtMs: asInt(migrated['savedAt']),
    );
  }

  /// Parse on-disk text; returns an empty bundle for a missing/corrupt file and
  /// records why in [BundleLoadResult.error] so the UI can offer a restore.
  static BundleLoadResult load(String? contents) {
    if (contents == null || contents.trim().isEmpty) {
      return const BundleLoadResult(bundle: ProfileBundle(), error: '', created: true);
    }
    try {
      final decoded = json.decode(contents);
      if (decoded is! Map) {
        return BundleLoadResult(
          bundle: const ProfileBundle(),
          error: 'state file is not a JSON object',
        );
      }
      return BundleLoadResult(
        bundle: fromJson(<String, Object?>{
          for (final e in decoded.entries) e.key.toString(): e.value,
        }),
      );
    } on FormatException catch (e) {
      return BundleLoadResult(bundle: const ProfileBundle(), error: 'malformed JSON: ${e.message}');
    }
  }

  /// v1 stored metrics as `{id: {ping, ok, fail}}`; v2 had no `selection`
  /// section. Rather than lose history on upgrade, translate what we recognise
  /// and drop the rest.
  static Map<String, Object?> _migrate(Map<String, Object?> jsonIn, int version) {
    if (version >= kSchemaVersion) return jsonIn;
    final out = <String, Object?>{...jsonIn};
    if (version == 1) {
      final legacy = asMap(jsonIn['metrics']);
      out['metrics'] = <String, Object?>{
        for (final e in legacy.entries)
          e.key: <String, Object?>{
            if (asInt(asMap(e.value)['ping']) > 0) 'lat': asDouble(asMap(e.value)['ping']),
            'okw': asDouble(asMap(e.value)['ok'], fallback: 0.5),
            'failw': asDouble(asMap(e.value)['fail'], fallback: 0.5),
            'n': asInt(asMap(e.value)['n']),
          },
      };
    }
    out['schema'] = kSchemaVersion;
    return out;
  }
}

class BundleLoadResult {
  const BundleLoadResult({required this.bundle, required this.error, this.created = false});

  final ProfileBundle bundle;

  /// Non-empty when the previous state could not be read. The app then writes a
  /// `naxlo-two.state.corrupt-<ts>` copy beside it so nothing is lost.
  final String error;
  final bool created;

  bool get isFresh => created || error.isNotEmpty;
}
