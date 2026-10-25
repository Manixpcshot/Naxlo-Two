import 'dart:math' as math;

import '../config/ranking_config.dart';
import '../models/server_node.dart';
import 'metrics.dart';
import 'ranked_server.dart';
import 'thompson.dart';

/// Turns `(servers, observations)` into an ordered, explainable list.
///
/// Design notes for anyone reading the math:
///
/// * Every component is mapped into `[0,1]`, higher-is-better, *before* weights
///   are applied. That keeps the weights interpretable ("reliability 0.9 vs
///   latency 0.85") and stops a unit change (ms → kbit/s) from silently
///   dominating the score.
/// * Saturation is exponential, not linear: `exp(-x/scale)`. A linear latency
///   term makes 20ms→40ms and 300ms→320ms look equally bad, which is not how
///   a tunnel feels. With a scale of 220ms, doubling a good node's latency is a
///   real penalty while jitter at 300ms is noise.
/// * Penalties are multiplied in *after* the weighted sum, so a node that is
///   measurably on fire (failure streak, `down`) cannot be rescued by an
///   excellent latency number.
class Ranker {
  Ranker({required this.config, ThompsonSampler? sampler})
      : sampler = sampler ?? ThompsonSampler();

  final RankingConfig config;
  final ThompsonSampler sampler;

  /// Score every server, including disabled ones (so the UI can grey them out
  /// with a reason instead of hiding them).
  List<RankedServer> rank({
    required List<ServerNode> servers,
    required Map<String, ServerMetrics> metrics,
    int nowMs = 0,
    String currentServerId = '',
  }) {
    final now = nowMs > 0 ? nowMs : DateTime.now().millisecondsSinceEpoch;
    final cfg = config.effectiveForMode();
    final results = <RankedServer>[];

    for (final server in servers) {
      final m = metrics[server.id] ?? ServerMetrics();
      results.add(_scoreOne(server, m, cfg, now, currentServerId));
    }

    results.sort(_compare);
    final out = <RankedServer>[];
    for (var i = 0; i < results.length; i++) {
      final r = results[i];
      out.add(RankedServer(
        serverId: r.serverId,
        score: r.score,
        rank: i + 1,
        health: r.health,
        components: r.components,
        latencyMs: r.latencyMs,
        jitterMs: r.jitterMs,
        reliability: r.reliability,
        confidence: r.confidence,
        throughputKbps: r.throughputKbps,
        ageMs: r.ageMs,
        consecutiveFailures: r.consecutiveFailures,
        isCurrent: r.isCurrent,
        isEligible: r.isEligible,
        manualBias: r.manualBias,
        exploration: r.exploration,
        reasons: r.reasons,
      ));
    }
    return out;
  }

