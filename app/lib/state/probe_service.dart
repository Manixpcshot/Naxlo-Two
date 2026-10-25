import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:naxlo_core/naxlo_core.dart';

import 'log_buffer.dart';

/// One measurement round for one node.
class ProbeOutcome {
  const ProbeOutcome({
    required this.serverId,
    required this.sample,
    required this.attempts,
  });

  final String serverId;
  final SamplePoint sample;

  /// Attempts that succeeded inside this round; 0 means "unreachable now".
  final int attempts;

  int get latencyMs => sample.latencyMs;
  bool get ok => sample.ok;
}

/// Measures nodes the way a user experiences them: time to get a usable tunnel.
///
/// What this does and does not prove:
///   * a plain TCP connect proves the port is open and gives the RTT;
///   * a TLS/Reality handshake additionally proves the server is speaking our
///     protocol with a matching SNI — which catches the most common "imported
///     but broken" cases (wrong SNI, wrong public key, wrong path);
///   * it does **not** validate credentials. A wrong UUID completes a TCP
///     handshake and then fails silently, so `connected-but-zero-bytes` is
///     detected by [TrafficTally] instead of by the prober.
///
/// Latency is the median of `probeSamples` attempts (default 3): the min flatters
/// a node that got lucky, the mean is dragged by one timeout, the median is what
/// the user feels.
class ProbeService {
  ProbeService({this.logs, this.concurrency = 6});

  final LogBuffer? logs;
  final int concurrency;

  final Set<String> _inFlight = <String>{};

  bool isProbing(String serverId) => _inFlight.contains(serverId);

  Future<SamplePoint> probeOnce(ServerNode node, {required int timeoutMs, required bool handshakeTls}) async {
    final started = Stopwatch()..start();
    Socket? socket;
    try {
      if (handshakeTls && node.hasTls) {
        final sni = node.tls.serverName.isEmpty ? node.address : node.tls.serverName;
        // The handshake is only worth its cost if it presents the same SNI the
        // tunnel will: a Reality/vhost server picks the backend from SNI, so a
        // probe that sent `node.address` instead would measure a different
        // machine — and for an IP-addressed Reality node it would measure no
        // server at all. `SecureSocket.connect` cannot override SNI (it uses the
        // connect host), so connect plain first and upgrade with `host:`.
        final context = SecurityContext(withTrustedRoots: false);
        // Only set ALPN when the node declares it: forcing `http/1.1` on a node
        // configured without ALPN can make a fronting server pick a different
        // backend, and the probe would then measure a connection the tunnel never
        // makes. (It also has to be a statement, not a cascade: the setter takes a
        // non-nullable list, and `null` was doing nothing useful here anyway.)
        if (node.tls.alpn.isNotEmpty) {
          context.setAlpnProtocols(node.tls.alpn, false);
        }
        socket = await Socket.connect(
          node.address,
          node.port,
          timeout: Duration(milliseconds: timeoutMs),
        );
        socket = await SecureSocket.secure(
          socket,
          context: context,
          host: sni,
          onBadCertificate: (_) => true, // measurement only; no payload crosses this socket
        );
      } else {
        socket = await Socket.connect(
          node.address,
          node.port,
          timeout: Duration(milliseconds: timeoutMs),
        );
      }
      started.stop();
      return SamplePoint.success(atMs: DateTime.now().millisecondsSinceEpoch, latencyMs: started.elapsedMilliseconds);
    } on SocketException catch (e) {
      started.stop();
      return SamplePoint.failure(
        atMs: DateTime.now().millisecondsSinceEpoch,
        error: e.osError?.message ?? e.message,
      );
    } on TimeoutException {
      started.stop();
      return SamplePoint.failure(atMs: DateTime.now().millisecondsSinceEpoch, error: 'timeout ${timeoutMs}ms');
    } on HandshakeException catch (e) {
      started.stop();
      return SamplePoint.failure(atMs: DateTime.now().millisecondsSinceEpoch, error: 'tls: ${e.message}');
    } on Object catch (e) {
      started.stop();
      return SamplePoint.failure(atMs: DateTime.now().millisecondsSinceEpoch, error: '$e');
    } finally {
      try {
        socket?.destroy();
      } on Object {
        // already dead
      }
    }
  }

