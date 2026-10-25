import 'dart:math' as math;

/// Sampling helpers for the `advanced` ranking mode.
///
/// Why Thompson sampling instead of ε-greedy: with a node list that changes
/// over the day (a VPS under load at 21:00, a route change, a provider
/// restarting one box), the question is never "is this node good?" but "is it
/// good *now*, and how sure am I?". Drawing from the posterior answers both at
/// once: a node with a fat posterior gets tried often, a proven node gets kept,
/// and a node that has done well for hours is not abandoned by one bad minute.
class ThompsonSampler {
  ThompsonSampler({int? seed}) : _random = math.Random(seed);

  final math.Random _random;

  /// Standard normal via Box–Muller. The second deviate is cached — the ranker
  /// draws many samples per round.
  double? _spareNormal;

  double normal() {
    final spare = _spareNormal;
    if (spare != null) {
      _spareNormal = null;
      return spare;
    }
    double u1;
    do {
      u1 = _random.nextDouble();
    } while (u1 <= 1e-12);
    final u2 = _random.nextDouble();
    final radius = math.sqrt(-2.0 * math.log(u1));
    final theta = 2.0 * math.pi * u2;
    _spareNormal = radius * math.sin(theta);
    return radius * math.cos(theta);
  }

  /// Gamma(shape, 1) via Marsaglia–Tsang, with the standard boost for shape < 1.
  double gamma(double shape) {
    if (shape <= 0) return 0;
    if (shape < 1.0) {
      final u = _random.nextDouble();
      return gamma(shape + 1.0) * math.pow(u, 1.0 / shape).toDouble();
    }
    final d = shape - 1.0 / 3.0;
    final c = 1.0 / math.sqrt(9.0 * d);
    for (var guard = 0; guard < 64; guard++) {
      double x;
      double v;
      do {
        x = normal();
        v = 1.0 + c * x;
      } while (v <= 0);
      v = v * v * v;
      final u = _random.nextDouble();
      if (u < 1.0 - 0.0331 * x * x * x * x) return d * v;
      if (u.isNaN) continue;
      if (math.log(u) < 0.5 * x * x + d * (1.0 - v + math.log(v))) return d * v;
    }
    // Pathological RNG state; the mean of the distribution is a safe fallback.
    return shape;
  }

  /// Beta(a, b) draw in (0, 1).
  double beta(double a, double b) {
    if (a <= 0 || b <= 0) return 0.5;
    final x = gamma(a);
    final y = gamma(b);
    if (x + y <= 0) return 0.5;
    return (x / (x + y)).clamp(1e-6, 1.0 - 1e-6).toDouble();
  }

  /// Reliability draw for a server's Beta posterior.
  double sampleReliability({required double okWeight, required double failWeight}) {
    return beta(0.5 + okWeight, 0.5 + failWeight);
  }

  /// Latency draw: log-normal centred on the EWMA with [sdMs] spread, clipped
  /// to a sane floor. Scoring the *draw* (rather than the mean) is what turns a
  /// volatile node into a risky one.
  double sampleLatencyMs({required double meanMs, required double sdMs, double floorMs = 1}) {
    if (meanMs <= 0) return math.max(floorMs, meanMs);
    final sd = math.max(0.0, sdMs);
    if (sd <= 0.5) return math.max(floorMs, meanMs);
    final sigma = math.sqrt(math.log(1.0 + (sd / meanMs) * (sd / meanMs)));
    // Median-anchored on purpose. Centring the log at log(mean) - σ²/2 would make
    // the draw *unbiased* (E[draw] == mean), i.e. variance would be free — and a
    // ranker where risk is free keeps picking the node that spikes every third
    // minute. With the median at the EWMA, E[draw] = mean · exp(σ²/2) > mean: a
    // jittery node is scored as if it were slower than it usually is, which is the
    // "what might it do" the caller asks for.
    final draw = math.exp(mu + sigma * normal());
    return draw.clamp(floorMs, 60000.0).toDouble();
  }

  /// Deterministic sequence for tests.
  void resetSeed(int seed) {
    _seeded = math.Random(seed);
  }

  math.Random? _seeded;

  math.Random get rng => _seeded ?? _random;
}