  RankedServer _scoreOne(
    ServerNode server,
    ServerMetrics m,
    RankingConfig cfg,
    int nowMs,
    String currentServerId,
  ) {
    final weights = cfg.weights;
    final totalWeight = math.max(1e-6, weights.sum);
    // A node we have never measured has no age. Reporting one would render
    // "last seen 51 years ago" in the UI and crush its freshness score.
    final age = m.hasSamples ? m.ageMs(nowMs) : 0;
    final isCurrent = server.id == currentServerId && currentServerId.isNotEmpty;

    // ---- latency -----------------------------------------------------------
    var latencyMs = m.latencyMsRounded;
    if (cfg.mode == RankingMode.advanced && latencyMs >= 0) {
      // Draw from the latency distribution instead of using its mean, so a node
      // with high variance is scored on what it might do, not on what it did.
      final drawn = sampler.sampleLatencyMs(
        meanMs: m.latencyEwmaMs ?? latencyMs.toDouble(),
        sdMs: m.latencySdMs ?? 0,
      );
      latencyMs = drawn.round();
    }
    final latencyScore = latencyMs >= 0
        ? math.exp(-latencyMs / math.max(1, cfg.latencyScaleMs)).toDouble()
        : _unknownComponent;

    // ---- jitter -----------------------------------------------------------
    final jitterMs = m.jitterMsRounded;
    final jitterScore = jitterMs >= 0
        ? math.exp(-jitterMs / math.max(1, cfg.jitterScaleMs)).toDouble()
        : _unknownComponent;

    // ---- reliability ------------------------------------------------------
    double reliability;
    if (!m.hasSamples) {
      // Absence of evidence is a middle score, in every component and every mode.
      // The lower bound is a pessimistic read of *data you have*; using it for "no
      // data" permanently buries a freshly imported node below a flaky one, which
      // is the exact failure mode an adaptive ranker must not have.
      reliability = _unknownComponent;
    } else if (cfg.mode == RankingMode.advanced) {
      reliability = sampler.sampleReliability(okWeight: m.okWeight, failWeight: m.failWeight);
      // Blend the draw with the conservative bound: pure sampling is too jumpy
      // for a security tool where flapping is worse than a slower node.
      reliability = 0.55 * reliability + 0.45 * m.reliabilityLcb;
    } else {
      reliability = m.reliability;
    }

    // ---- throughput -------------------------------------------------------
    final throughputScore = m.throughputKbps > 0
        ? (m.throughputKbps / (m.throughputKbps + cfg.kbpsHalfPoint)).toDouble()
        : _unknownComponent;

    // ---- freshness --------------------------------------------------------
    // A node with *no* samples is "unknown", not "infinitely stale": scoring it
    // as stale would hide it forever, which is exactly the failure mode an
    // adaptive ranker must avoid.
    final freshnessScore = !m.hasSamples
        ? _unknownComponent
        : (age <= 0 ? 1.0 : math.exp(-age / math.max(1000, cfg.halfLifeMs * 2)).toDouble());

    // ---- stability (failure streaks) -------------------------------------
    final stabilityScore = m.consecutiveFailures <= 0
        ? 1.0
        : math.exp(-m.consecutiveFailures / 2.5).toDouble();

    // ---- stickiness -------------------------------------------------------
    final stickinessScore = isCurrent ? 1.0 : 0.0;

    final components = <String, double>{
      'latency': weights.latency * latencyScore,
      'jitter': weights.jitter * jitterScore,
      'reliability': weights.reliability * reliability,
      'throughput': weights.throughput * throughputScore,
      'freshness': weights.freshness * freshnessScore,
      'stability': weights.stability * stabilityScore,
      'stickiness': weights.stickiness * stickinessScore,
    };

    var weighted = 0.0;
    components.forEach((_, v) => weighted += v);
    var score = weighted / totalWeight;

    // ---- hard multipliers (penalties) ------------------------------------
    final eligible = server.enabled && !(cfg.penalizeDown && m.isDown);
    if (m.isDown) score *= 0.45;
    if (!server.enabled) score *= 0.05;
    if (m.consecutiveFailures >= 5) score *= 0.6;

    // manual bias: -100..100 → ±5% of the score, so a "pin" nudges but cannot
    // override evidence entirely (a dead node stays down).
    final manualBias = (server.weight / 100.0).clamp(-1.0, 1.0).toDouble();
    score *= 1.0 + manualBias * 0.05;

    // exploration bonus, in advanced mode only: unknown nodes get a small push
    // so they are measured rather than ignored forever.
    var exploration = 0.0;
    if (cfg.mode == RankingMode.advanced && cfg.exploration > 0) {
      final uncertainty = 1.0 - _confidenceOf(m);
      exploration = cfg.exploration * 0.25 * uncertainty;
      score += exploration;
    }

    score = score.clamp(0.0, 1.0).toDouble();

    final reasons = <String>[
      if (latencyMs >= 0) 'latency ${latencyMs}ms' else 'no latency sample yet',
      if (jitterMs >= 0) 'jitter ±${jitterMs}ms',
      'reliability ${(reliability * 100).toStringAsFixed(0)}% (${m.okWeight.toStringAsFixed(1)} ok / '
          '${m.failWeight.toStringAsFixed(1)} fail, decayed)',
      if (m.throughputKbps > 0) 'throughput ${m.throughputKbps.toStringAsFixed(0)} kbit/s',
      if (m.hasSamples && age > 0) 'last seen ${(age / 1000).toStringAsFixed(0)}s ago',
      if (m.consecutiveFailures > 0) 'penalty: ${m.consecutiveFailures} consecutive failures',
      if (m.isDown) 'penalty: marked down',
      // Only claim it when it pays: in `simple` the weight is 0, and a reason line
      // that says "currently active" over a 0.000 contribution makes the explain
      // sheet a lie about a mode that deliberately has no hysteresis term.
      if (isCurrent && weights.stickiness > 0) 'bonus: currently active (stickiness)',
      if (server.weight != 0) 'manual bias ${server.weight > 0 ? '+' : ''}${server.weight}',
      if (exploration > 0) 'exploration +${(exploration * 100).toStringAsFixed(1)}%',
      if (!server.enabled) 'excluded: node disabled',
    ];

    return RankedServer(
      serverId: server.id,
      score: score,
      rank: 0,
      health: m.health,
      components: <String, double>{
        for (final e in components.entries) e.key: double.parse(e.value.toStringAsFixed(4)),
      },
      latencyMs: latencyMs,
      jitterMs: jitterMs,
      reliability: double.parse(reliability.toStringAsFixed(4)),
      confidence: _confidenceOf(m),
      throughputKbps: double.parse(m.throughputKbps.toStringAsFixed(1)),
      ageMs: age,
      consecutiveFailures: m.consecutiveFailures,
      isCurrent: isCurrent,
      isEligible: eligible,
      manualBias: manualBias,
      exploration: exploration,
      reasons: reasons,
    );
  }

