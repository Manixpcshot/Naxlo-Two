import 'dart:math' as math;

import '../config/ranking_config.dart';
import 'ranked_server.dart';

/// Persistent memory of the auto-selector.
///
/// Saved with the profile: without it, every app restart would re-shuffle the
/// active node and the hysteresis would be worthless.
class SelectionState {
  const SelectionState({
    this.currentServerId = '',
    this.switchedAtMs = 0,
    this.betterSinceMs = 0,
    this.betterCandidateId = '',
    this.lastProbeRoundAtMs = 0,
    this.consecutiveSwitches = 0,
    this.lastReason = '',
  });

  final String currentServerId;

  /// When we last moved traffic (used by `cooldownMs`).
  final int switchedAtMs;

  /// Since when the leader has been ahead of the current node by > margin.
  final int betterSinceMs;
  final String betterCandidateId;

  /// Timestamp of the last auto-switch decision round (for probe scheduling).
  final int lastProbeRoundAtMs;

  /// Backoff memory: many switches in a row means the network is the problem.
  final int consecutiveSwitches;
  final String lastReason;

  SelectionState copyWith({
    String? currentServerId,
    int? switchedAtMs,
    int? betterSinceMs,
    String? betterCandidateId,
    int? lastProbeRoundAtMs,
    int? consecutiveSwitches,
    String? lastReason,
  }) {
    return SelectionState(
      currentServerId: currentServerId ?? this.currentServerId,
      switchedAtMs: switchedAtMs ?? this.switchedAtMs,
      betterSinceMs: betterSinceMs ?? this.betterSinceMs,
      betterCandidateId: betterCandidateId ?? this.betterCandidateId,
      lastProbeRoundAtMs: lastProbeRoundAtMs ?? this.lastProbeRoundAtMs,
      consecutiveSwitches: consecutiveSwitches ?? this.consecutiveSwitches,
      lastReason: lastReason ?? this.lastReason,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'cur': currentServerId,
        'at': switchedAtMs,
        'since': betterSinceMs,
        'cand': betterCandidateId,
        'probe': lastProbeRoundAtMs,
        'flips': consecutiveSwitches,
        if (lastReason.isNotEmpty) 'why': lastReason,
      };

  static SelectionState fromJson(Map<String, Object?> json) {
    return SelectionState(
      currentServerId: _s(json['cur']),
      switchedAtMs: _i(json['at']),
      betterSinceMs: _i(json['since']),
      betterCandidateId: _s(json['cand']),
      lastProbeRoundAtMs: _i(json['probe']),
      consecutiveSwitches: _i(json['flips']),
      lastReason: _s(json['why']),
    );
  }

  static String _s(Object? v) => v is String ? v : (v == null ? '' : v.toString());
  static int _i(Object? v) => v is int ? v : (v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0);
}

enum SelectOutcome {
  keep('keep'),
  switched('switched'),
  failover('failover'),
  cleared('cleared'),
  none('none');

  const SelectOutcome(this.wireName);
  final String wireName;
}

/// Result of one selection round: what to use and why, phrased for humans.
class SelectionDecision {
  const SelectionDecision({
    required this.outcome,
    required this.serverId,
    required this.reason,
    this.score = 0,
    this.currentScore = 0,
    this.marginNeeded = 0,
    this.waitMs = 0,
    this.betterId = '',
  });

  final SelectOutcome outcome;

  /// Server to connect to. Empty means "nothing eligible".
  final String serverId;
  final String reason;
  final double score;
  final double currentScore;

  /// `switchMargin` (plus backoff) that a candidate must clear.
  final double marginNeeded;

  /// How long the current leader must keep leading before we act.
  final int waitMs;

  /// The node that outranks the incumbent, on a `keep`. Empty when the incumbent
  /// is still #1. Distinct from [serverId] (the node we *stay* on), which is why
  /// both exist: see [ServerSelector.apply].
  final String betterId;

  bool get changed => outcome == SelectOutcome.switched || outcome == SelectOutcome.failover;

  @override
  String toString() => '${outcome.wireName}: ${serverId.isEmpty ? "∅" : serverId} ($reason)';
}

/// The policy layer: scores say who is best, this decides whether to act.
///
/// Everything here exists to answer one question: *is changing the active node
/// worth the disruption?* A switch costs a reconnect, a TLS handshake and a
/// few hundred ms of stall, so a 1% score improvement must not trigger one.
/// Hence: margin + dwell + cooldown + escalating backoff after flip-flops.
class ServerSelector {
  const ServerSelector(this.config);

