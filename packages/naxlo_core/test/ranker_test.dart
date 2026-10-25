import 'package:naxlo_core/naxlo_core.dart';
import 'package:test/test.dart';

ServerNode node(
  String id, {
  int weight = 0,
  bool enabled = true,
  int port = 443,
}) {
  return ServerNode(
    id: id,
    name: id,
    address: '10.0.0.$port',
    port: port,
    protocol: ProxyProtocol.vless,
    userId: 'u-$id',
    enabled: enabled,
    weight: weight,
  );
}

ServerMetrics withLatency(int ms, {int atMs = 1000000, int extra = 0}) {
  final m = ServerMetrics();
  m.observe(SamplePoint.success(atMs: atMs, latencyMs: ms), halfLifeMs: 90000);
  for (var i = 0; i < extra; i++) {
    m.observe(SamplePoint.success(atMs: atMs + 1000 + i * 1000, latencyMs: ms), halfLifeMs: 90000);
  }
  return m;
}

void main() {
  const simple = RankingConfig(mode: RankingMode.simple, halfLifeMs: 90000);

  group('Ranker', () {
    test('orders by measured latency in simple mode', () {
      final ranker = Ranker(config: simple);
      final ranked = ranker.rank(
        servers: <ServerNode>[node('slow'), node('fast')],
        metrics: <String, ServerMetrics>{
          'slow': withLatency(400),
          'fast': withLatency(50),
        },
        nowMs: 1000000,
      );
      expect(ranked.first.serverId, 'fast');
      expect(ranked.first.rank, 1);
      expect(ranked.last.rank, 2);
      expect(ranked.first.score > ranked.last.score, isTrue);
      expect(ranked.first.latencyMs, 50);
    });

    test('never-measured nodes are unknown, not infinitely stale', () {
      final ranker = Ranker(config: simple);
      final ranked = ranker.rank(
        servers: <ServerNode>[node('known'), node('ghost')],
        metrics: <String, ServerMetrics>{
          'known': withLatency(50, atMs: 0),
        },
        nowMs: 10 * 60 * 1000,
      );
      final ghost = ranked.firstWhere((r) => r.serverId == 'ghost');
      final known = ranked.firstWhere((r) => r.serverId == 'known');
      expect(ghost.ageMs, 0, reason: 'no sample yet is not "ancient"');
      expect(ghost.isEligible, isTrue, reason: 'it must stay reachable so it can be probed');
      // A proven-excellent node still beats an unknown one in `simple`.
      expect(known.score > ghost.score, isTrue);
    });

    test('manual bias nudges but cannot rescue a bad node', () {
      final ranker = Ranker(config: simple);
      final ranked = ranker.rank(
        servers: <ServerNode>[node('fast'), node('slow', weight: 100)],
        metrics: <String, ServerMetrics>{
          'fast': withLatency(40),
          'slow': withLatency(900),
        },
        nowMs: 1000000,
      );
      expect(ranked.first.serverId, 'fast');
      final slow = ranked.firstWhere((r) => r.serverId == 'slow');
      expect(slow.manualBias, 1.0);
      expect(slow.reasons.any((s) => s.contains('manual bias')), isTrue);
    });

    test('disabled and down nodes are pushed out of the candidate set', () {
      final ranker = Ranker(config: simple);
      final down = ServerMetrics();
      down.observe(SamplePoint.failure(atMs: 1, error: 'eof'), halfLifeMs: 90000);
      down.observe(SamplePoint.failure(atMs: 2, error: 'eof'), halfLifeMs: 90000);
      down.observe(SamplePoint.failure(atMs: 3, error: 'eof'), halfLifeMs: 90000);
      final ranked = ranker.rank(
        servers: <ServerNode>[node('off', enabled: false), node('dead'), node('ok')],
        metrics: <String, ServerMetrics>{
          'dead': down,
          'ok': withLatency(120),
        },
        nowMs: 1000000,
      );
      expect(ranked.first.serverId, 'ok', reason: 'the only eligible node comes first');
      expect(ranked.firstWhere((r) => r.serverId == 'off').isEligible, isFalse);
      expect(ranked.firstWhere((r) => r.serverId == 'dead').isEligible, isFalse);
      expect(ranked.firstWhere((r) => r.serverId == 'dead').health, HealthState.down);
    });

    test('stickiness rewards the node already carrying traffic', () {
      final a = withLatency(100);
      final advanced = const RankingConfig(mode: RankingMode.advanced);
      List<RankedServer> rank(String current, RankingConfig cfg) => Ranker(config: cfg).rank(
            servers: <ServerNode>[node('x')],
            metrics: <String, ServerMetrics>{'x': a},
            nowMs: 1000000,
            currentServerId: current,
          );

      expect(rank('x', advanced).first.score, greaterThan(rank('', advanced).first.score));
      expect(rank('x', advanced).first.reasons.any((r) => r.contains('stickiness')), isTrue);

      // And it is deliberately *absent* from `simple`: in "median latency" mode
      // the list the user reads must not be reordered by which node happens to be
      // carrying traffic right now — that would make the ranking look arbitrary
      // exactly when the user is trying to compare nodes. Resistance to flapping
      // lives in the selector (dwell + switch margin), which applies in both
      // modes, so nothing is lost by keeping it out of the score.
      expect(rank('x', simple).first.score, rank('', simple).first.score);
      expect(rank('x', simple).first.reasons.any((r) => r.contains('stickiness')), isFalse);
    });

    test('advanced mode is deterministic for a fixed seed', () {
      final servers = <ServerNode>[node('a'), node('b'), node('c')];
      final metrics = <String, ServerMetrics>{
        'a': withLatency(60, extra: 20),
        'b': withLatency(65, extra: 4),
        'c': withLatency(300, extra: 40),
      };
      final one = Ranker(
        config: const RankingConfig(mode: RankingMode.advanced),
        sampler: ThompsonSampler(seed: 42),
      ).rank(servers: servers, metrics: metrics, nowMs: 1000000);
      final two = Ranker(
        config: const RankingConfig(mode: RankingMode.advanced),
        sampler: ThompsonSampler(seed: 42),
      ).rank(servers: servers, metrics: metrics, nowMs: 1000000);
      expect(one.map((r) => r.serverId), two.map((r) => r.serverId));
      for (var i = 0; i < one.length; i++) {
        expect(one[i].score, two[i].score);
      }
      expect(one.first.score <= 1.0, isTrue);
      expect(one.first.score >= 0.0, isTrue);
    });

    test('advanced mode explores nodes it has little data about', () {
      final wellKnown = withLatency(70, extra: 60);
      final ranker = Ranker(config: const RankingConfig(mode: RankingMode.advanced));
      final metrics = <String, ServerMetrics>{
        'known': wellKnown,
        'unknown': ServerMetrics(),
      };
      final ranked = ranker.rank(servers: <ServerNode>[node('known'), node('unknown')], metrics: metrics, nowMs: 1000000);
      final unknown = ranked.firstWhere((r) => r.serverId == 'unknown');
      final known = ranked.firstWhere((r) => r.serverId == 'known');
      expect(unknown.confidence, lessThan(known.confidence));
      expect(unknown.exploration > 0, isTrue);
      expect(unknown.isEligible, isTrue);
      // The bonus must be a nudge, not a guarantee: exploration makes an
      // unmeasured node *closer* to a proven one than `simple` mode leaves it.
      // Compare against the same mode with exploration turned off, not against
      // `simple`: the two modes have different weight vectors, so a cross-mode
      // comparison measures the vectors, not the mechanism under test.
      final noExplore = Ranker(config: const RankingConfig(mode: RankingMode.advanced, exploration: 0.0))
          .rank(
            servers: <ServerNode>[node('known'), node('unknown')],
            metrics: metrics,
            nowMs: 1000000,
          )
          .firstWhere((r) => r.serverId == 'unknown');
      expect(unknown.score > noExplore.score, isTrue);
      expect(unknown.exploration, lessThan(0.1),
          reason: 'a nudge, so a coin flip never beats evidence outright');
    });

    test('every ranked row explains itself', () {
      final ranked = Ranker(config: simple).rank(
        servers: <ServerNode>[node('x')],
        metrics: <String, ServerMetrics>{'x': withLatency(90)},
        nowMs: 1000000,
      );
      expect(ranked.first.reasons, isNotEmpty);
      expect(ranked.first.summary.contains('90ms'), isTrue);
      expect(ranked.first.components.containsKey('latency'), isTrue);
      expect(ranked.first.components['latency']! > 0, isTrue);
    });

    test('tie-break is stable across map orderings', () {
      final empty = <String, ServerMetrics>{};
      final servers = <ServerNode>[node('bbb'), node('aaa'), node('ccc')];
      final ranked = Ranker(config: simple).rank(servers: servers, metrics: empty, nowMs: 1);
      expect(ranked.map((r) => r.serverId).toList(), <String>['aaa', 'bbb', 'ccc']);
    });
  });

  group('RankingConfig', () {
    test('simple mode neutralizes the adaptive knobs', () {
      const cfg = RankingConfig(mode: RankingMode.simple, exploration: 0.5);
      final eff = cfg.effectiveForMode();
      expect(eff.exploration, 0.0);
      expect(eff.weights.jitter, 0.0);
      expect(eff.weights.latency, 1.0);
    });

    test('weights are normalized, so scale alone does not change the ranking', () {
      final servers = <ServerNode>[node('a'), node('b')];
      final metrics = <String, ServerMetrics>{
        'a': withLatency(50, extra: 5),
        'b': withLatency(150, extra: 5),
      };
      final balanced = Ranker(config: const RankingConfig(mode: RankingMode.advanced))
          .rank(servers: servers, metrics: metrics, nowMs: 1000000);
      // Doubling every weight must give the same winner.
      final doubled = Ranker(
        config: const RankingConfig(mode: RankingMode.advanced).copyWith(
          weights: const RankingWeights(
            latency: 1.7,
            jitter: 0.9,
            reliability: 1.8,
            throughput: 1.0,
            freshness: 0.7,
            stability: 1.1,
            stickiness: 0.8,
          ),
        ),
      ).rank(servers: servers, metrics: metrics, nowMs: 1000000);
      expect(balanced.first.serverId, doubled.first.serverId);
    });

    test('json round trip', () {
      const cfg = RankingConfig(mode: RankingMode.simple, switchMargin: 0.2, probeConcurrency: 3);
      final back = RankingConfig.fromJson(cfg.toJson());
      expect(back.mode, RankingMode.simple);
      expect(back.switchMargin, 0.2);
      expect(back.probeConcurrency, 3);
      expect(back.weights.stickiness, cfg.weights.stickiness);
    });

    test('presets', () {
      expect(RankingWeights.preset('speed').latency, 1.0);
      expect(RankingWeights.preset('stability').reliability, 1.0);
      expect(RankingWeights.preset('nonsense').latency, RankingWeights.balancedPreset.latency);
    });
  });
}