  /// Mid-band value for "we have no idea yet": better than a mediocre node,
  /// worse than a measured-good one. Keeps unprobed nodes reachable without
  /// letting them win a tie.
  static const double _unknownComponent = 0.55;

  /// How much the estimates can be trusted: grows with sample count and decays
  /// with staleness. Used by the UI ("2 samples, 40s ago") and by exploration.
  static double _confidenceOf(ServerMetrics m) {
    if (m.totalSamples == 0) return 0;
    final byCount = m.totalSamples / (m.totalSamples + 6.0);
    final byReliability = math.min(1.0, 1.0 - m.reliabilitySd * 2.0);
    return (0.6 * byCount + 0.4 * byReliability).clamp(0.0, 1.0).toDouble();
  }

  int _compare(RankedServer a, RankedServer b) {
    // Eligible first, then by score, then stable tie-break by id so output is
    // deterministic regardless of map iteration order.
    if (a.isEligible != b.isEligible) return a.isEligible ? -1 : 1;
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    return a.serverId.compareTo(b.serverId);
  }

  /// Candidate order used by the auto-selector: eligible nodes only, ties broken
  /// in favour of the current node (that is what `loadSpread`/stickiness is for).
  List<RankedServer> candidates(List<RankedServer> ranked, {String currentServerId = ''}) {
    final eligible = ranked.where((r) => r.isEligible).toList(growable: false);
    if (eligible.isEmpty) return const <RankedServer>[];
    if (!config.loadSpread) return eligible;
    // With load spreading, keep a band of near-ties and prefer whoever is not
    // already loaded — here expressed as: current node stays first, the rest
    // keep their score order.
    if (currentServerId.isEmpty) return eligible;
    final current = eligible.where((r) => r.serverId == currentServerId).toList();
    if (current.isEmpty) return eligible;
    return <RankedServer>[
      ...current,
      ...eligible.where((r) => r.serverId != currentServerId),
    ];
  }
}
