import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:naxlo_core/naxlo_core.dart';

/// The updater, wired to GitHub's own Releases API.
///
/// Two sources are read in parallel and merged, because they answer different
/// questions:
///
///   * **GitHub** (`api.github.com/repos/…/releases`) is the *inventory*: which
///     tag is newest, which installer belongs to it, how big it is, and the
///     sha256 GitHub itself computed while receiving the upload. The inventory
///     cannot drift from the repository, and the hash being checked comes from
///     the same store the bytes come from.
///   * the `release` manifest at the repo root is the *policy*: block lists and
///     the `updateOnlyBelow` ratchet, neither of which GitHub can express.
///
/// Each source is optional at runtime — [lastSource] says which one answered —
/// so a rate-limited API or a dead mirror degrades to the other instead of
/// turning into "no updates".
///
/// Security posture, since an updater is the one code path where "trust the
/// server" is genuinely dangerous:
///   * https only, for the check *and* for the download; a plain-http manifest
///     URL can announce a version, it can never get bytes onto disk;
///   * every response is capped in bytes and bounded by one timeout around the
///     whole read, so a server that opens a response and stops talking cannot
///     hang the app;
///   * the release asset's own name is stripped of path separators before it
///     becomes a file name, because that string arrives over the network;
///   * nothing is executed unless a sha256 was advertised and the downloaded
///     bytes match it. An announcement without a digest is still shown (the
///     version and the link are useful on their own) but the Install action is
///     withheld, and the UI says why.
class UpdateService {
  UpdateService({
    required this.platform,
    this.currentVersion = kNaxloVersion,
    this.client,
    this.githubOwner = '',
    this.githubRepo = '',
  });

  final String platform;
  final String currentVersion;

  /// Injectable for tests; when null a short-lived [HttpClient] is created per
  /// request so a hung connection can never leak into the next check.
  final HttpClient? client;

  /// Overrides for forks. Empty means "the upstream repository this app ships".
  final String githubOwner;
  final String githubRepo;

  ReleaseManifest? lastManifest;
  UpdateDecision? lastDecision;
  DateTime? lastCheckAt;
  String? lastError;

  /// Which source answered the last check, for the UI to show honestly. A
  /// settings screen that says "up to date" when the API rate-limited us is the
  /// classic way a fleet stops updating without anyone noticing.
  String lastSource = 'never checked';

  Uri get manifestUri => Uri.parse(kDefaultManifestUrl);

  Uri get githubUri =>
      Uri.parse(GithubReleases.listUrl(ownerOverride: githubOwner, repoOverride: githubRepo));

  /// The page to send a human to when the app must not install by itself
  /// (Android, or a release published without a digest).
  String get releasesPage =>
      GithubReleases.pageUrl(ownerOverride: githubOwner, repoOverride: githubRepo);

  /// Read both sources, merge, and decide.
  Future<UpdateDecision> check({
    String channel = 'stable',
    bool includePrerelease = false,
    Duration timeout = const Duration(seconds: 8),
    String? overrideUrl,
    bool useGithub = true,
  }) async {
    lastError = null;
    final Uri manifestTarget = overrideUrl == null ? manifestUri : Uri.parse(overrideUrl);
    final List<String> problems = <String>[];

    final List<ReleaseManifest?> results = await Future.wait<ReleaseManifest?>(<Future<ReleaseManifest?>>[
      _fetchManifest(manifestTarget, timeout: timeout, label: 'manifest', problems: problems),
      if (useGithub && overrideUrl == null)
        _fetchManifest(githubUri, timeout: timeout, label: 'github', problems: problems)
      else
        Future<ReleaseManifest?>.value(null),
    ]);

    final ReleaseManifest? policy = results.isNotEmpty ? results[0] : null;
    final ReleaseManifest? inventory = results.length > 1 ? results[1] : null;

    ReleaseManifest? merged;
    if (inventory != null && inventory.platforms.containsKey(platform)) {
      merged = inventory.withPolicy(policy);
      lastSource = policy == null ? 'github releases' : 'github releases + release manifest';
    } else if (policy != null) {
      merged = policy;
      lastSource = 'release manifest';
    } else if (inventory != null) {
      // The API answered and simply has no artifact for this platform (macOS is
      // the standing example: releases exist, a dmg does not). Saying "update
      // server unavailable" there would send a user to debug a working network,
      // so the empty inventory is kept and decide() reports it honestly.
      merged = inventory;
      lastSource = 'github releases (no asset for $platform)';
    } else {
      lastSource = 'nothing reachable';
      lastError = problems.isEmpty ? 'no update source reachable' : problems.join('; ');
      return const UpdateDecision(action: UpdateAction.none, reason: 'update server unavailable');
    }

    lastManifest = merged;
    lastCheckAt = DateTime.now();
    if (problems.isNotEmpty) lastError = problems.join('; ');
    final UpdateDecision decision = merged.decide(
      platform: platform,
      currentVersion: currentVersion,
      channel: channel,
      includePrerelease: includePrerelease,
    );
    lastDecision = decision;
    return decision;
  }

