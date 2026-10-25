import 'dart:convert';

import '../json/json_utils.dart';
import 'semver.dart';

/// One channel entry of the update manifest — the same shape as the `release`
/// file the Happ repositories ship, extended with integrity fields.
class ReleaseChannel {
  const ReleaseChannel({
    required this.version,
    required this.link,
    this.details = '',
    this.sha256 = '',
    this.size = 0,
    this.minSupported = '',
    this.warnAlwaysBelow = '',
    this.updateOnlyBelow = '',
  });

  final String version;

  /// Direct installer URL (a GitHub release asset, usually).
  final String link;

  /// Markdown-ish changelog body shown in the update dialog.
  final String details;
  final String sha256;

  /// Bytes; lets the UI show progress and refuse truncated downloads.
  final int size;

  /// Refuse to run below this version (protocol break).
  final String minSupported;

  /// Nudge (non-blocking banner) for everyone below this version.
  final String warnAlwaysBelow;

  /// Force the update for everyone at or below this version.
  final String updateOnlyBelow;

  Semver? get semver => Semver.tryParse(version);

  bool isForced(String currentVersion) {
    if (updateOnlyBelow.isEmpty) return false;
    final cur = Semver.tryParse(currentVersion);
    final limit = Semver.tryParse(updateOnlyBelow);
    if (cur == null || limit == null) return false;
    return cur.compareTo(limit) <= 0;
  }

  bool isBlocked(String currentVersion) {
    if (minSupported.isEmpty) return false;
    final cur = Semver.tryParse(currentVersion);
    final min = Semver.tryParse(minSupported);
    if (cur == null || min == null) return false;
    return cur.compareTo(min) < 0;
  }

  Map<String, Object?> toJson() => pruneNulls(<String, Object?>{
        'version': version,
        'link': link,
        'details': details,
        'sha256': sha256,
        'size': size == 0 ? null : size,
        'minSupported': minSupported,
        'update': pruneNulls(<String, Object?>{
          'warnalways': warnAlwaysBelow,
          'updateonly': updateOnlyBelow,
        }),
      });

  static ReleaseChannel fromJson(Map<String, Object?> json) {
    final update = asMap(json['update']);
    return ReleaseChannel(
      version: asString(json['version']),
      link: asString(json['link']),
      details: asString(json['details']),
      sha256: asString(json['sha256']),
      size: asInt(json['size']),
      minSupported: asString(json['minSupported']),
      warnAlwaysBelow: asString(update['warnalways']),
      updateOnlyBelow: asString(update['updateonly']),
    );
  }
}

/// A platform's set of channels, plus the block list of known-bad versions.
class PlatformReleases {
  const PlatformReleases({this.block = const <String>[], this.channels = const <String, ReleaseChannel>{}});

  final List<String> block;
  final Map<String, ReleaseChannel> channels;

  ReleaseChannel? channelFor(String name) => channels[name];

  /// Stable first, then beta — mirrors how the manifest is authored.
  ReleaseChannel? get preferred {
    final stable = channels['stable'];
    if (stable != null) return stable;
    final beta = channels['beta'];
    if (beta != null) return beta;
    if (channels.isEmpty) return null;
    return channels.values.first;
  }

  bool isBlocked(String version) => block.contains(version);

  Map<String, Object?> toJson() => <String, Object?>{
        'block': List<String>.from(block),
        for (final e in channels.entries) e.key: e.value.toJson(),
      };

  static PlatformReleases fromJson(Map<String, Object?> json) {
    final channels = <String, ReleaseChannel>{};
    json.forEach((key, value) {
      if (key == 'block') return;
      if (value is Map && value.isNotEmpty) {
        channels[key] = ReleaseChannel.fromJson(asMap(value));
      }
    });
    return PlatformReleases(
      block: asStringList(json['block']),
      channels: channels,
    );
  }
}

/// Verdict the UI acts on.
enum UpdateAction {
  none('none'),
  notify('notify'),
  update('update'),
  force('force'),
  blocked('blocked');

  const UpdateAction(this.wireName);
  final String wireName;
}

class UpdateDecision {
  const UpdateDecision({
    required this.action,
    required this.reason,
    this.available = '',
    this.downloadUrl = '',
    this.details = '',
  });

  final UpdateAction action;
  final String reason;
  final String available;
  final String downloadUrl;
  final String details;

  bool get shouldPrompt => action == UpdateAction.update || action == UpdateAction.force;
  bool get isBlocking => action == UpdateAction.force || action == UpdateAction.blocked;

