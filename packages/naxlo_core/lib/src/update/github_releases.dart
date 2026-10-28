import 'dart:convert';

import '../json/json_utils.dart';
import 'release_manifest.dart';
import 'semver.dart';

/// GitHub's own Releases API, read as an update source.
///
/// Two sources, two jobs. The `release` manifest at the repo root is a
/// *publisher decision*: it can block a known-bad version, mark one forced, or
/// withhold a channel — none of which GitHub can express. The API is the
/// *inventory*: what the tag is, which assets exist, how big they are, and what
/// sha256 GitHub itself computed when the asset was uploaded. Reading the
/// inventory from GitHub means the updater's idea of "latest" cannot drift from
/// the repository's, and the digest being verified comes from the same store as
/// the bytes rather than from a file that anyone with write access could edit
/// next to them.
///
/// `UpdateService` fetches both and merges them with [ReleaseManifest.withPolicy]
/// — GitHub for what exists, the manifest for what is allowed.
abstract final class GithubReleases {
  /// The repository this app's releases live in. A fork needs these two strings
  /// and nothing else: every URL is derived from them.
  static const String owner = 'Manixpcshot';
  static const String repo = 'Naxlo-Two';

  static String apiBase({String ownerOverride = '', String repoOverride = ''}) {
    final o = ownerOverride.isEmpty ? owner : ownerOverride;
    final r = repoOverride.isEmpty ? repo : repoOverride;
    return 'https://api.github.com/repos/$o/$r/releases';
  }

  /// Newest published release, GitHub's own ordering.
  static String latestUrl({String ownerOverride = '', String repoOverride = ''}) =>
      '${apiBase(ownerOverride: ownerOverride, repoOverride: repoOverride)}/latest';

  /// Enough entries that a prerelease and a stable, several releases apart, are
  /// both in one response — the alternative is a second request per check.
  static String listUrl({int perPage = 8, String ownerOverride = '', String repoOverride = ''}) =>
      '${apiBase(ownerOverride: ownerOverride, repoOverride: repoOverride)}?per_page=$perPage';

  /// The page a human should be sent to when the app cannot install by itself.
  static String pageUrl({String tag = '', String ownerOverride = '', String repoOverride = ''}) {
    final String o = ownerOverride.isEmpty ? owner : ownerOverride;
    final String r = repoOverride.isEmpty ? repo : repoOverride;
    return 'https://github.com/$o/$r/releases${tag.isEmpty ? '/latest' : '/tag/$tag'}';
  }

  /// Parse a `/releases` (array) or `/releases/latest` (object) response.
  ///
  /// Returns an empty manifest — meaning "no update information", never "you are
  /// up to date" — for anything that is not the shape we expect: a rate-limit
  /// body, an HTML error page, or a truncated response all land here, and an
  /// updater that treats "I could not read it" as "nothing new" is how a fleet of
  /// installs silently stops updating.
  static ReleaseManifest manifestFrom(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return const ReleaseManifest();
    }
    final List<Object?> releases;
    if (decoded is List) {
      releases = decoded;
    } else if (decoded is Map) {
      releases = <Object?>[decoded];
    } else {
      return const ReleaseManifest();
    }

    final Map<String, Map<String, ReleaseChannel>> byPlatform = <String, Map<String, ReleaseChannel>>{};
    final List<_Release> parsed = <_Release>[];
    for (final Object? raw in releases) {
      final _Release? r = _Release.tryParse(asMap(raw));
      if (r != null) parsed.add(r);
    }
    // Newest first, by version rather than by the API's `created_at`: a release
    // edited last week has a *newer* `published_at` than the one that superseded
    // it, and "latest" is a statement about versions, not about timestamps.
    parsed.sort((a, b) => Semver.compare(b.version, a.version));

    for (final _Release r in parsed) {
      final String channel = r.prerelease ? 'beta' : 'stable';
      for (final String platform in ReleaseManifest.kPlatforms) {
        final _Asset? asset = r.bestAsset(platform);
        if (asset == null) continue;
        final Map<String, ReleaseChannel> channels =
            byPlatform.putIfAbsent(platform, () => <String, ReleaseChannel>{});
        // First one wins per (platform, channel), and `parsed` is newest-first —
        // so the newest release that actually ships an artifact for this platform
        // is what the user is offered, rather than a release that was tagged with
        // only a source tarball.
        if (channels.containsKey(channel)) continue;
        channels[channel] = ReleaseChannel(
          version: r.version,
          link: asset.url,
          details: r.body,
          sha256: asset.sha256,
          size: asset.size,
        );
      }
    }

