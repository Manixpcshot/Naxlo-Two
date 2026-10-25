import '../json/json_utils.dart';
import 'metrics.dart';

/// One row of the ranked list: the score, the inputs behind it, and a plain
/// sentence about *why* it is where it is.
///
/// The `reasons` field is not decoration. A ranker the user cannot audit gets
/// turned off, so every ranked node carries the numbers that produced its
/// score and the exact deltas the selector considered.
class RankedServer {
  const RankedServer({
    required this.serverId,
    required this.score,
    required this.rank,
    required this.health,
    required this.components,
    this.latencyMs = -1,
    this.jitterMs = -1,
    this.reliability = 0.5,
    this.confidence = 0,
    this.throughputKbps = 0,
    this.ageMs = 0,
    this.consecutiveFailures = 0,
    this.isCurrent = false,
    this.isEligible = true,
    this.manualBias = 0,
    this.exploration = 0,
    this.reasons = const <String>[],
  });

  final String serverId;

  /// Final score in 0..1 (higher is better).
  final double score;
  final int rank;
  final HealthState health;

  /// Per-component contributions, already weight-multiplied, for the detail sheet.
  final Map<String, double> components;
  final int latencyMs;
  final int jitterMs;

  /// Risk-adjusted reliability (posterior lower bound).
  final double reliability;

  /// 0..1: how much data backs the estimate. `1 - sd·2` roughly.
  final double confidence;
  final double throughputKbps;
  final int ageMs;
  final int consecutiveFailures;
  final bool isCurrent;

  /// False for disabled nodes and for `down` nodes when `penalizeDown` is on.
  final bool isEligible;

  /// User's manual −100..100 bias, normalized.
  final double manualBias;

  /// How much of [score] came from exploration rather than evidence.
  final double exploration;
  final List<String> reasons;

  String get scorePercentLabel => '${(score * 100).toStringAsFixed(1)}%';

  bool get hasLatency => latencyMs >= 0;

  /// Compact, single-line explanation used in the server list.
  String get summary {
    final parts = <String>[
      if (hasLatency) '${latencyMs}ms' else 'no data',
      if (jitterMs >= 0) '±$jitterMs',
      // Named for what it is: this row explains the *score*, whose reliability term
      // is the lower bound — not the success rate the status screens show.
      'lcb ${(reliability * 100).round()}%',
      if (consecutiveFailures > 0) 'x$consecutiveFailures fail',
      if (isCurrent) 'active',
    ];
    return parts.join(' · ');
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': serverId,
        'score': score,
        'rank': rank,
        'health': health.wireName,
        'lat': latencyMs,
        'jit': jitterMs,
        'rel': reliability,
        'conf': confidence,
        'kbps': throughputKbps,
        'age': ageMs,
        'fails': consecutiveFailures,
        'cur': isCurrent,
        'elig': isEligible,
        'comp': components,
        if (reasons.isNotEmpty) 'why': List<String>.from(reasons),
      };

  static RankedServer fromJson(Map<String, Object?> json) => RankedServer(
        serverId: asString(json['id']),
        score: asDouble(json['score']),
        rank: asInt(json['rank']),
        health: HealthState.fromName(asString(json['health'])),
        components: <String, double>{
          for (final e in asMap(json['comp']).entries) e.key: asDouble(e.value),
        },
        latencyMs: asInt(json['lat'], fallback: -1),
        jitterMs: asInt(json['jit'], fallback: -1),
        reliability: asDouble(json['rel'], fallback: 0.5),
        confidence: asDouble(json['conf']),
        throughputKbps: asDouble(json['kbps']),
        ageMs: asInt(json['age']),
        consecutiveFailures: asInt(json['fails']),
        isCurrent: asBool(json['cur']),
        isEligible: asBool(json['elig'], fallback: true),
        reasons: asStringList(json['why']),
      );

  @override
  String toString() => '#$rank $serverId ${(score * 100).toStringAsFixed(1)} ($summary)';
}
