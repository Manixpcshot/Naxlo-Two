import 'dart:convert';

import 'package:naxlo_core/naxlo_core.dart';
import 'package:test/test.dart';

void main() {
  group('Semver', () {
    test('compares numerically, not lexically', () {
      expect(Semver.compare('1.10.0', '1.9.0') > 0, isTrue);
      expect(Semver.compare('1.2.10', '1.2.9') > 0, isTrue);
      expect(Semver.compare('2.0.0', '10.0.0') < 0, isTrue);
    });

    test('follows pre-release precedence rules', () {
      expect(Semver.compare('1.0.0-rc.1', '1.0.0') < 0, isTrue);
      expect(Semver.compare('1.0.0-rc.2', '1.0.0-rc.1') > 0, isTrue);
      expect(Semver.compare('1.0.0-rc.10', '1.0.0-rc.9') > 0, isTrue);
      expect(Semver.compare('1.0.0-alpha', '1.0.0-1') > 0, isTrue, reason: 'numeric identifiers rank lower');
      expect(Semver.compare('1.0.0-rc.1+bld', '1.0.0-rc.1+other') == 0, isTrue, reason: 'build ignored');
    });

    test('tolerates v-prefix, missing patch and junk', () {
      expect(Semver.tryParse('v1.2').toString(), '1.2.0');
      expect(Semver.tryParse('1.2.3final').toString(), '1.2.3', reason: 'trailing junk is ignored');
      expect(Semver.tryParse('nonsense'), isNull);
      expect(Semver.tryParse(''), isNull);
    });

    test('next() bumps one component and resets the rest', () {
      const v = Semver(1, 4, 7);
      expect(v.next('major').toString(), '2.0.0');
      expect(v.next('minor').toString(), '1.5.0');
      expect(v.next('patch').toString(), '1.4.8');
      expect(v.next('prerelease').toString(), '1.4.7-rc.1');
      expect(Semver(1, 0, 0, preRelease: 'rc.3').next('prerelease').toString(), '1.0.0-rc.4');
    });
  });

  group('ReleaseManifest', () {
    final manifest = ReleaseManifest.parse(json.encode(<String, Object?>{
      'app': 'naxlo_two',
      'filenum': 7,
      'windows': <String, Object?>{
        'block': <String>['0.0.9'],
        'stable': <String, Object?>{
          'version': '1.2.0',
          'link': 'https://example.com/setup-Naxlo.x64.exe',
          'details': '- fix ranking\n- new theme',
          'sha256': 'deadbeef',
          'update': <String, Object?>{'warnalways': '1.0.0', 'updateonly': '0.9.0'},
        },
      },
      'linux': <String, Object?>{
        'block': <String>[],
        'beta': <String, Object?>{'version': '1.3.0-rc.1', 'link': 'https://example.com/n.deb'},
      },
    }));

    test('reads every platform and channel', () {
      expect(manifest.app, 'naxlo_two');
      expect(manifest.filenum, 7);
      final windows = manifest.platform('windows')!;
      expect(windows.channelFor('stable')!.version, '1.2.0');
      expect(windows.channelFor('stable')!.sha256, 'deadbeef');
      expect(manifest.platform('macos'), isNull);
    });

    test('tells an up-to-date client to stop nagging', () {
      final d = manifest.decide(platform: 'windows', currentVersion: '1.2.0');
      expect(d.action, UpdateAction.none);
      expect(d.reason, contains('up to date'));
    });

    test('offers an update from newer to newest', () {
      final d = manifest.decide(platform: 'windows', currentVersion: '1.1.0');
      expect(d.action, UpdateAction.update);
      expect(d.shouldPrompt, isTrue);
      expect(d.downloadUrl, endsWith('.exe'));
      expect(d.details, contains('ranking'));
    });

    test('forces the update below the cutoff', () {
      final d = manifest.decide(platform: 'windows', currentVersion: '0.9.0');
      expect(d.action, UpdateAction.force);
      expect(d.isBlocking, isTrue);
    });

    test('blocks a known-bad build even when nothing newer exists', () {
      final d = manifest.decide(platform: 'windows', currentVersion: '0.0.9');
      expect(d.action, UpdateAction.blocked);
      expect(d.isBlocking, isTrue);
    });

    test('does not push a prerelease onto a stable channel user', () {
      final d = manifest.decide(platform: 'linux', currentVersion: '1.0.0');
      expect(d.action, UpdateAction.none);
      expect(d.reason, contains('prerelease'));
      final opted = manifest.decide(platform: 'linux', currentVersion: '1.0.0', includePrerelease: true);
      expect(opted.action, UpdateAction.update);
      expect(opted.available, '1.3.0-rc.1');
    });

    test('missing platform is a no-op, not a crash', () {
      final d = manifest.decide(platform: 'macos', currentVersion: '1.0.0');
      expect(d.action, UpdateAction.none);
    });

    test('tolerates an empty or corrupt manifest', () {
      expect(ReleaseManifest.parse('').decide(platform: 'windows', currentVersion: '1.0.0').action, UpdateAction.none);
      expect(ReleaseManifest.parse('not json').platforms, isEmpty);
    });

    test('json round trip preserves the shape Happ tooling expects', () {
      final back = ReleaseManifest.parse(json.encode(manifest.toJson()));
      expect(back.platform('windows')!.channelFor('stable')!.link, startsWith('https://'));
      expect(back.platform('windows')!.isBlocked('0.0.9'), isTrue);
    });
  });

  group('ProfileBundle', () {
    Profile sample() => Profile(
          id: 'p1',
          name: 'Home',
          servers: <ServerNode>[
            ServerNode(id: 's1', name: 'A', address: '1.1.1.1', port: 443, protocol: ProxyProtocol.vless, userId: 'u'),
            ServerNode(id: 's2', name: 'B', address: '2.2.2.2', port: 443, protocol: ProxyProtocol.trojan, password: 'p'),
          ],
          selectedServerId: 's1',
        );

    test('round trips profiles, metrics, selection and settings', () {
      final metrics = ServerMetrics();
      metrics.observe(SamplePoint.success(atMs: 5, latencyMs: 77), halfLifeMs: 90000);
      final bundle = ProfileBundle(
        profiles: <Profile>[sample()],
        activeProfileId: 'p1',
        metricsByServer: <String, ServerMetrics>{'s1': metrics},
        selectionByProfile: <String, SelectionState>{'p1': const SelectionState(currentServerId: 's1', consecutiveSwitches: 2)},
        recentSamplesByServer: <String, List<SamplePoint>>{'s1': <SamplePoint>[SamplePoint.success(atMs: 5, latencyMs: 77)]},
        ranking: const RankingConfig(mode: RankingMode.simple, switchMargin: 0.1),
        settings: const RuntimeSettings(socksPort: 30000, proxyMode: ProxyMode.manual),
        savedAtMs: 12345,
      );
      final loaded = ProfileBundle.fromJson(json.decode(bundle.encode(pretty: false))! as Map<String, Object?>);
      expect(loaded.profiles.single.servers.length, 2);
      expect(loaded.active!.name, 'Home');
      expect(loaded.active!.selected!.id, 's1');
      expect(loaded.metricsByServer['s1']!.latencyMsRounded, 77);
      expect(loaded.selectionByProfile['p1']!.consecutiveSwitches, 2);
      expect(loaded.ranking.mode, RankingMode.simple);
      expect(loaded.ranking.switchMargin, 0.1);
      expect(loaded.settings.socksPort, 30000);
      expect(loaded.settings.proxyMode, ProxyMode.manual);
      expect(loaded.savedAtMs, 12345);
      expect(loaded.recentSamplesByServer['s1']!.single.latencyMs, 77);
    });

    test('drops metrics for nodes that no longer exist, keeps the rest', () {
      final m = (ServerMetrics()..observe(SamplePoint.success(atMs: 10, latencyMs: 50), halfLifeMs: 90000));
      final bundle = ProfileBundle(
        profiles: <Profile>[sample()],
        metricsByServer: <String, ServerMetrics>{'s1': m, 's2': m, 'ghost': m},
      );
      final pruned = bundle.pruned(nowMs: 10000, keepDays: 30);
      expect(pruned.metricsByServer.containsKey('ghost'), isFalse);
      expect(pruned.metricsByServer.containsKey('s1'), isTrue);
    });

    test('prunes history older than the retention window', () {
      final now = 1000000000000;
      final old = ServerMetrics()..observe(SamplePoint.success(atMs: now - 40 * 24 * 3600 * 1000, latencyMs: 50), halfLifeMs: 90000);
      final fresh = ServerMetrics()..observe(SamplePoint.success(atMs: now - 3600 * 1000, latencyMs: 60), halfLifeMs: 90000);
      final bundle = ProfileBundle(
        profiles: <Profile>[sample()],
        metricsByServer: <String, ServerMetrics>{'s1': old, 's2': fresh},
      );
      final pruned = bundle.pruned(nowMs: now, keepDays: 7);
      expect(pruned.metricsByServer.containsKey('s1'), isFalse, reason: '40 days old, retention is 7');
      expect(pruned.metricsByServer.containsKey('s2'), isTrue);
    });

    test('a deleted pinned node clears the pin but keeps the cooldown', () {
      final bundle = ProfileBundle(
        profiles: <Profile>[sample()],
        metricsByServer: <String, ServerMetrics>{},
        selectionByProfile: <String, SelectionState>{
          'p1': const SelectionState(currentServerId: 'removed', switchedAtMs: 999, consecutiveSwitches: 2),
        },
      );
      final pruned = bundle.pruned(nowMs: 1000, keepDays: 7);
      final st = pruned.selectionByProfile['p1']!;
      expect(st.currentServerId, isEmpty);
      expect(st.switchedAtMs, 999);
      expect(st.consecutiveSwitches, 2);
    });

    test('a corrupt file yields an empty bundle plus a reason, never a throw', () {
      final res = ProfileBundle.load('{ this is not json');
      expect(res.error, isNotEmpty);
      expect(res.bundle.profiles, isEmpty);
      expect(res.isFresh, isTrue);
    });

    test('a missing file is a fresh install', () {
      final res = ProfileBundle.load(null);
      expect(res.created, isTrue);
      expect(res.error, isEmpty);
    });

    test('v1 state files migrate instead of being discarded', () {
      final legacy = json.encode(<String, Object?>{
        'schema': 1,
        'activeProfileId': 'p1',
        'profiles': <Object?>[
          <String, Object?>{
            'id': 'p1',
            'name': 'Legacy',
            'servers': <Object?>[
              <String, Object?>{'id': 's1', 'name': 'A', 'address': '1.1.1.1', 'port': 443, 'protocol': 'vless', 'uuid': 'u'},
            ],
          },
        ],
        'metrics': <String, Object?>{
          's1': <String, Object?>{'ping': 120, 'ok': 4, 'fail': 1, 'n': 5},
        },
      });
      final loaded = ProfileBundle.load(legacy).bundle;
      expect(loaded.schemaVersion, ProfileBundle.kSchemaVersion);
      expect(loaded.profiles.single.name, 'Legacy');
      expect(loaded.profiles.single.servers.single.userId, 'u', reason: 'legacy `uuid` key');
      expect(loaded.metricsByServer['s1']!.latencyEwmaMs, closeTo(120, 0.001));
      expect(loaded.metricsByServer['s1']!.okWeight, 4);
    });
  });
}
