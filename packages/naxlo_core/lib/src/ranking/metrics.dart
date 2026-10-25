import 'dart:math' as math;

import '../json/json_utils.dart';
import 'sample_point.dart';

/// Coarse health used by badges and by the failover policy.
enum HealthState {
  unknown('unknown'),
  healthy('healthy'),
  degraded('degraded'),
  down('down');

  const HealthState(this.wireName);
  final String wireName;

  static HealthState fromName(String? raw) {
    final s = asString(raw).trim();
    for (final e in HealthState.values) {
      if (e.wireName == s) return e;
    }
    return HealthState.unknown;
  }

  bool get isUsable => this != HealthState.down;
}

/// Rolling, time-decayed estimates for one server.
///
/// This is the heart of the ranker. Three ideas make it behave better than
/// "remember the last ping":
///
/// 1. **Exponentially weighted estimates with a half-life.** Each observation is
///    decayed by `0.5^(age/halfLifeMs)` before merging, so an old measurement
///    fades instead of sitting in an average forever, and a burst of new
///    samples can't be smothered by a long history.
/// 2. **A Beta posterior for reliability** with the same decay, reported as a
///    risk-adjusted lower bound (`mean - k·sd`). A node with 1/1 success is not
///    yet "perfect"; a node with 900/1000 is.
/// 3. **Jitter as a first-class quantity** — the mean of |Δlatency| — because
///    an 80ms node that ranges 80±120ms is worse to use than a 110ms steady one.
class ServerMetrics {
  ServerMetrics({
    this.latencyEwmaMs,
    this.latencySdMs,
    this.jitterEwmaMs,
    this.okWeight = kPriorWeight,
    this.failWeight = kPriorWeight,
    this.throughputKbps = 0,
    this.consecutiveFailures = 0,
    this.totalSamples = 0,
    this.lastSampleAtMs = 0,
    this.lastSuccessAtMs = 0,
    this.lastLatencyMs = -1,
    this.lastError = '',
    this.health = HealthState.unknown,
  });

  /// Jeffreys prior (½,½): keeps a node with zero history at "unknown, maybe
  /// fine" instead of "0% success → never try it".
  static const double kPriorWeight = 0.5;

  double? latencyEwmaMs;
  double? latencySdMs;
  double? jitterEwmaMs;
  double okWeight;
  double failWeight;
  double throughputKbps;
  int consecutiveFailures;
  int totalSamples;
  int lastSampleAtMs;
  int lastSuccessAtMs;
  int lastLatencyMs;
  String lastError;
  HealthState health;

  double _lastLatencyForJitter = double.nan;

  bool get hasSamples => totalSamples > 0;
  bool get isDown => health == HealthState.down;
  bool get isUnknown => health == HealthState.unknown;

  /// Age of the newest observation.
  int ageMs(int nowMs) => math.max(0, nowMs - lastSampleAtMs);

  double get reliability {
    final total = okWeight + failWeight;
    if (total <= 0) return 0.5;
    return okWeight / total;
  }

  double get reliabilityVariance {
    final a = okWeight, b = failWeight;
    final total = a + b;
    if (total <= 0) return 0.25;
    return (a * b) / (total * total * (total + 1));
  }

  double get reliabilitySd => math.sqrt(reliabilityVariance);

  /// Conservative reliability: posterior mean minus one standard deviation,
  /// floored at 0. This is what punishes a node that "looks great" on two
  /// samples, and what rewards one that has been up for hours.
  double get reliabilityLcb {
    final mean = reliability;
    final v = reliabilityVariance;
    if (v <= 0) return mean;
    return math.max(0.0, mean - _lcbK() * math.sqrt(v));
  }

  double _lcbK() {
    // Shrink the penalty when we have little data? No — that is exactly when we
    // want it. But cap it so a single transient timeout doesn't zero a node.
    return math.min(1.25, 0.75 + consecutiveFailures * 0.15);
  }

  /// Effective latency to display: EWMA, or the raw last value if we only have
  /// one sample (EWMA of one point is that point anyway).
  double get latencyMsValue => latencyEwmaMs ?? (lastLatencyMs >= 0 ? lastLatencyMs.toDouble() : double.nan);

  bool get hasLatency => latencyEwmaMs != null || lastLatencyMs >= 0;

  double get jitterMsValue => jitterEwmaMs ?? 0;

  int get latencyMsRounded => hasLatency ? latencyMsValue.round() : -1;
  int get jitterMsRounded => jitterEwmaMs == null ? -1 : jitterEwmaMs!.round();

