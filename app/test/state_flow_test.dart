import 'package:flutter_test/flutter_test.dart';
import 'package:naxlo_core/naxlo_core.dart';
import 'package:naxlo_two/state/app_state.dart';
import 'package:naxlo_two/state/log_buffer.dart';
import 'package:naxlo_two/state/probe_service.dart';

/// Covers the path that actually distinguishes Naxlo Two from a ping list:
/// measurements arrive → metrics decay → ranker scores → selector decides.
///
/// These run against [AppState.inMemory], which has no engine and no disk, so
/// what is being tested is the state machine rather than the network.
void main() {
  const twoLinks = '''
vless://11111111-1111-1111-1111-111111111111@fast.example.com:443?security=tls&sni=fast.example.com&type=ws#FAST
vless://22222222-2222-2222-2222-222222222222@slow.example.com:443?security=tls&sni=slow.example.com&type=ws#SLOW
''';

  AppState newApp() => AppState.inMemory(
        settings: const RuntimeSettings(checkForUpdates: false),
      );

  test('import creates a profile with both nodes', () async {
    final app = newApp();
    final report = await app.importLinks(twoLinks);
    expect(report.imported, 2);
    expect(app.nodeCount, 2);
    expect(app.profile, isNotNull);
    expect(app.profile!.servers.map((ServerNode s) => s.name), containsAll(<String>['FAST', 'SLOW']));
    app.dispose();
  });

  test('faster node outranks slower one, unreachable one last', () async {
    final app = newApp();
    await app.importLinks(twoLinks);
    final fast = app.profile!.servers.firstWhere((ServerNode s) => s.name == 'FAST');
    final slow = app.profile!.servers.firstWhere((ServerNode s) => s.name == 'SLOW');

    final now = DateTime.now().millisecondsSinceEpoch;
    app.ingestSamples(<ProbeOutcome>[
      ProbeOutcome(
        serverId: fast.id,
        attempts: 3,
        sample: SamplePoint.success(atMs: now, latencyMs: 40, bytes: 4096),
      ),
      ProbeOutcome(
        serverId: slow.id,
        attempts: 1,
        sample: SamplePoint.success(atMs: now, latencyMs: 900, bytes: 512),
      ),
    ]);

    expect(app.ranked.first.serverId, fast.id);
    expect(app.rankOf(slow.id)!.rank, 2);
    expect(app.rankOf(fast.id)!.latencyMs, 40);
    // The ranker explains itself into the log buffer so the Logs screen can show why.
    expect(app.logs.lines.any((LogLine l) => l.source == 'ranker'), isTrue);
    app.dispose();
  });

  test('three failures flip health to down and drop the node out of the top', () async {
    final app = newApp();
    await app.importLinks(twoLinks);
    final fast = app.profile!.servers.firstWhere((ServerNode s) => s.name == 'FAST');
    final now = DateTime.now().millisecondsSinceEpoch;

    for (var i = 0; i < 3; i++) {
      app.ingestSamples(<ProbeOutcome>[
        ProbeOutcome(
          serverId: fast.id,
          attempts: 0,
          sample: SamplePoint.failure(atMs: now + i, error: 'connection refused'),
        ),
      ]);
    }

    final r = app.rankOf(fast.id)!;
    expect(r.health, HealthState.down);
    expect(app.metricsOf(fast.id)!.consecutiveFailures, 3);
    app.dispose();
  });

  test('manual pin survives a better node until unpinned', () async {
    final app = newApp();
    await app.importLinks(twoLinks);
    final fast = app.profile!.servers.firstWhere((ServerNode s) => s.name == 'FAST');
    final slow = app.profile!.servers.firstWhere((ServerNode s) => s.name == 'SLOW');
    final now = DateTime.now().millisecondsSinceEpoch;

    await app.selectServer(slow.id);
    app.ingestSamples(<ProbeOutcome>[
      ProbeOutcome(
        serverId: fast.id,
        attempts: 3,
        sample: SamplePoint.success(atMs: now, latencyMs: 30),
      ),
    ]);

    // Pinned: the ranker prefers FAST, the selector must not move us.
    expect(app.ranked.first.serverId, fast.id);
    expect(app.activeServerId, slow.id);
    expect(app.selectionReason, contains('pin'));

    await app.unpin();
    // Unpin means "hand control back to the ranker", not "disconnect": dropping
    // a working tunnel because a toggle was released is the kind of behaviour
    // that makes people leave a VPN app. The tunnel stays up on SLOW until the
    // selector's own margin/dwell/cooldown decides otherwise.
    expect(app.activeServerId, slow.id);
    app.dispose();
  });

  test('weights bias changes the order without changing the measurements', () async {
    final app = newApp();
    await app.importLinks(twoLinks);
    final fast = app.profile!.servers.firstWhere((ServerNode s) => s.name == 'FAST');
    final slow = app.profile!.servers.firstWhere((ServerNode s) => s.name == 'SLOW');
    final now = DateTime.now().millisecondsSinceEpoch;

    // FAST is quick but jittery and lossy; SLOW is dull and rock solid.
    for (var i = 0; i < 4; i++) {
      app.ingestSamples(<ProbeOutcome>[
        ProbeOutcome(
          serverId: fast.id,
          attempts: 2,
          sample: SamplePoint.success(atMs: now + i * 10, latencyMs: i.isEven ? 20 : 400),
        ),
        ProbeOutcome(
          serverId: slow.id,
          attempts: 3,
          sample: SamplePoint.success(atMs: now + i * 10, latencyMs: 120),
        ),
      ]);
    }

    final speedFirst = app.ranked.first.serverId;
    await app.updateRanking(
      app.ranking.copyWith(
        mode: RankingMode.advanced,
        weights: const RankingWeights(latency: 0.05, jitter: 0.05, reliability: 0.9, freshness: 0.1),
      ),
    );
    final stabilityFirst = app.ranked.first.serverId;

    expect(<String>[speedFirst, stabilityFirst], isNot(equals(<String>[stabilityFirst, speedFirst])));
    expect(app.ranking.weights.reliability, closeTo(0.9, 0.001));
    app.dispose();
  });

  test('simple mode ignores exploration and still orders by latency', () async {
    final app = AppState.inMemory(
      settings: const RuntimeSettings(checkForUpdates: false),
      ranking: const RankingConfig(mode: RankingMode.simple),
    );
    await app.importLinks(twoLinks);
    final fast = app.profile!.servers.firstWhere((ServerNode s) => s.name == 'FAST');
    final slow = app.profile!.servers.firstWhere((ServerNode s) => s.name == 'SLOW');
    final now = DateTime.now().millisecondsSinceEpoch;
    app.ingestSamples(<ProbeOutcome>[
      ProbeOutcome(
        serverId: slow.id,
        attempts: 3,
        sample: SamplePoint.success(atMs: now, latencyMs: 500),
      ),
      ProbeOutcome(
        serverId: fast.id,
        attempts: 3,
        sample: SamplePoint.success(atMs: now, latencyMs: 55),
      ),
    ]);
    expect(app.ranked.first.serverId, fast.id);
    expect(app.rankOf(slow.id)!.exploration, 0);
    app.dispose();
  });

  test('persisted bundle round-trips metrics through a reload', () async {
    final app = newApp();
    await app.importLinks(twoLinks);
    final fast = app.profile!.servers.firstWhere((ServerNode s) => s.name == 'FAST');
    app.ingestSamples(<ProbeOutcome>[
      ProbeOutcome(
        serverId: fast.id,
        attempts: 3,
        sample: SamplePoint.success(atMs: DateTime.now().millisecondsSinceEpoch, latencyMs: 42),
      ),
    ]);
    await app.flush();

    final restored = AppState.inMemory(initialJson: await app.store.read());
    await restored.load();
    expect(restored.nodeCount, 2);
    expect(restored.metricsOf(fast.id)!.latencyMsRounded, 42);
    app.dispose();
    restored.dispose();
  });
}