  Future<ReleaseManifest?> _fetchManifest(
    Uri uri, {
    required Duration timeout,
    required String label,
    required List<String> problems,
    int maxBytes = 512 * 1024,
  }) async {
    late final HttpClient http;
    bool ownsClient = false;
    try {
      http = client ?? (HttpClient()..connectionTimeout = timeout);
      ownsClient = client == null;
      final HttpClientRequest request = await http.openUrl('GET', uri);
      request.headers.set(HttpHeaders.userAgentHeader, '$kNaxloAgent/$currentVersion ($platform)');
      if (uri.host == 'api.github.com') {
        request.headers.set('Accept', 'application/vnd.github+json');
      }
      final HttpClientResponse response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        // Drain, or the connection is left half-read for the next request.
        await response.drain<void>();
        final bool rateLimited = uri.host == 'api.github.com' &&
            (response.statusCode == 403 || response.statusCode == 429);
        problems.add(rateLimited
            ? '$label HTTP ${response.statusCode} (unauthenticated API calls are rate limited)'
            : '$label HTTP ${response.statusCode}');
        return null;
      }
      final String body = await _readBody(response, maxBytes, timeout);
      final bool isGithub = label == 'github' || uri.host == 'api.github.com';
      return isGithub ? GithubReleases.manifestFrom(body) : ReleaseManifest.parse(body);
    } on TimeoutException {
      problems.add('$label timed out after ${timeout.inMilliseconds / 1000}s');
      return null;
    } on SocketException catch (e) {
      problems.add('$label network: ${e.message}');
      return null;
    } on HandshakeException catch (e) {
      problems.add('$label tls: ${e.message}');
      return null;
    } on FormatException catch (e) {
      problems.add('$label unparseable: ${e.message}');
      return null;
    } on Object catch (e) {
      problems.add('$label failed: $e');
      return null;
    } finally {
      if (ownsClient) http.close(force: true);
    }
  }

  /// Read a whole response body under both a size and a time budget.
  ///
  /// `contentLength` is -1 for chunked responses, so it cannot be the only check;
  /// and a response that ends *early* without an error is how a truncating proxy
  /// looks, which is why the total is compared against the advertised length too.
  static Future<String> _readBody(HttpClientResponse response, int maxBytes, Duration timeout) async {
    final int declared = response.contentLength;
    if (declared > maxBytes) {
      await response.drain<void>();
      throw FormatException('body is $declared bytes, over the $maxBytes cap');
    }
    final List<int> bytes = <int>[];
    bool overflowed = false;
    await response.forEach((List<int> chunk) {
      if (overflowed) return;
      bytes.addAll(chunk);
      if (bytes.length > maxBytes) overflowed = true;
    }).timeout(timeout, onTimeout: () {
      overflowed = true;
    });
    if (overflowed) throw FormatException('body exceeded $maxBytes bytes');
    if (declared >= 0 && bytes.length != declared) {
      throw FormatException('body truncated (${bytes.length} of $declared bytes)');
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Fetch the advertised installer into a temp directory and verify it.
  ///
  /// The file is written as `<name>.part` and only renamed once the hash has
  /// been checked, so a half-download can never be mistaken for an installer —
  /// including by the user, who sees the directory in their file manager.
  Future<UpdateDownload> download(
    UpdateDecision decision, {
    String? directory,
    void Function(int received, int total)? onProgress,
    Duration idleTimeout = const Duration(seconds: 20),
  }) async {
    final String url = decision.downloadUrl;
    if (url.isEmpty) return UpdateDownload.failed('this release advertises no installer URL');
    final Uri? uri = Uri.tryParse(url);
    if (uri == null || !uri.isScheme('https')) {
      return UpdateDownload.failed('refusing to download from anything but https: $url');
    }
    final List<String> segments = uri.pathSegments.where((String segment) => segment.isNotEmpty).toList();
    final String rawName = decision.assetName.isNotEmpty
        ? decision.assetName
        : (segments.isEmpty ? 'installer.bin' : segments.last);
    final String name = safeFileName(rawName);
    if (name.isEmpty) return UpdateDownload.failed('the release asset has no usable file name');

    late final Directory target;
    if (directory == null) {
      target = await Directory.systemTemp.createTemp('naxlo-update');
    } else {
      target = Directory(directory);
      await target.create(recursive: true);
    }
    final File part = File('${target.path}${Platform.pathSeparator}$name.part');
    final File finalFile = File('${target.path}${Platform.pathSeparator}$name');

    // A download that outgrows its advertised size by more than a few megabytes
    // is not a slightly-wrong content-length, it is someone streaming garbage into
    // a temp directory — so the cap is generous, but it is never unlimited.
    final int budget = decision.size > 0 ? decision.size + 8 * 1024 * 1024 : 512 * 1024 * 1024;
    int received = 0;
    String? failure;
    bool headersReceived = false;
    Timer? idle;

    late final IOSink sink;
    try {
      sink = part.openWrite();
    } on FileSystemException catch (e) {
      return UpdateDownload.failed('cannot write ${part.path}: ${e.osError?.message ?? e.message}');
    }

    late final HttpClient http;
    bool ownsClient = false;
    StreamSubscription<List<int>>? subscription;
    final Completer<void> done = Completer<void>();
    // An *idle* budget, not a total one: 40 MB over a throttled link legitimately
    // takes minutes, and a deadline on the whole transfer would fail exactly the
    // connections that most need the update. What must never happen is waiting on
    // a server that sent one chunk and then stopped.
    void armIdle() {
      idle?.cancel();
      idle = Timer(idleTimeout, () {
        failure ??= 'the download stalled (no bytes for ${idleTimeout.inSeconds}s)';
        if (!done.isCompleted) done.complete();
        unawaited(subscription?.cancel() ?? Future<void>.value());
      });
    }

    try {
      http = client ?? (HttpClient()..connectionTimeout = idleTimeout);
      ownsClient = client == null;
      armIdle();
      final HttpClientRequest request = await http.openUrl('GET', uri);
      request.headers.set(HttpHeaders.userAgentHeader, '$kNaxloAgent/$currentVersion ($platform)');
      final HttpClientResponse response = await request.close();
      headersReceived = true;
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        failure = 'download HTTP ${response.statusCode}';
      } else {
        final int total = response.contentLength >= 0 ? response.contentLength : decision.size;
        subscription = response.listen(
          (List<int> chunk) {
            armIdle();
            if (done.isCompleted) return;
            received += chunk.length;
            if (received > budget) {
              failure = 'the download grew past its advertised size (${decision.size} bytes advertised)';
              if (!done.isCompleted) done.complete();
              return;
            }
            sink.add(chunk);
            onProgress?.call(received, total);
          },
          onError: (Object error, StackTrace _) {
            failure ??= 'download failed: $error';
            if (!done.isCompleted) done.complete();
          },
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: true,
        );
        await done.future;
      }
    } on TimeoutException {
      failure ??= headersReceived
          ? 'the download stalled (no bytes for ${idleTimeout.inSeconds}s)'
          : 'the server accepted no response in ${idleTimeout.inSeconds}s';
    } on SocketException catch (e) {
      failure ??= 'network: ${e.message}';
    } on HandshakeException catch (e) {
      failure ??= 'tls: ${e.message}';
    } on Object catch (e) {
      failure ??= '$e';
    } finally {
      idle?.cancel();
      if (subscription != null) {
        try {
          await subscription!.cancel();
        } on Object {
          // Already cancelled by the stream's own error handling.
        }
      }
      try {
        await sink.close();
      } on Object {
        // A sink whose stream was torn down errors on close; the file's state is
        // what matters and that is checked below.
      }
      if (ownsClient) http.close(force: true);
    }

    // A stalled or truncated transfer must not reach the hash check at all:
    // partial bytes are only ever a failure, never an "unverified" success.
    if (failure == null && received == 0) failure = 'downloaded nothing';
    final int advertised = decision.size;
    if (failure == null && advertised > 0 && received != advertised) {
      failure = 'got $received bytes, the release advertises $advertised';
    }
    if (failure != null) {
      await _delete(part);
      return UpdateDownload.failed(failure, path: part.path, bytes: received);
    }

    await _delete(finalFile);
    await part.rename(finalFile.path);
    final FileDigest digest = await UpdateService.digestFile(finalFile);
    final String expected = decision.sha256.toLowerCase();
    if (expected.isEmpty) {
      // Kept on purpose: the user may still want to install by hand, and the UI
      // says plainly that nothing vouches for these bytes.
      return UpdateDownload(
        path: finalFile.path,
        state: DownloadState.unverified,
        bytes: received,
        sha256: digest.sha256,
        message: 'downloaded, but the release published no sha256 — installed nothing',
      );
    }
    if (digest.sha256.isEmpty) {
      return UpdateDownload(
        path: finalFile.path,
        state: DownloadState.unverified,
        bytes: received,
        sha256: '',
        message: 'could not hash the file (${digest.error}), so nothing was run',
      );
    }
    if (digest.sha256 != expected) {
      await _delete(finalFile);
      return UpdateDownload.failed(
        'sha256 mismatch — this is either a corrupt download or someone is '
        'interfering with it. The file was deleted.',
        path: finalFile.path,
        bytes: received,
        actualSha256: digest.sha256,
      );
    }
    return UpdateDownload(
      path: finalFile.path,
      state: DownloadState.verified,
      bytes: received,
      sha256: digest.sha256,
      message: 'sha256 matches the value GitHub computed for this asset',
    );
  }

  /// Run the installer the OS knows how to run. Never a shell string: `argv` is
  /// passed to [Process.start] directly, so a file name containing a quote or a
  /// semicolon is a file name and not a second command.
  static Future<LaunchResult> launchInstaller(File file) async {
    if (!await file.exists()) return const LaunchResult(message: 'the downloaded file is gone');
    final String path = file.path;
    try {
      if (Platform.isWindows) {
        // Inno's own parameters: close the running app, replace the binaries,
        // bring it back, and do not reboot the machine for us.
        final List<String> args = <String>[
          '/SILENT',
          '/CLOSEAPPLICATIONS',
          '/RESTARTAPPLICATIONS',
          '/NORESTART',
        ];
        await Process.start(path, args, mode: ProcessStartMode.detached);
        return LaunchResult(
          started: true,
          message: 'installer started — Naxlo Two will now close',
          command: '"$path" ${args.join(' ')}',
        );
      }
      if (Platform.isMacOS) {
        await Process.start('open', <String>[path], mode: ProcessStartMode.detached);
        return LaunchResult(
          started: true,
          message: 'disk image opened — drag Naxlo Two onto Applications',
          command: 'open "$path"',
        );
      }
      if (Platform.isAndroid) {
        return LaunchResult(
          message: 'Android will not let an app install a package by itself: open the file in your Files '
              'app and allow installing from this source',
          command: path,
        );
      }
      final String command = _linuxInstallCommand(path);
      await Process.start('xdg-open', <String>[File(path).parent.path], mode: ProcessStartMode.detached);
      return LaunchResult(
        started: true,
        message: 'the folder was opened — run this in a terminal: $command',
        command: command,
      );
    } on ProcessException catch (e) {
      return LaunchResult(message: 'could not start the installer: ${e.message}');
    } on Object catch (e) {
      return LaunchResult(message: 'could not start the installer: $e');
    }
  }

  /// Absolute paths, because the terminal the user opens will not be sitting in
  /// the temp directory the download landed in.
  static String _linuxInstallCommand(String path) {
    if (path.endsWith('.deb')) return 'sudo apt install "$path"';
    if (path.endsWith('.rpm')) return 'sudo rpm -Uvh "$path"';
    if (path.endsWith('.pkg.tar.zst')) return 'sudo pacman -U "$path"';
    if (path.endsWith('.AppImage')) return 'chmod +x "$path" && "$path"';
    return 'install "$path" the usual way for this file type';
  }

  /// A [FileDigest] is `sha256 == ''` whenever the hash could not be produced —
  /// which is a *different* state from "hashes do not match", and callers must
  /// not treat one as the other: refusing to run an unhashable file is honest,
  /// claiming it is corrupt is not.
  static Future<FileDigest> digestFile(File file) async {
    if (!await file.exists()) return const FileDigest(error: 'file not found');
    // dart:convert has no hasher and we refuse to add a crypto dependency for one
    // call, so shell out to the platform tool that already exists.
    final String quoted = file.path.replaceAll("'", "''");
    final List<String> argv = Platform.isWindows
        ? <String>[
            'powershell',
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            "(Get-FileHash -Algorithm SHA256 -LiteralPath '$quoted').Hash",
          ]
        : <String>['sha256sum', '--', file.path];
    final ProcessResult result;
    try {
      result = await Process.run(argv.first, argv.sublist(1));
    } on ProcessException catch (e) {
      // The old code caught only FileSystemException here, so a machine without
      // the tool reported a crash to the caller instead of "unverified".
      return FileDigest(error: '${argv.first} unavailable: ${e.message}');
    } on Object catch (e) {
      return FileDigest(error: '$e');
    }
    if (result.exitCode != 0) {
      return FileDigest(error: '${result.stderr}'.trim().split('\n').first);
    }
    final String out = '${result.stdout}'.trim().toLowerCase();
    final String candidate = Platform.isWindows ? out : out.split(RegExp(r'\s+')).first;
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(candidate)) {
      return FileDigest(error: 'the hasher printed something unexpected');
    }
    return FileDigest(sha256: candidate);
  }

  /// Kept for callers that only want the boolean; an empty expected digest is a
  /// mismatch, not a pass.
  static Future<bool> verifySha256(File file, String expectedHex) async {
    if (expectedHex.isEmpty) return false;
    final FileDigest digest = await digestFile(file);
    return digest.sha256 == expectedHex.toLowerCase();
  }

  /// Strip anything a hostile asset name could use to escape the download
  /// directory: separators, drive letters, `..`, and control characters.
  /// Public and covered by a test, because the value it sanitises is a string
  /// that arrives over the network and lands in a filesystem path.
  static String safeFileName(String raw) {
    String name = raw.trim();
    final int slash = name.lastIndexOf(RegExp(r'[/\\]'));
    if (slash >= 0) name = name.substring(slash + 1);
    name = name.replaceAll('..', '.').replaceAll(RegExp(r'[^A-Za-z0-9._+-]'), '_');
    if (name.startsWith('.')) name = 'naxlo-$name';
    if (name.length > 120) name = name.substring(name.length - 120);
    return name == '.' || name == '..' ? '' : name;
  }

  static Future<void> _delete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on Object {
      // Nothing useful to do about a file we could not remove, and reporting it
      // over the real failure would be worse.
    }
  }

  static String platformName() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return 'linux';
  }

  static String describeBytes(int bytes) {
    if (bytes <= 0) return 'unknown size';
    const List<String> units = <String>['B', 'KB', 'MB', 'GB'];
    double value = bytes.toDouble();
    int unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
  }
}

enum DownloadState { verified, unverified, failed }

class UpdateDownload {
  const UpdateDownload({
    required this.path,
    required this.state,
    required this.bytes,
    required this.sha256,
    required this.message,
  });

  factory UpdateDownload.failed(
    String message, {
    String path = '',
    int bytes = 0,
    String actualSha256 = '',
  }) =>
      UpdateDownload(
        path: path,
        state: DownloadState.failed,
        bytes: bytes,
        sha256: actualSha256,
        message: message,
      );

  final String path;
  final DownloadState state;
  final int bytes;
  final String sha256;
  final String message;

  bool get isVerified => state == DownloadState.verified;
  bool get failed => state == DownloadState.failed;
  bool get installable => state == DownloadState.verified;
}

class FileDigest {
  const FileDigest({this.sha256 = '', this.error = ''});

  final String sha256;
  final String error;

  bool get ok => sha256.isNotEmpty;
}

class LaunchResult {
  const LaunchResult({this.started = false, required this.message, this.command = ''});

  final bool started;
  final String message;

  /// The exact thing being run (or, on Linux, what the user should run), shown in
  /// the UI so an updater never asks for trust it has not earned.
  final String command;
}