    return ReleaseManifest(
      platforms: <String, PlatformReleases>{
        for (final e in byPlatform.entries)
          e.key: PlatformReleases(channels: e.value),
      },
    );
  }

  /// Which asset name means "the installer for this platform", best first.
  ///
  /// The order mirrors the selection in `scripts/gen_release_manifest.sh`, which
  /// writes the repo's manifest; `GithubReleasesTest` feeds the real asset list
  /// through both so the two cannot drift apart in silence. Anything not listed
  /// here is never offered: `SHA256SUMS.txt` and the manifest itself are release
  /// assets too, and "latest Windows installer" resolving to a checksum file is a
  /// supply-chain bug that would look like a corrupt download.
  static const Map<String, List<RegExp>> assetPatterns = <String, List<RegExp>>{
    'windows': <RegExp>[
      RegExp(r'^setup-Naxlo\.x64\.exe$', caseSensitive: false),
      RegExp(r'(?i)^naxlo.*x64.*\.exe$'),
      RegExp(r'(?i)setup.*\.exe$'),
    ],
    'macos': <RegExp>[
      RegExp(r'(?i)universal\.dmg$'),
      RegExp(r'(?i)\.dmg$'),
      RegExp(r'(?i)\.pkg$'),
    ],
    'linux': <RegExp>[
      RegExp(r'(?i)(x64|amd64)\.deb$'),
      RegExp(r'(?i)\.deb$'),
      RegExp(r'(?i)\.AppImage$'),
      RegExp(r'(?i)\.rpm$'),
      RegExp(r'(?i)\.pkg\.tar\.zst$'),
    ],
    'android': <RegExp>[
      RegExp(r'(?i)universal.*\.apk$'),
      RegExp(r'(?i)arm64-v8a.*\.apk$'),
      RegExp(r'(?i)^naxlo.*\.apk$'),
      RegExp(r'(?i)\.apk$'),
    ],
    'ios': <RegExp>[RegExp(r'(?i)\.ipa$')],
  };

  /// The rank of `name` for `platform`, or -1 when it is not an installer.
  static int rank(String platform, String name) {
    final List<RegExp>? patterns = assetPatterns[platform];
    if (patterns == null) return -1;
    for (int i = 0; i < patterns.length; i++) {
      if (patterns[i].hasMatch(name)) return i;
    }
    return -1;
  }
}

class _Release {
  const _Release({
    required this.version,
    required this.tag,
    required this.body,
    required this.prerelease,
    required this.assets,
  });

  final String version;
  final String tag;
  final String body;
  final bool prerelease;
  final List<_Asset> assets;

  static _Release? tryParse(Map<String, Object?> json) {
    if (asBool(json['draft'])) return null;
    final String tag = asString(json['tag_name']);
    if (tag.isEmpty) return null;
    // A release renamed to `v0.4.0-beta.1` still has to compare correctly, so the
    // version is the *parsed* semver rather than the tag with a prefix chopped off.
    final Semver? semver = Semver.tryParse(tag);
    if (semver == null) return null;
    final List<_Asset> assets = <_Asset>[];
    for (final Object? raw in asList(json['assets'])) {
      final _Asset? a = _Asset.tryParse(asMap(raw));
      if (a != null) assets.add(a);
    }
    return _Release(
      version: semver.toString(),
      tag: tag,
      body: asString(json['body']),
      prerelease: asBool(json['prerelease']),
      assets: assets,
    );
  }

  /// The best-matching, fully-uploaded asset for `platform`.
  _Asset? bestAsset(String platform) {
    _Asset? best;
    int bestRank = 1 << 30;
    for (final _Asset a in assets) {
      final int r = GithubReleases.rank(platform, a.name);
      if (r < 0) continue;
      if (r < bestRank) {
        bestRank = r;
        best = a;
      }
    }
    return best;
  }
}

class _Asset {
  const _Asset({required this.name, required this.url, required this.sha256, required this.size});

  final String name;
  final String url;
  final String sha256;
  final int size;

  static _Asset? tryParse(Map<String, Object?> json) {
    final String url = asString(json['browser_download_url']);
    final String name = asString(json['name']);
    if (url.isEmpty || name.isEmpty) return null;
    // `state` is `new` while an upload is still being assembled, and a `new`
    // asset can 404 or serve partial bytes.
    final String state = asString(json['state']);
    if (state.isNotEmpty && state != 'uploaded') return null;
    return _Asset(
      name: name,
      url: url,
      sha256: _digest(json['digest']),
      size: asInt(json['size']),
    );
  }

  /// GitHub reports `sha256:<hex>`. Anything else (a bare hex from an older
  /// proxy, an empty string when the digest was never computed) yields '' — and an
  /// empty digest is what [UpdateService] uses to refuse to auto-install: announcing
  /// a version is safe, running unverified bytes is not.
  static String _digest(Object? value) {
    final String raw = asString(value).trim().toLowerCase();
    if (raw.isEmpty) return '';
    final int colon = raw.indexOf(':');
    final String prefix = colon < 0 ? '' : raw.substring(0, colon);
    if (prefix.isNotEmpty && prefix != 'sha256') return '';
    final String hex = colon < 0 ? raw : raw.substring(colon + 1);
    final String trimmed = hex.trim();
    return RegExp(r'^[0-9a-f]{64}$').hasMatch(trimmed) ? trimmed : '';
  }
}
