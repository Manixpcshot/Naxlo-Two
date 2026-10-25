import 'package:naxlo_core/naxlo_core.dart';
import 'package:test/test.dart';

ServerMetrics observed({
  required List<int> latencies,
  List<bool> ok = const <bool>[],
  int startMs = 0,
  int stepMs = 1000,
  int halfLifeMs = 90000,
  int bytes = 0,
}) {
  final m = ServerMetrics();
  for (var i = 0; i < latencies.length; i++) {
    final isOk = ok.isEmpty ? true : ok[i];
    final at = startMs + i * stepMs;
    if (!isOk) {
      m.observe(SamplePoint.failure(atMs: at, error: 'timeout'), halfLifeMs: halfLifeMs);
    } else {
      m.observe(
        SamplePoint.success(atMs: at, latencyMs: latencies[i], bytes: bytes),
        halfLifeMs: halfLifeMs,
      );
    }
  }
  return m;
}

void main() {
  group('ServerMetrics', () {
    test('a single sample becomes the estimate, not a shrunk version of it', () {
      final m = observed(latencies: <int>[100]);
      expect(m.latencyEwmaMs, closeTo(100, 0.001));
      expect(m.totalSamples, 1);
      expect(m.health, HealthState.healthy);
      // Jeffreys prior: 1 success out of (1+0.5 prior-ok, 0.5 prior-fail)
      expect(m.reliability, closeTo(1.5 / 2.0, 0.001));
    });

    test('EWMA is time-aware: a 1s gap barely moves, a 10-half-life gap resets', () {
      final m = ServerMetrics();
      m.observe(SamplePoint.success(atMs: 0, latencyMs: 100), halfLifeMs: 90000);
      m.observe(SamplePoint.success(atMs: 1000, latencyMs: 200), halfLifeMs: 90000);
      expect(m.latencyEwmaMs, closeTo(100.77, 0.05));

      m.observe(SamplePoint.success(atMs: 901000, latencyMs: 300), halfLifeMs: 90000);
      expect(m.latencyEwmaMs! > 295, isTrue, reason: 'ten half-lives of decay');
    });

    test('one half-life merges old and new 50/50 and defines jitter', () {
      final m = ServerMetrics();
      m.observe(SamplePoint.success(atMs: 0, latencyMs: 100), halfLifeMs: 90000);
      m.observe(SamplePoint.success(atMs: 90000, latencyMs: 200), halfLifeMs: 90000);
      expect(m.latencyEwmaMs, closeTo(150, 0.001));
      expect(m.jitterEwmaMs, closeTo(100, 0.001));
      expect(m.latencySdMs, closeTo(50, 0.001));
    });

    test('three consecutive failures mark the node down', () {
      final m = observed(latencies: <int>[0, 0, 0], ok: <bool>[false, false, false]);
      expect(m.consecutiveFailures, 3);
      expect(m.health, HealthState.down);
      expect(m.isDown, isTrue);
    });

    test('a failure long ago is forgotten, a failure now is not', () {
      final old = ServerMetrics();
      old.observe(SamplePoint.failure(atMs: 0, error: 'reset'), halfLifeMs: 90000);
      old.observe(SamplePoint.success(atMs: 900000, latencyMs: 90), halfLifeMs: 90000);
      // The decay is what this pins: the old failure has been forgotten. It shows
      // up in the *observed* rate (which has no prior to hide behind); the ranked
      // `reliability` stays shrunken toward 0.5 because there is still only one
      // sample either way.
      expect(old.observedRate > 0.9, isTrue, reason: 'both weights decayed, the failure is gone');
      expect(old.reliability > recent.reliability, isTrue);

      final recent = ServerMetrics();
      recent.observe(SamplePoint.failure(atMs: 900000, error: 'reset'), halfLifeMs: 90000);
      recent.observe(SamplePoint.success(atMs: 901000, latencyMs: 90), halfLifeMs: 90000);
      expect(recent.reliability < old.reliability, isTrue);
    });

    test('risk-adjusted reliability punishes tiny samples', () {
      final oneOk = observed(latencies: <int>[50]);
      final proven = observed(latencies: List<int>.filled(200, 50));
      expect(oneOk.observedRate, greaterThanOrEqualTo(proven.observedRate),
          reason: 'the raw rate looks perfect for 1/1 — which is why we do not rank on it');
      expect(oneOk.reliability, lessThan(proven.reliability),
          reason: 'the Jeffreys prior keeps a single success from reading as certain');
      expect(oneOk.reliabilityLcb < proven.reliabilityLcb, isTrue,
          reason: 'the lower bound is what we actually rank on');
    });

    test('bytes become kbit/s over the sample window', () {
      final m = observed(latencies: <int>[50, 55], bytes: 1000000, stepMs: 8000);
      // 1e6 bytes over 8s = 1 Mbit/s, and the first sample sets the estimate.
      expect(m.throughputKbps, closeTo(1000, 0.001));
    });

    test('json round trip keeps the estimates', () {
      final m = observed(latencies: <int>[80, 95, 88], bytes: 400000, stepMs: 5000);
      final back = ServerMetrics.fromJson(m.toJson());
      expect(back.latencyEwmaMs, closeTo(m.latencyEwmaMs!, 0.01));
      expect(back.jitterEwmaMs, closeTo(m.jitterEwmaMs!, 0.01));
      expect(back.okWeight, closeTo(m.okWeight, 0.01));
      expect(back.totalSamples, m.totalSamples);
      expect(back.health, m.health);
    });
  });

  group('ThompsonSampler', () {
    test('is deterministic for a fixed seed', () {
      final a = ThompsonSampler(seed: 7);
      final b = ThompsonSampler(seed: 7);
      for (var i = 0; i < 5; i++) {
        expect(a.beta(3, 2), b.beta(3, 2));
      }
      final c = ThompsonSampler(seed: 8);
      expect(a.beta(3, 2) == c.beta(3, 2), isFalse);
    });

    test('beta draws stay in range and track the mean', () {
      final s = ThompsonSampler(seed: 11);
      var sum = 0.0;
      for (var i = 0; i < 4000; i++) {
        final v = s.beta(8, 2);
        expect(v > 0 && v < 1, isTrue);
        sum += v;
      }
      expect(sum / 4000, closeTo(8 / 10, 0.03));
    });

    test('latency draws widen with variance and never go negative', () {
      final s = ThompsonSampler(seed: 3);
      var spread = 0.0;
      for (var i = 0; i < 500; i++) {
        spread += s.sampleLatencyMs(meanMs: 100, sdMs: 60);
      }
      expect(spread / 500 > 100, isTrue, reason: 'log-normal is right-skewed');
      expect(s.sampleLatencyMs(meanMs: 100, sdMs: 0), 100);
      expect(s.sampleLatencyMs(meanMs: 0, sdMs: 10) >= 1, isTrue);
    });
  });
}
