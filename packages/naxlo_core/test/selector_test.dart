import 'package:naxlo_core/naxlo_core.dart';
import 'package:test/test.dart';

RankedServer row(
  String id,
  double score, {
  bool current = false,
  bool eligible = true,
  HealthState health = HealthState.healthy,
  int ageMs = 1000,
}) {
  return RankedServer(
    serverId: id,
    score: score,
    rank: 1,
    health: health,
    components: const <String, double>{},
    isCurrent: current,
    isEligible: eligible,
    ageMs: ageMs,
  );
}

void main() {
  const cfg = RankingConfig(switchMargin: 0.06, dwellMs: 45000, cooldownMs: 120000, probeConcurrency: 3);
  const selector = ServerSelector(cfg);
  final now = DateTime.now().millisecondsSinceEpoch;

  group('ServerSelector', () {
    test('an empty candidate set yields no server instead of a crash', () {
      final d = selector.decide(
        ranked: <RankedServer>[row('a', 0.5, eligible: false)],
        state: const SelectionState(),
        nowMs: now,
      );
      expect(d.outcome, SelectOutcome.none);
      expect(d.serverId, isEmpty);
    });

    test('first selection takes the leader', () {
      final d = selector.decide(
        ranked: <RankedServer>[row('a', 0.7), row('b', 0.5)],
        state: const SelectionState(),
        nowMs: now,
      );
      expect(d.outcome, SelectOutcome.switched);
      expect(d.serverId, 'a');
    });

    test('a small lead does not justify a reconnect', () {
      final d = selector.decide(
        ranked: <RankedServer>[row('b', 0.52), row('a', 0.50, current: true)],
        state: const SelectionState(currentServerId: 'a'),
        nowMs: now,
      );
      expect(d.outcome, SelectOutcome.keep);
      expect(d.serverId, 'a');
      expect(d.reason, contains('staying put'));
      expect(d.marginNeeded, closeTo(0.06, 0.0001));
    });

    test('a real lead must still hold for the dwell window (anti-flap)', () {
      final d = selector.decide(
        ranked: <RankedServer>[row('b', 0.70), row('a', 0.50, current: true)],
        state: const SelectionState(currentServerId: 'a'),
        nowMs: now,
      );
      expect(d.outcome, SelectOutcome.keep);
      expect(d.waitMs, greaterThan(0));
      expect(d.reason, contains('anti-flap'));

      final after = selector.decide(
        ranked: <RankedServer>[row('b', 0.70), row('a', 0.50, current: true)],
        state: const SelectionState(
          currentServerId: 'a',
          betterCandidateId: 'b',
          betterSinceMs: 0,
          switchedAtMs: 0,
        ).copyWith(betterSinceMs: now - 50000, lastProbeRoundAtMs: 0, consecutiveSwitches: 0),
        nowMs: now,
      );
      expect(after.outcome, SelectOutcome.switched);
      expect(after.serverId, 'b');
    });

    test('cooldown suppresses a second switch right after the first', () {
      final d = selector.decide(
        ranked: <RankedServer>[row('b', 0.70), row('a', 0.50, current: true)],
        state: SelectionState(
          currentServerId: 'a',
          switchedAtMs: now - 5000,
          betterCandidateId: 'b',
          betterSinceMs: now - 60000,
          consecutiveSwitches: 0,
        ),
        nowMs: now,
      );
      expect(d.outcome, SelectOutcome.keep);
      expect(d.reason, contains('cooldown'));
    });

    test('a dead active node fails over immediately, bypassing dwell', () {
      final d = selector.decide(
        ranked: <RankedServer>[
          row('b', 0.60),
          row('a', 0.59, current: true, health: HealthState.down, eligible: false),
        ],
        state: SelectionState(currentServerId: 'a', switchedAtMs: now - 1000),
        nowMs: now,
      );
      expect(d.outcome, SelectOutcome.failover);
      expect(d.serverId, 'b');
    });

    test('the active node staying #1 is not reported as a switch', () {
      final d = selector.decide(
        ranked: <RankedServer>[row('a', 0.8, current: true), row('b', 0.4)],
        state: const SelectionState(currentServerId: 'a'),
        nowMs: now,
      );
      expect(d.outcome, SelectOutcome.keep);
      expect(d.reason, contains('still ranks #1'));
    });

    test('a manual pin is respected even when the pin is worse', () {
      final d = selector.decide(
        ranked: <RankedServer>[row('b', 0.9), row('a', 0.2, current: true)],
        state: const SelectionState(currentServerId: 'a'),
        nowMs: now,
        allowSwitch: false,
      );
      expect(d.outcome, SelectOutcome.keep);
      expect(d.serverId, 'a');
      expect(d.reason, contains('pinned'));
    });

    test('a pinned node that is gone releases the pin', () {
      final d = selector.decide(
        ranked: <RankedServer>[row('b', 0.9)],
        state: const SelectionState(currentServerId: 'a'),
        nowMs: now,
        allowSwitch: false,
      );
      expect(d.serverId, 'b');
      expect(d.outcome, SelectOutcome.switched);
    });

    test('repeated flip-flops raise the required margin', () {
      final calm = selector.decide(
        ranked: <RankedServer>[row('b', 0.60), row('a', 0.50, current: true)],
        state: SelectionState(
          currentServerId: 'a',
          switchedAtMs: now - 1000, // in cooldown, but we only inspect the margin
          consecutiveSwitches: 0,
        ),
        nowMs: now,
      );
      final flappy = selector.decide(
        ranked: <RankedServer>[row('b', 0.60), row('a', 0.50, current: true)],
        state: SelectionState(
          currentServerId: 'a',
          switchedAtMs: now - 1000,
          consecutiveSwitches: 3,
        ),
        nowMs: now,
      );
      expect(flappy.marginNeeded, greaterThan(calm.marginNeeded));
      expect(calm.reason, contains('needs'));
    });

    test('apply() records a switch and clears the dwell timer', () {
      // 'b' has been leading long enough to clear the dwell window, so decide()
      // must hand apply() a real switch — that is what makes "apply clears the
      // timer" an observable assertion rather than a pass through keep().
      final state = SelectionState(
        currentServerId: 'a',
        betterCandidateId: 'b',
        betterSinceMs: now - 50000,
        consecutiveSwitches: 0,
      );
      final decision = selector.decide(
        ranked: <RankedServer>[row('b', 0.70), row('a', 0.50, current: true)],
        state: state,
        nowMs: now,
      );
      final next = selector.apply(state, decision, nowMs: now);
      expect(next.currentServerId, decision.serverId);
      expect(next.betterSinceMs, 0);
      expect(next.betterCandidateId, isEmpty);
      expect(next.consecutiveSwitches, 1);
    });

    test('apply() keeps tracking a leader that has not won yet', () {
      final keep = selector.decide(
        ranked: <RankedServer>[row('b', 0.70), row('a', 0.50, current: true)],
        state: const SelectionState(currentServerId: 'a'),
        nowMs: now,
      );
      expect(keep.outcome, SelectOutcome.keep);
      final next = selector.apply(keep, const SelectionState(currentServerId: 'a'), nowMs: now);
      expect(next.currentServerId, 'a');
      expect(next.betterCandidateId, 'b');
      expect(next.betterSinceMs, now);
    });
  });

  group('ProbeScheduler', () {
    const scheduler = ProbeScheduler(cfg);

    test('unmeasured nodes are probed before healthy ones', () {
      final plan = scheduler.plan(
        ranked: <RankedServer>[
          row('known', 0.9, ageMs: 0),
          row('ghost', 0.5),
        ],
        ageByServer: <String, int>{'known': now},
        nowMs: now,
      );
      expect(plan.first, 'ghost');
    });

    test('the active node is kept fresh', () {
      final plan = scheduler.plan(
        ranked: <RankedServer>[row('active', 0.9), row('idle', 0.8)],
        ageByServer: <String, int>{'active': now - 30000, 'idle': now - 40000},
        nowMs: now,
        currentServerId: 'active',
      );
      expect(plan.first, 'active');
    });

    test('dead nodes back off instead of being hammered', () {
      final plan = scheduler.plan(
        ranked: <RankedServer>[
          row('dead', 0.1, health: HealthState.down, eligible: false),
          row('fine', 0.7),
        ],
        ageByServer: <String, int>{'dead': now - 60000, 'fine': now - 59000},
        nowMs: now,
      );
      expect(plan.contains('dead'), isFalse, reason: 'needs * 0.35 falls under the floor');
    });

    test('the plan respects the concurrency budget', () {
      final many = <RankedServer>[for (var i = 0; i < 25; i++) row('n$i', 0.5)];
      final plan = scheduler.plan(
        ranked: many,
        ageByServer: <String, int>{},
        nowMs: now,
      );
      expect(plan.length, lessThanOrEqualTo(3));
    });
  });
}