  final RankingConfig config;

  SelectionDecision decide({
    required List<RankedServer> ranked,
    required SelectionState state,
    int nowMs = 0,
    bool allowSwitch = true,
  }) {
    final now = nowMs > 0 ? nowMs : DateTime.now().millisecondsSinceEpoch;
    final candidates = ranked.where((r) => r.isEligible).toList(growable: false);
    if (candidates.isEmpty) {
      return const SelectionDecision(
        outcome: SelectOutcome.none,
        serverId: '',
        reason: 'no eligible server (all disabled or marked down)',
      );
    }

    final best = candidates.first;

    // Manual pin wins outright — the user said "stay here".
    if (state.currentServerId.isNotEmpty && !allowSwitch) {
      final pinned = candidates.where((r) => r.serverId == state.currentServerId).toList();
      if (pinned.isNotEmpty) {
        return SelectionDecision(
          outcome: SelectOutcome.keep,
          serverId: state.currentServerId,
          reason: 'pinned by user (auto-select off)',
          currentScore: pinned.first.score,
          score: pinned.first.score,
        );
      }
      return SelectionDecision(
        outcome: SelectOutcome.switched,
        serverId: best.serverId,
        reason: 'pinned node unavailable → ${best.serverId}',
        score: best.score,
      );
    }

    if (state.currentServerId.isEmpty) {
      return SelectionDecision(
        outcome: SelectOutcome.switched,
        serverId: best.serverId,
        reason: 'first selection: ${_pct(best.score)} score, rank #1',
        score: best.score,
      );
    }

    final currentMatches = candidates.where((r) => r.serverId == state.currentServerId).toList();
    if (currentMatches.isEmpty) {
      return SelectionDecision(
        outcome: SelectOutcome.failover,
        serverId: best.serverId,
        reason: 'active node not usable (disabled or down) → failover to ${best.serverId}',
        score: best.score,
      );
    }
    final current = currentMatches.first;

    // Dead node: fail immediately, but only if there is somewhere better to go.
    if (current.health.wireName == 'down') {
      if (current.isCurrent && best.serverId != current.serverId) {
        return SelectionDecision(
          outcome: SelectOutcome.failover,
          serverId: best.serverId,
          reason: 'active node reported unreachable; failing over (dwell bypassed)',
          score: best.score,
          currentScore: current.score,
        );
      }
    }

    if (best.serverId == current.serverId) {
      return SelectionDecision(
        outcome: SelectOutcome.keep,
        serverId: current.serverId,
        reason: 'active node still ranks #1 at ${_pct(current.score)}',
        currentScore: current.score,
        score: current.score,
      );
    }

    final gap = best.score - current.score;
    final margin = _effectiveMargin(state);

    if (gap < margin) {
      return SelectionDecision(
        outcome: SelectOutcome.keep,
        serverId: current.serverId,
        reason: 'leader ${best.serverId} is only ${_pct(gap)} ahead; needs ${_pct(margin)} → staying put',
        currentScore: current.score,
        score: best.score,
        marginNeeded: margin,
        betterId: best.serverId,
      );
    }

    final waiting = state.betterCandidateId == best.serverId && state.betterSinceMs > 0;
    final heldFor = waiting ? now - state.betterSinceMs : 0;
    final needDwell = math.max(0, config.dwellMs - heldFor);
    if (needDwell > 0) {
      return SelectionDecision(
        outcome: SelectOutcome.keep,
        serverId: current.serverId,
        reason: '${best.serverId} leads by ${_pct(gap)} but needs ${_sec(needDwell)} more of '
            'sustained lead (anti-flap dwell)',
        currentScore: current.score,
        score: best.score,
        marginNeeded: margin,
        waitMs: needDwell,
        betterId: best.serverId,
      );
    }

    final sinceSwitch = state.switchedAtMs == 0 ? config.cooldownMs : now - state.switchedAtMs;
    final cooldownLeft = math.max(0, _effectiveCooldown(state) - sinceSwitch);
    if (cooldownLeft > 0) {
      return SelectionDecision(
        outcome: SelectOutcome.keep,
        serverId: current.serverId,
        reason: 'switch ready, but in cooldown for ${_sec(cooldownLeft)} '
            '(${state.consecutiveSwitches} recent switches)',
        currentScore: current.score,
        score: best.score,
        marginNeeded: margin,
        waitMs: cooldownLeft,
        betterId: best.serverId,
      );
    }

    return SelectionDecision(
      outcome: SelectOutcome.switched,
      serverId: best.serverId,
      reason: '${_pct(gap)} better (${_pct(best.score)} vs ${_pct(current.score)}) held for '
          '${_sec(heldFor)} → switching',
      score: best.score,
      currentScore: current.score,
      marginNeeded: margin,
    );
  }

