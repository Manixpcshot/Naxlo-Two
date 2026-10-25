import '../json/json_utils.dart';

/// `simple` = deterministic "best median latency, with light hysteresis".
/// `advanced` = EWMA + risk-adjusted reliability + Thompson exploration.
enum RankingMode {
  simple('simple', 'Median latency'),
  advanced('advanced', 'Adaptive (EWMA + Thompson)');

  const RankingMode(this.wireName, this.label);
  final String wireName;
  final String label;

  static RankingMode fromName(String? raw) {
    final s = asString(raw).trim();
    for (final e in RankingMode.values) {
      if (e.wireName == s) return e;
    }
    return RankingMode.advanced;
  }
}

/// The seven sliders the UI exposes. Each is in 0..1; they are normalized
/// against their sum, so the *relative* shape matters, not the absolute scale.
class RankingWeights {
  const RankingWeights({
    this.latency = 0.85,
    this.jitter = 0.45,
    this.reliability = 0.9,
    this.throughput = 0.5,
    this.freshness = 0.35,
    this.stability = 0.55,
    this.stickiness = 0.4,
  });

  final double latency;
  final double jitter;

  /// Beta-posterior reliability (risk adjusted).
  final double reliability;

  /// Measured throughput while connected.
  final double throughput;

  /// How recent the observations are.
  final double freshness;

  /// Resistance to failure streaks (a.k.a. "don't pick the flapper").
  final double stability;

  /// Bias toward the node already carrying traffic.
  final double stickiness;

  double get sum => latency + jitter + reliability + throughput + freshness + stability + stickiness;

  RankingWeights copyWith({
    double? latency,
    double? jitter,
    double? reliability,
    double? throughput,
    double? freshness,
    double? stability,
    double? stickiness,
  }) {
    return RankingWeights(
      latency: latency ?? this.latency,
      jitter: jitter ?? this.jitter,
      reliability: reliability ?? this.reliability,
      throughput: throughput ?? this.throughput,
      freshness: freshness ?? this.freshness,
      stability: stability ?? this.stability,
      stickiness: stickiness ?? this.stickiness,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'latency': latency,
        'jitter': jitter,
        'reliability': reliability,
        'throughput': throughput,
        'freshness': freshness,
        'stability': stability,
        'stickiness': stickiness,
      };

  static RankingWeights fromJson(Map<String, Object?> json) {
    const d = RankingWeights();
    if (json.isEmpty) return d;
    return RankingWeights(
      latency: asDouble(json['latency'], fallback: d.latency),
      jitter: asDouble(json['jitter'], fallback: d.jitter),
      reliability: asDouble(json['reliability'], fallback: d.reliability),
      throughput: asDouble(json['throughput'], fallback: d.throughput),
      freshness: asDouble(json['freshness'], fallback: d.freshness),
      stability: asDouble(json['stability'], fallback: d.stability),
      stickiness: asDouble(json['stickiness'], fallback: d.stickiness),
    );
  }

  /// UI presets.
  static const RankingWeights balanced = RankingWeights();
  static const RankingWeights speed = RankingWeights(
    latency: 1.0,
    jitter: 0.25,
    reliability: 0.5,
    throughput: 0.8,
    freshness: 0.3,
    stability: 0.3,
    stickiness: 0.2,
  );
  static const RankingWeights stability = RankingWeights(
    latency: 0.5,
    jitter: 0.8,
    reliability: 1.0,
    throughput: 0.3,
    freshness: 0.4,
    stability: 0.95,
    stickiness: 0.7,
  );

  static RankingWeights preset(String name) {
    switch (name) {
      case 'speed':
        return speed;
      case 'stability':
        return stability;
      default:
        return balanced;
    }
  }

  @override
  String toString() => 'RankingWeights(${(latency, jitter, reliability).toString()})';
}

/// Everything the ranker and the selector need; persisted with the profile so a
/// restart does not reset the user's tuning.
class RankingConfig {
  const RankingConfig({
    this.mode = RankingMode.advanced,
    this.weights = RankingWeights.balanced,
    this.halfLifeMs = 90000,
    this.latencyScaleMs = 220,
    this.jitterScaleMs = 35,
    this.kbpsHalfPoint = 4096,
    this.switchMargin = 0.06,
    this.dwellMs = 45000,
    this.cooldownMs = 120000,
    this.probeIntervalMs = 60000,
    this.probeConcurrency = 6,
    this.probeTimeoutMs = 4000,
    this.probeSamples = 3,
    this.exploration = 0.18,
    this.penalizeDown = true,
    this.loadSpread = false,
    this.maxSamplesKept = 40,
  });

  final RankingMode mode;
  final RankingWeights weights;

  /// Half-life of the decay window. 90s ≈ "what happened in the last 3 minutes
  /// matters, an hour ago barely does".
  final int halfLifeMs;

  /// exp(-latency / latencyScaleMs): the ms value at which latency score ≈ 0.37.
  final int latencyScaleMs;
  final int jitterScaleMs;

  /// Throughput saturates around this kbit/s.
  final int kbpsHalfPoint;

  /// Minimum score gap that justifies moving off the current node.
  final double switchMargin;

  /// How long a candidate must stay ahead before we act (anti-flap).
  final int dwellMs;