  /// Median of [samples] attempts, with one TLS handshake on the last one when
  /// the node is encrypted (so a broken SNI/pbk is still caught without paying
  /// three handshakes per node per minute).
  Future<ProbeOutcome> probe(
    ServerNode node,
    RankingConfig cfg,
  ) async {
    if (!_inFlight.add(node.id)) {
      return ProbeOutcome(
        serverId: node.id,
        attempts: 0,
        sample: SamplePoint.failure(atMs: DateTime.now().millisecondsSinceEpoch, error: 'probe already running'),
      );
    }
    try {
      final attempts = math.max(1, cfg.probeSamples);
      final times = <int>[];
      String? lastError;
      for (var i = 0; i < attempts; i++) {
        final isLast = i == attempts - 1;
        final s = await probeOnce(
          node,
          timeoutMs: cfg.probeTimeoutMs,
          handshakeTls: isLast && node.hasTls,
        );
        if (s.ok) {
          times.add(s.latencyMs);
        } else {
          lastError = s.error;
        }
        if (i + 1 < attempts) {
          await Future<void>.delayed(const Duration(milliseconds: 60));
        }
      }
      final at = DateTime.now().millisecondsSinceEpoch;
      if (times.isEmpty) {
        return ProbeOutcome(
          serverId: node.id,
          attempts: 0,
          sample: SamplePoint.failure(atMs: at, error: lastError ?? 'unreachable'),
        );
      }
      times.sort((a, b) => a.compareTo(b));
      final median = times[times.length ~/ 2];
      return ProbeOutcome(
        serverId: node.id,
        attempts: times.length,
        sample: SamplePoint.success(atMs: at, latencyMs: median),
      );
    } finally {
      _inFlight.remove(node.id);
    }
  }

  /// Bounded-parallel probe round. The cap exists because "measure all 80 nodes"
  /// on a subscription plan is 80 SYN bursts, which middleboxes and hotel
  /// routers really do rate-limit — and a throttled probe round reads as
  /// "every node got 3× slower", poisoning the ranking.
  Future<List<ProbeOutcome>> probeMany(
    List<ServerNode> nodes,
    RankingConfig cfg, {
    void Function(ProbeOutcome)? onEach,
  }) async {
    if (nodes.isEmpty) return const <ProbeOutcome>[];
    final limit = math.max(1, math.min(concurrency, cfg.probeConcurrency));
    final results = <ProbeOutcome>[];
    final queue = List<ServerNode>.of(nodes);
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final node = queue.removeAt(0);
        final outcome = await probe(node, cfg);
        results.add(outcome);
        if (onEach != null) onEach(outcome);
      }
    }

    await Future.wait<void>(<Future<void>>[
      for (var i = 0; i < limit; i++) worker(),
    ]);
    return results;
  }
}

/// Runs the periodic measurement loop and feeds the ranker.
///
/// The loop is deliberately *not* "probe everything every N seconds": it asks
/// [ProbeScheduler] who deserves a measurement, so an idle healthy node is
/// re-checked rarely and a suspicious one often. That keeps a laptop fan quiet
/// and stops the probe traffic from dominating the estimates.
class ProbeLoop {
  ProbeLoop({
    required this.prober,
    required this.onSamples,
    required this.currentServerId,
    this.onTick,
  });

  final ProbeService prober;
  final void Function(List<ProbeOutcome>) onSamples;
  final String Function() currentServerId;
  final void Function()? onTick;

  Timer? _timer;
  bool _running = false;
  RankingConfig _cfg = RankingConfig.defaults;

  bool get isRunning => _timer != null;

  void configure(RankingConfig cfg) => _cfg = cfg;

  void start({Duration? interval}) {
    stop();
    final ms = math.max(5000, _cfg.probeIntervalMs);
    _timer = Timer.periodic(interval ?? Duration(milliseconds: ms), (_) => unawaited(runOnce()));
    unawaited(runOnce());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// One round. Returns how many nodes were measured; safe to call concurrently
  /// (a slow round that overlaps the next tick is skipped, not stacked).
  Future<int> runOnce({List<ServerNode>? only}) async {
    if (_running) return 0;
    _running = true;
    try {
      final nodes = only ?? const <ServerNode>[];
      if (nodes.isEmpty && only == null) return 0;
      if (nodes.isEmpty) return 0;
      onTick?.call();
      final outcomes = await prober.probeMany(nodes, _cfg);
      if (outcomes.isNotEmpty) onSamples(outcomes);
      return outcomes.length;
    } finally {
      _running = false;
    }
  }

  /// Probe exactly these nodes now, ignoring the schedule (the "Measure all"
  /// button, and the first run after an import when nothing has a score yet).
  Future<int> probeNow(List<ServerNode> nodes) async {
    if (nodes.isEmpty) return 0;
    final outcomes = await prober.probeMany(nodes, _cfg);
    onSamples(outcomes);
    return outcomes.length;
  }

  void dispose() => stop();
}