  /// Fold a decision back into the persistent state.
  SelectionState apply(SelectionState state, SelectionDecision decision, {required int nowMs}) {
    if (decision.serverId.isEmpty) return state;
    if (decision.outcome == SelectOutcome.keep) {
      // Track the *leader*, not `decision.serverId`. On a keep, `serverId` is the
      // node we stay on, so starting the dwell timer for it produced a timer for a
      // node that is by definition not a threat: the next round reset it again, and
      // automatic switching could therefore never happen at all.
      final leader = decision.betterId;
      final tracking = leader.isNotEmpty && leader != state.currentServerId;
      return state.copyWith(
        betterSinceMs: tracking
            ? (state.betterCandidateId == leader && state.betterSinceMs > 0
                ? state.betterSinceMs
                : nowMs)
            : 0,
        betterCandidateId: tracking ? leader : '',
        lastReason: decision.reason,
      );
    }
    final flipped = state.consecutiveSwitches + 1;
    return SelectionState(
      currentServerId: decision.serverId,
      switchedAtMs: nowMs,
      betterSinceMs: 0,
      betterCandidateId: '',
      lastProbeRoundAtMs: state.lastProbeRoundAtMs,
      consecutiveSwitches: flipped,
      lastReason: decision.reason,
    );
  }

  /// The margin grows after flip-flops: 6% → 12% → 18% … capped at 30%.
  double _effectiveMargin(SelectionState state) {
    final backoff = config.switchMargin * (1.0 + state.consecutiveSwitches * 0.5);
    return math.min(0.30, backoff).toDouble();
  }

  int _effectiveCooldown(SelectionState state) {
    final base = math.max(0, config.cooldownMs);
    if (state.consecutiveSwitches <= 1) return base;
    return math.min(15 * 60 * 1000, base * (1 << math.min(4, state.consecutiveSwitches - 1))).toInt();
  }

  static String _pct(double v) => '${(v * 100).toStringAsFixed(1)}%';
  static String _sec(int ms) => '${(ms / 1000).toStringAsFixed(ms < 10000 ? 1 : 0)}s';
}

/// Decides *which* servers to measure next and when.
///
/// Naive "probe everything every 10s" wastes battery and, worse, makes the
/// ranker's own probes the dominant signal (you rank what you measure most).
/// This scheduler probes unknown and suspicious nodes often, and healthy ones
/// rarely — with a hard concurrency cap.
class ProbeScheduler {
  const ProbeScheduler(this.config);

  final RankingConfig config;

  /// [ageByServer] is `lastSampleAtMs` per server id. Returns at most
  /// `probeConcurrency` ids, most-deserving first.
  List<String> plan({
    required List<RankedServer> ranked,
    required Map<String, int> ageByServer,
    required int nowMs,
    String currentServerId = '',
  }) {
    final budget = math.max(1, config.probeConcurrency);
    final scored = <_ProbePriority>[];
    for (final r in ranked) {
      final age = math.max(0, nowMs - (ageByServer[r.serverId] ?? 0));
      double need;
      if (r.health.wireName == 'unknown') {
        need = 1.0; // never measured → highest priority
      } else if (r.health.wireName == 'down' || r.consecutiveFailures > 0) {
        // back off from dead nodes: retry at 4× the interval, but not forever
        need = 0.8 * (age / (config.probeIntervalMs * 4.0)).clamp(0.0, 1.0).toDouble();
      } else {
        need = (age / math.max(1, config.probeIntervalMs)).clamp(0.0, 1.0).toDouble() * 0.6;
      }
      // The node carrying traffic must stay fresh: a stale "best" is a lie.
      if (r.serverId == currentServerId) need = math.min(1.0, need + 0.35);
      if (!r.isEligible) need *= 0.35;
      scored.add(_ProbePriority(r.serverId, need, age));
    }
    scored.sort((a, b) {
      final byNeed = b.need.compareTo(a.need);
      if (byNeed != 0) return byNeed;
      return b.ageMs.compareTo(a.ageMs);
    });
    return <String>[
      for (final p in scored.take(budget))
        if (p.need > 0.02) p.serverId,
    ];
  }
}

class _ProbePriority {
  const _ProbePriority(this.serverId, this.need, this.ageMs);
  final String serverId;
  final double need;
  final int ageMs;
}