  /// Fold a new observation into the estimates.
  ///
  /// [halfLifeMs] controls how fast the past forgets; [nowMs] is only used to
  /// measure the gap since the previous sample.
  void observe(SamplePoint sample, {required int halfLifeMs, double? alphaOverride}) {
    totalSamples++;
    final dt = lastSampleAtMs == 0 ? 0.0 : math.max(0, sample.atMs - lastSampleAtMs).toDouble();
    lastSampleAtMs = sample.atMs;

    // Decay everything toward "no knowledge" first, so the merge below is a
    // plain weighted update with alpha derived from the *gap since last sample*.
    final decay = halfLifeMs <= 0 ? 1.0 : math.pow(0.5, dt / halfLifeMs).toDouble();
    okWeight *= decay;
    failWeight *= decay;

    // alpha: how much of the new sample to take. A single fresh sample on top
    // of a long gap must move the estimate a lot (alpha → 1); many samples in a
    // short window should move it little.
    final gapAlpha = halfLifeMs <= 0 ? 1.0 : 1.0 - math.pow(0.5, dt / halfLifeMs).toDouble();
    final alpha = (alphaOverride ?? gapAlpha).clamp(0.02, 1.0).toDouble() * sample.source.reliability;

    if (!sample.ok) {
      failWeight += 1.0 * sample.source.reliability;
      consecutiveFailures++;
      lastError = sample.error.isEmpty ? 'unreachable' : sample.error;
      _refreshHealth();
      return;
    }

    consecutiveFailures = 0;
    lastSuccessAtMs = sample.atMs;
    okWeight += 1.0 * sample.source.reliability;

    if (sample.latencyMs >= 0) {
      final observed = sample.latencyMs.toDouble();
      if (latencyEwmaMs == null) {
        latencyEwmaMs = observed;
        latencySdMs = 0;
        _lastLatencyForJitter = observed;
      } else {
        final prev = latencyEwmaMs!;
        final merged = prev + alpha * (observed - prev);
        final dev = (observed - prev).abs();
        latencySdMs = (latencySdMs ?? 0) + alpha * (dev - (latencySdMs ?? 0));
        latencyEwmaMs = merged;
        if (!_lastLatencyForJitter.isNaN) {
          final delta = (observed - _lastLatencyForJitter).abs();
          jitterEwmaMs = jitterEwmaMs == null ? delta : (jitterEwmaMs! + alpha * (delta - jitterEwmaMs!));
        }
        _lastLatencyForJitter = observed;
      }
      lastLatencyMs = sample.latencyMs;
    }

    if (sample.bytes > 0) {
      // bytes over the inter-sample window → kbit/s
      if (dt > 0) {
        final kbps = (sample.bytes * 8.0) / (dt / 1000.0) / 1000.0;
        throughputKbps = throughputKbps <= 0 ? kbps : throughputKbps + alpha * (kbps - throughputKbps);
      }
    }
    _refreshHealth();
  }

  /// Recompute [health] from the estimates. Thresholds are intentionally blunt:
  /// this drives a badge and a failover, not a fine-grained score.
  void _refreshHealth() {
    if (totalSamples == 0) {
      health = HealthState.unknown;
      return;
    }
    if (consecutiveFailures >= 3 || reliability < 0.25) {
      health = HealthState.down;
      return;
    }
    if (consecutiveFailures > 0 || reliability < 0.7 || reliabilitySd > 0.22) {
      health = HealthState.degraded;
      return;
    }
    health = HealthState.healthy;
  }

  /// Force the node into `down` (e.g. the engine exited while it was active).
  void noteEngineFailure(int nowMs, String error) {
    failWeight += 1.0;
    consecutiveFailures++;
    lastSampleAtMs = nowMs;
    lastError = error;
    _refreshHealth();
  }

  Map<String, Object?> toJson() => <String, Object?>{
        if (latencyEwmaMs != null) 'lat': _round3(latencyEwmaMs!),
        if (latencySdMs != null) 'sd': _round3(latencySdMs!),
        if (jitterEwmaMs != null) 'jit': _round3(jitterEwmaMs!),
        'okw': _round3(okWeight),
        'failw': _round3(failWeight),
        'kbps': _round3(throughputKbps),
        'fails': consecutiveFailures,
        'n': totalSamples,
        'at': lastSampleAtMs,
        'okAt': lastSuccessAtMs,
        'lastLat': lastLatencyMs,
        if (lastError.isNotEmpty) 'err': lastError,
        'health': health.wireName,
      };

  static double _round3(double v) => (v * 1000).roundToDouble() / 1000;

  static ServerMetrics fromJson(Map<String, Object?> json) {
    final m = ServerMetrics(
      latencyEwmaMs: json['lat'] == null ? null : asDouble(json['lat']),
      latencySdMs: json['sd'] == null ? null : asDouble(json['sd']),
      jitterEwmaMs: json['jit'] == null ? null : asDouble(json['jit']),
      okWeight: asDouble(json['okw'], fallback: kPriorWeight),
      failWeight: asDouble(json['failw'], fallback: kPriorWeight),
      throughputKbps: asDouble(json['kbps']),
      consecutiveFailures: asInt(json['fails']),
      totalSamples: asInt(json['n']),
      lastSampleAtMs: asInt(json['at']),
      lastSuccessAtMs: asInt(json['okAt']),
      lastLatencyMs: asInt(json['lastLat'], fallback: -1),
      lastError: asString(json['err']),
      health: HealthState.fromName(asString(json['health'])),
    );
    if (m.lastLatencyMs >= 0) m._lastLatencyForJitter = m.lastLatencyMs.toDouble();
    return m;
  }

  @override
  String toString() => 'ServerMetrics(lat=${latencyMsRounded}ms, rel=${(reliability * 100).round()}%, '
      'health=${health.wireName}, n=$totalSamples)';
}