  @override
  String toString() => '${action.wireName}: $reason';
}

/// The `release` file at the repo root.
///
/// Deliberately compatible with the manifest format Happ clients already read:
/// `{app, filenum, <platform>: {block, beta, stable, ...}}`. Keeping the shape
/// means users who script their updates can point their tooling at either, and
/// it makes the "regenerate on every release" CI step a 10-line diff.
class ReleaseManifest {
  const ReleaseManifest({
    this.app = 'naxlo_two',
    this.filenum = 1,
    this.generatedAt = '',
    this.platforms = const <String, PlatformReleases>{},
  });

  final String app;
  final int filenum;
  final String generatedAt;
  final Map<String, PlatformReleases> platforms;

  static const List<String> kPlatforms = <String>['windows', 'macos', 'linux', 'android', 'ios'];

  PlatformReleases? platform(String name) => platforms[name];

  /// Decide what to do about updates for `platform`/`channel` given the running
  /// `currentVersion`.
  ///
/// Ordering matters: a blocked build must be told to move *even if* the
  /// manifest also offers an optional update, and a version that is already the
  /// newest must never nag (that is how update loops start).
  UpdateDecision decide({
    required String platform,
    required String currentVersion,
    String channel = 'stable',
    bool includePrerelease = false,
  }) {
    final releases = platforms[platform];
    if (releases == null) {
      return const UpdateDecision(action: UpdateAction.none, reason: 'no entries for this platform');
    }
    if (releases.isBlocked(currentVersion)) {
      final chan = releases.channelFor(channel) ?? releases.preferred;
      return UpdateDecision(
        action: UpdateAction.blocked,
        reason: 'version $currentVersion is blocked by the publisher',
        available: chan?.version ?? '',
        downloadUrl: chan?.link ?? '',
        details: chan?.details ?? '',
      );
    }
    final entry = releases.channelFor(channel) ?? releases.preferred;
    if (entry == null || entry.version.isEmpty) {
      return const UpdateDecision(action: UpdateAction.none, reason: 'manifest has no release for this channel');
    }
    final latest = Semver.tryParse(entry.version);
    final mine = Semver.tryParse(currentVersion);
    if (latest == null || mine == null) {
      return UpdateDecision(
        action: UpdateAction.none,
        reason: 'unparseable version "${entry.version}" in manifest',
      );
    }
    if (entry.isForced(currentVersion)) {
      return UpdateDecision(
        action: UpdateAction.force,
        reason: 'this build is older than the update-only cutoff',
        available: entry.version,
        downloadUrl: entry.link,
        details: entry.details,
      );
    }
    final isPrerelease = latest.preRelease.isNotEmpty;
    if (isPrerelease && !includePrerelease) {
      return UpdateDecision(
        action: UpdateAction.none,
        reason: 'only a prerelease ($latest) exists; prereleases are off',
      );
    }
    if (mine.compareTo(latest) >= 0) {
      return UpdateDecision(
        action: UpdateAction.none,
        reason: 'up to date ($mine)',
      );
    }
    final warnBelow = Semver.tryParse(entry.warnAlwaysBelow);
    final optional = warnBelow != null && mine.compareTo(warnBelow) <= 0;
    return UpdateDecision(
      action: UpdateAction.update,
      reason: optional
          ? '$latest is available and your version is in the nag range'
          : '$latest is available',
      available: entry.version,
      downloadUrl: entry.link,
      details: entry.details,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'app': app,
        'filenum': filenum,
        if (generatedAt.isNotEmpty) 'generatedAt': generatedAt,
        for (final e in platforms.entries) e.key: e.value.toJson(),
      };

  static ReleaseManifest parse(String body) {
    if (body.trim().isEmpty) return const ReleaseManifest();
    final decoded = jsonDecode(body);
    if (decoded is! Map) return const ReleaseManifest();
    final json = <String, Object?>{for (final e in decoded.entries) e.key.toString(): e.value};
    final platforms = <String, PlatformReleases>{};
    for (final name in kPlatforms) {
      if (json.containsKey(name)) platforms[name] = PlatformReleases.fromJson(asMap(json[name]));
    }
    return ReleaseManifest(
      app: asString(json['app'], fallback: 'naxlo_two'),
      filenum: asInt(json['filenum'], fallback: 1),
      generatedAt: asString(json['generatedAt']),
      platforms: platforms,
    );
  }
}
