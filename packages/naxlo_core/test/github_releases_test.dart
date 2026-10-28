import 'dart:convert';

import 'package:naxlo_core/naxlo_core.dart';
import 'package:test/test.dart';

/// The GitHub-backed update source, tested against the *real* shape of the API
/// response for this repository (v0.3.0's asset names, sizes and digests), plus
/// the ordering rules `decide` has to keep honouring once two sources are merged.
void main() {
  Map<String, Object?> asset(
    String name, {
    String digest = 'sha256:51202fb3065d83c86f8508fe679077315d6edabe99686509761e57dc6402ac75',
    int size = 39952829,
    String state = 'uploaded',
    String tag = 'v0.3.0',
  }) =>
      <String, Object?>{
        'name': name,
        'size': size,
        'digest': digest,
        'state': state,
        'browser_download_url': 'https://github.com/Manixpcshot/Naxlo-Two/releases/download/$tag/$name',
      };

  Map<String, Object?> release(
    String tag, {
    bool prerelease = false,
    bool draft = false,
    List<Object?> assets = const <Object?>[],
    String body = '## Naxlo Two\n- **fix** the ranking\n',
  }) =>
      <String, Object?>{
        'tag_name': tag,
        'name': 'Naxlo Two $tag',
        'body': body,
        'draft': draft,
        'prerelease': prerelease,
        'assets': assets,
      };

  group('GithubReleases asset selection', () {
    test('prefers the platform-native installer and never a checksum file', () {
      expect(GithubReleases.rank('windows', 'setup-Naxlo.x64.exe'), 0);
      expect(GithubReleases.rank('linux', 'Naxlo.linux.x64.deb') < GithubReleases.rank('linux', 'Naxlo.linux.x64.rpm'), isTrue);
      expect(GithubReleases.rank('android', 'Naxlo.android.arm64-v8a.apk') >= 0, isTrue);
      for (final platform in ReleaseManifest.kPlatforms) {
        expect(GithubReleases.rank(platform, 'SHA256SUMS.txt'), -1, reason: '$platform must never "download" a checksum');
        expect(GithubReleases.rank(platform, 'release'), -1);
        expect(GithubReleases.rank(platform, 'source.zip'), -1);
      }
    });

    test('reads the real v0.3.0 release into a per-platform manifest', () {
      final manifest = GithubReleases.manifestFrom(json.encode(<Object?>[
        release('v0.3.0', assets: <Object?>[
          asset('Naxlo.android.arm64-v8a.apk', size: 8035518, digest: 'sha256:15ff553c3928e8867fab592afd3e8048fe871360f548e40083c8b2f0705520df'),
          asset('Naxlo.apk', size: 22776781),
          asset('Naxlo.linux.x64.deb', size: 40108896, digest: 'sha256:69fe051fc20a0c02c8f865b15a6ea9551dbcec791a3bd481ad0bfdd362ce6f4b'),
          asset('Naxlo.linux.x64.rpm', size: 50530859),
          asset('setup-Naxlo.x64.exe', size: 39952829, digest: 'sha256:51202fb3065d83c86f8508fe679077315d6edabe99686509761e57dc6402ac75'),
          asset('SHA256SUMS.txt', size: 709),
        ]),
      ]));

      final windows = manifest.platform('windows')!.channelFor('stable')!;
      expect(windows.version, '0.3.0', reason: 'the v-prefix is stripped so Semver can compare it');
      expect(windows.assetName, 'setup-Naxlo.x64.exe');
      expect(windows.size, 39952829);
      expect(
        windows.sha256,
        '51202fb3065d83c86f8508fe679077315d6edabe99686509761e57dc6402ac75',
        reason: 'the digest GitHub computed, without its algorithm prefix',
      );
      expect(manifest.platform('linux')!.channelFor('stable')!.assetName, 'Naxlo.linux.x64.deb');
      expect(manifest.platform('android')!.channelFor('stable')!.assetName, 'Naxlo.android.arm64-v8a.apk');
      expect(manifest.platform('macos'), isNull, reason: 'v0.3.0 shipped no dmg, so macOS must not be offered an asset');
      expect(manifest.platform('ios'), isNull);
      expect(manifest.platform('windows')!.channelFor('beta'), isNull);
    });

    test('ignores drafts, half-uploaded assets and unhashed ones', () {
      final manifest = GithubReleases.manifestFrom(json.encode(<Object?>[
        release('v9.9.9', draft: true, assets: <Object?>[asset('setup-Naxlo.x64.exe')]),
        release('v0.3.1', assets: <Object?>[
          asset('setup-Naxlo.x64.exe', state: 'new'),
          asset('Naxlo.linux.x64.deb', digest: ''),
        ]),
      ]));
      expect(manifest.platform('windows'), isNull, reason: 'the only exe is in a draft release, then in state "new"');
      final linux = manifest.platform('linux')!.channelFor('stable')!;
      expect(linux.sha256, '', reason: 'a release published without a digest reports none rather than a guess');
    });

    test('sorts by version and not by the order GitHub returned', () {
      final manifest = GithubReleases.manifestFrom(json.encode(<Object?>[
        release('v0.2.17', assets: <Object?>[asset('setup-Naxlo.x64.exe', tag: 'v0.2.17')]),
        release('v0.10.0', assets: <Object?>[asset('setup-Naxlo.x64.exe', tag: 'v0.10.0')]),
        release('v0.9.0', assets: <Object?>[asset('setup-Naxlo.x64.exe', tag: 'v0.9.0')]),
      ]));
      expect(manifest.platform('windows')!.channelFor('stable')!.version, '0.10.0');
    });

    test('a prerelease lands on beta, so a stable client never sees it', () {
      final manifest = GithubReleases.manifestFrom(json.encode(<Object?>[
        release('v0.4.0-rc.1', prerelease: true, assets: <Object?>[asset('setup-Naxlo.x64.exe', tag: 'v0.4.0-rc.1')]),
        release('v0.3.0', assets: <Object?>[asset('setup-Naxlo.x64.exe', tag: 'v0.3.0')]),
      ]));
      final windows = manifest.platform('windows')!;
      expect(windows.channelFor('beta')!.version, '0.4.0-rc.1');
      expect(windows.channelFor('stable')!.version, '0.3.0');
      expect(
        windows.channelFor('beta')!.details,
        contains('fix'),
        reason: 'the release body is the changelog the dialog shows',
      );
    });

    test('a release with no matching asset contributes nothing', () {
      final manifest = GithubReleases.manifestFrom(json.encode(<Object?>[
        release('v1.0.0', assets: <Object?>[asset('notes.txt')]),
      ]));
      expect(manifest.platforms, isEmpty);
    });

    test('rate limits and captive portals degrade to "no information"', () {
      for (final body in <String>[
        '{"message":"API rate limit exceeded for 1.2.3.4.","documentation_url":"https://docs.github.com/rest"}',
        '<html><body>Sign in</body></html>',
        '',
        '[]',
        '{"tag_name": 42}',
      ]) {
        final manifest = GithubReleases.manifestFrom(body);
        expect(manifest.platforms, isEmpty, reason: 'must not read as up to date: $body');
        expect(
          manifest.decide(platform: 'windows', currentVersion: '0.3.0').action,
          UpdateAction.none,
        );
      }
    });
  });

  group('merging the inventory with the publisher policy', () {
    ReleaseManifest policy(String body) => ReleaseManifest.parse(body);

    test('the block list and the ratchet survive the merge', () {
      final inventory = GithubReleases.manifestFrom(json.encode(<Object?>[
        release('v0.4.0', assets: <Object?>[asset('setup-Naxlo.x64.exe', tag: 'v0.4.0')]),
      ]));
      final allowed = policy(json.encode(<String, Object?>{
        'windows': <String, Object?>{
          'block': <String>['0.3.0'],
          'stable': <String, Object?>{
            'version': '0.3.1',
            'link': 'https://example.invalid/old.exe',
            'update': <String, Object?>{'updateonly': '0.3.0'},
          },
        },
      }));
      final merged = inventory.withPolicy(allowed);

      expect(merged.decide(platform: 'windows', currentVersion: '0.3.0').action, UpdateAction.blocked);
      final d = merged.decide(platform: 'windows', currentVersion: '0.3.5');
      expect(d.available, '0.4.0', reason: 'the version comes from GitHub, not from the stale manifest');
      expect(d.downloadUrl, contains('github.com'));
      expect(d.sha256.length, 64, reason: 'integrity data comes from GitHub too');
      expect(merged.platform('windows')!.channelFor('stable')!.updateOnlyBelow, '0.3.0');
    });

    test('a block list still reaches a platform the inventory knows nothing about', () {
      final allowed = policy(json.encode(<String, Object?>{
        'windows': <String, Object?>{
          'block': <String>['0.3.0'],
          'stable': <String, Object?>{'version': '0.3.1', 'link': 'https://example.invalid/old.exe'},
        },
      }));
      const ReleaseManifest inventory = ReleaseManifest();
      final merged = inventory.withPolicy(allowed);
      expect(merged.decide(platform: 'windows', currentVersion: '0.3.0').action, UpdateAction.blocked);
    });

    test('an unreachable manifest cannot lift a block list', () {
      final inventory = GithubReleases.manifestFrom(json.encode(<Object?>[
        release('v0.4.0', assets: <Object?>[asset('setup-Naxlo.x64.exe', tag: 'v0.4.0')]),
      ]));
      expect(inventory.withPolicy(null).platforms.length, inventory.platforms.length);
    });

    test('the ratchet never turns into a forced downgrade', () {
      // A hand-edited manifest left `updateonly` covering the current version
      // while the newest release is *older* than what is running. This is the
      // case that, evaluated in the other order, downgrades an install forever.
      final inventory = GithubReleases.manifestFrom(json.encode(<Object?>[
        release('v0.3.0', assets: <Object?>[asset('setup-Naxlo.x64.exe', tag: 'v0.3.0')]),
      ]));
      final allowed = policy(json.encode(<String, Object?>{
        'windows': <String, Object?>{
          'stable': <String, Object?>{
            'version': '0.3.0',
            'link': 'https://example.invalid/setup.exe',
            'update': <String, Object?>{'updateonly': '0.9.0'},
          },
        },
      }));
      final d = inventory.withPolicy(allowed).decide(platform: 'windows', currentVersion: '0.9.0');
      expect(d.action, UpdateAction.none);
      expect(d.reason, contains('up to date'));
      expect(d.available, '0.3.0', reason: 'the banner can still say what the newest release is');
    });

    test('the decision carries what the UI needs to act, not just a version', () {
      final inventory = GithubReleases.manifestFrom(json.encode(<Object?>[
        release('v0.4.0', assets: <Object?>[asset('setup-Naxlo.x64.exe', tag: 'v0.4.0', size: 40000000)]),
      ]));
      final d = inventory.decide(platform: 'windows', currentVersion: '0.3.0');
      expect(d.action, UpdateAction.update);
      expect(d.assetName, 'setup-Naxlo.x64.exe');
      expect(d.size, 40000000);
      expect(d.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(d.minSupported, '');
    });
  });

  group('urls', () {
    test('are derived from owner/repo so a fork needs no code change', () {
      expect(GithubReleases.latestUrl(ownerOverride: 'someone', repoOverride: 'fork'),
          'https://api.github.com/repos/someone/fork/releases/latest');
      expect(GithubReleases.listUrl(perPage: 3), contains('per_page=3'));
      expect(GithubReleases.pageUrl(tag: 'v0.3.0'), endsWith('/releases/tag/v0.3.0'));
    });
  });
}
