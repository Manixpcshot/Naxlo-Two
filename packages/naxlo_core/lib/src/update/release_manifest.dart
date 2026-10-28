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

  /// Keep this channel's facts (version, link, digest, size) and take the
  /// publisher's *policy* from `policy` instead.
  ///
  /// The two update sources answer different questions: GitHub's Releases API
  /// knows which installer exists and what its sha256 is, but it cannot express
  /// "0.3.0 is known-bad, do not run it" — only the `release` manifest can.
  /// Merging them keeps the kill switch working while the version and the
  /// integrity data come from GitHub itself.
  ReleaseChannel withPolicy(ReleaseChannel? policy) {
    if (policy == null) return this;
    return ReleaseChannel(
      version: version,
      link: link,
      details: details.isEmpty ? policy.details : details,
      sha256: sha256.isEmpty ? policy.sha256 : sha256,
      size: size == 0 ? policy.size : size,
      minSupported: policy.minSupported,
      warnAlwaysBelow: policy.warnAlwaysBelow,
      updateOnlyBelow: policy.updateOnlyBelow,
    );
  }

  /// The installer file name, so a download is saved under something
  /// recognisable rather than a temporary UUID.
  String get assetName {
    final int slash = link.lastIndexOf('/');
    return slash < 0 ? '' : link.substring(slash + 1);
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

  /// Carry `policy`'s block list and per-channel policy fields onto this
  /// platform's channels while keeping this platform's versions and links. A
  /// channel that exists only in the policy is kept, so a version the publisher
  /// blocked stays blocked even when the inventory said nothing about it.
  PlatformReleases withPolicy(PlatformReleases? policy) {
    if (policy == null) return this;
    final Map<String, ReleaseChannel> merged = <String, ReleaseChannel>{};
    for (final MapEntry<String, ReleaseChannel> e in channels.entries) {
      merged[e.key] = e.value.withPolicy(policy.channelFor(e.key));
    }
    for (final MapEntry<String, ReleaseChannel> e in policy.channels.entries) {
      merged.putIfAbsent(e.key, () => e.value);
    }
    return PlatformReleases(block: block.isEmpty ? policy.block : block, channels: merged);
  }

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
    this.sha256 = '',
    this.size = 0,
    this.assetName = '',
    this.minSupported = '',
  });

  final UpdateAction action;
  final String reason;
  final String available;
  final String downloadUrl;
  final String details;

  /// Integrity hash of [downloadUrl] as the publisher reported it. Empty means
  /// nobody can vouch for the bytes, which is the difference between "download
  /// this and run it" and "here is a link, you decide".
  final String sha256;

  /// Advertised size in bytes, so a download can be called short before it runs.
  final int size;

  /// File name the installer should be saved under.
  final String assetName;

  /// The version this app must be at to keep working. Only ever set on a
  /// `blocked` decision, and shown because "update required" with no lower bound
  /// is not actionable information.
  final String minSupported;

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

  /// Keep this manifest's versions, links and digests, and take the *policy*
  /// (block lists, `minSupported`, the warn/force cutoffs) from `policy`.
  ///
  /// `policy == null` — the manifest URL unreachable or unparseable — returns
  /// this manifest unchanged rather than an empty one: a dead mirror must not be
  /// able to lift a block list, and must not be able to invent one either.
  ReleaseManifest withPolicy(ReleaseManifest? policy) {
    if (policy == null) return this;
    final Map<String, PlatformReleases> merged = <String, PlatformReleases>{};
    for (final String name in kPlatforms) {
      final PlatformReleases? mine = platforms[name];
      final PlatformReleases? theirs = policy.platforms[name];
      if (mine != null) {
        merged[name] = mine.withPolicy(theirs);
      } else if (theirs != null && theirs.block.isNotEmpty) {
        // Nothing installable for this platform, but a kill switch still has to
        // reach decide() — that is the entire point of a block list.
        merged[name] = PlatformReleases(block: theirs.block);
      }
    }
    return ReleaseManifest(
      app: app,
      filenum: filenum,
      generatedAt: generatedAt,
      platforms: merged,
    );
  }

  /// Decide what to do about updates for `platform`/`channel` given the running
  /// `currentVersion`.
  ///
  /// Ordering matters three ways: a blocked build must be told to move *even if*
  /// the manifest also offers an optional update; a version that is already the
  /// newest must never nag (that is how update loops start); and the
  /// `updateOnlyBelow` ratchet is only honoured for a version that is actually
  /// older than what is offered, because a ratchet pointing backwards would be a
  /// forced downgrade.
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
        minSupported: chan?.minSupported ?? '',
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
    // This ordering is deliberate, and it has to sit above the forced check:
    // `updateOnlyBelow` is a ratchet ("anything this old must leave"), not a
    // promise that the advertised version is newer. Checked first, a channel
    // left pointing at an older release — a manifest edited by hand, a rollback
    // of the last tag — would report a *forced downgrade*, and a client that
    // obeyed would drop its own version and then be told to drop again forever.
    if (mine.compareTo(latest) >= 0) {
      return UpdateDecision(
        action: UpdateAction.none,
        reason: 'up to date ($currentVersion)',
        available: entry.version,
        sha256: entry.sha256,
        size: entry.size,
        assetName: entry.assetName,
      );
    }
    if (entry.isForced(currentVersion)) {
      return UpdateDecision(
        action: UpdateAction.force,
        reason: 'this build is older than the update-only cutoff',
        available: entry.version,
        downloadUrl: entry.link,
        details: entry.details,
        sha256: entry.sha256,
        size: entry.size,
        assetName: entry.assetName,
      );
    }
    final isPrerelease = latest.preRelease.isNotEmpty;
    if (isPrerelease && !includePrerelease) {
      return UpdateDecision(
        action: UpdateAction.none,
        reason: 'only a prerelease ($latest) exists; prereleases are off',
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
      sha256: entry.sha256,
      size: entry.size,
      assetName: entry.assetName,
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
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      // A captive portal, a login page, a truncated download: all reach here as text
      // that is not JSON. Throwing would surface as a stack trace in the update
      // screen; an empty manifest means "no update information", which is the honest
      // answer and is never mistaken for "you are up to date".
      return const ReleaseManifest();
    }
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