  /// Time after a switch during which we won't switch again.
  final int cooldownMs;
  final int probeIntervalMs;
  final int probeConcurrency;
  final int probeTimeoutMs;

  /// Samples per probe round; the median of these is what gets recorded.
  final int probeSamples;

  /// Strength of the Thompson exploration term in `advanced`.
  final double exploration;

  /// Drop `down` nodes from the candidate set (unless all are down).
  final bool penalizeDown;

  /// Break near-ties across nodes instead of always taking #1.
  final bool loadSpread;
  final int maxSamplesKept;

  RankingConfig copyWith({
    RankingMode? mode,
    RankingWeights? weights,
    int? halfLifeMs,
    int? latencyScaleMs,
    int? jitterScaleMs,
    int? kbpsHalfPoint,
    double? switchMargin,
    int? dwellMs,
    int? cooldownMs,
    int? probeIntervalMs,
    int? probeConcurrency,
    int? probeTimeoutMs,
    int? probeSamples,
    double? exploration,
    bool? penalizeDown,
    bool? loadSpread,
  }) {
    return RankingConfig(
      mode: mode ?? this.mode,
      weights: weights ?? this.weights,
      halfLifeMs: halfLifeMs ?? this.halfLifeMs,
      latencyScaleMs: latencyScaleMs ?? this.latencyScaleMs,
      jitterScaleMs: jitterScaleMs ?? this.jitterScaleMs,
      kbpsHalfPoint: kbpsHalfPoint ?? this.kbpsHalfPoint,
      switchMargin: switchMargin ?? this.switchMargin,
      dwellMs: dwellMs ?? this.dwellMs,
      cooldownMs: cooldownMs ?? this.cooldownMs,
      probeIntervalMs: probeIntervalMs ?? this.probeIntervalMs,
      probeConcurrency: probeConcurrency ?? this.probeConcurrency,
      probeTimeoutMs: probeTimeoutMs ?? this.probeTimeoutMs,
      probeSamples: probeSamples ?? this.probeSamples,
      exploration: exploration ?? this.exploration,
      penalizeDown: penalizeDown ?? this.penalizeDown,
      loadSpread: loadSpread ?? this.loadSpread,
      maxSamplesKept: maxSamplesKept,
    );
  }

  /// Config for `simple` mode with the adaptive knobs neutralized.
  RankingConfig effectiveForMode() {
    if (mode == RankingMode.simple) {
      return copyWith(
        weights: const RankingWeights(
          latency: 1.0,
          jitter: 0.0,
          reliability: 0.25,
          throughput: 0.0,
          freshness: 0.0,
          stability: 0.25,
          stickiness: 0.0,
        ),
        exploration: 0.0,
      );
    }
    return this;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'mode': mode.wireName,
        'weights': weights.toJson(),
        'halfLifeMs': halfLifeMs,
        'latencyScaleMs': latencyScaleMs,
        'jitterScaleMs': jitterScaleMs,
        'kbpsHalfPoint': kbpsHalfPoint,
        'switchMargin': switchMargin,
        'dwellMs': dwellMs,
        'cooldownMs': cooldownMs,
        'probeIntervalMs': probeIntervalMs,
        'probeConcurrency': probeConcurrency,
        'probeTimeoutMs': probeTimeoutMs,
        'probeSamples': probeSamples,
        'exploration': exploration,
        'penalizeDown': penalizeDown,
        'loadSpread': loadSpread,
        'maxSamplesKept': maxSamplesKept,
      };

  static RankingConfig fromJson(Map<String, Object?> json) {
    const d = RankingConfig();
    if (json.isEmpty) return d;
    return RankingConfig(
      mode: RankingMode.fromName(asString(json['mode'])),
      weights: RankingWeights.fromJson(asMap(json['weights'])),
      halfLifeMs: asInt(json['halfLifeMs'], fallback: d.halfLifeMs),
      latencyScaleMs: asInt(json['latencyScaleMs'], fallback: d.latencyScaleMs),
      jitterScaleMs: asInt(json['jitterScaleMs'], fallback: d.jitterScaleMs),
      kbpsHalfPoint: asInt(json['kbpsHalfPoint'], fallback: d.kbpsHalfPoint),
      switchMargin: asDouble(json['switchMargin'], fallback: d.switchMargin),
      dwellMs: asInt(json['dwellMs'], fallback: d.dwellMs),
      cooldownMs: asInt(json['cooldownMs'], fallback: d.cooldownMs),
      probeIntervalMs: asInt(json['probeIntervalMs'], fallback: d.probeIntervalMs),
      probeConcurrency: asInt(json['probeConcurrency'], fallback: d.probeConcurrency),
      probeTimeoutMs: asInt(json['probeTimeoutMs'], fallback: d.probeTimeoutMs),
      probeSamples: asInt(json['probeSamples'], fallback: d.probeSamples),
      exploration: asDouble(json['exploration'], fallback: d.exploration),
      penalizeDown: asBool(json['penalizeDown'], fallback: true),
      loadSpread: asBool(json['loadSpread']),
      maxSamplesKept: asInt(json['maxSamplesKept'], fallback: d.maxSamplesKept),
    );
  }

  static const RankingConfig defaults = RankingConfig();
}
