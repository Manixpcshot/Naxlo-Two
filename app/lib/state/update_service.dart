import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:naxlo_core/naxlo_core.dart';

/// In-app update check against the `release` manifest at the repo root.
///
/// Security posture, because an updater is the one code path where "trust the
/// server" is genuinely dangerous:
///   * the manifest is fetched over HTTPS and, for the GitHub-hosted default,
///     pinned to raw.githubusercontent.com;
///   * a download is only started when the manifest carries a `sha256`, which
///     is verified before anything is executed;
///   * an unsigned/unknown-hash artifact is reported, never installed.
/// A supply-chain win via a stolen token is still possible upstream, which is
/// why the UI shows the hash and the exact URL instead of a bare "updated ✓".
class UpdateService {
  UpdateService({
    required this.platform,
    this.currentVersion = kNaxloVersion,
    this.client,
  });

  final String platform;
  final String currentVersion;
  final HttpClient? client;

  ReleaseManifest? lastManifest;
  UpdateDecision? lastDecision;
  DateTime? lastCheckAt;
  String? lastError;

  Uri get manifestUri => Uri.parse(kDefaultManifestUrl);

  Future<UpdateDecision> check({
    String channel = 'stable',
    bool includePrerelease = false,
    Duration timeout = const Duration(seconds: 8),
    String? overrideUrl,
  }) async {
    lastError = null;
    late final HttpClient httpClient;
    var ownsClient = false;
    try {
      httpClient = client ?? (HttpClient()..connectionTimeout = timeout);
      ownsClient = client == null;
      final request = await httpClient.openUrl('GET', overrideUrl == null ? manifestUri : Uri.parse(overrideUrl));
      request.headers.set(HttpHeaders.userAgentHeader, '$kNaxloAgent/$currentVersion ($platform)');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        lastError = 'manifest HTTP ${response.statusCode}';
        return const UpdateDecision(action: UpdateAction.none, reason: 'update server unavailable');
      }
      final body = await response.transform(utf8.decoder).join();
      final manifest = ReleaseManifest.parse(body);
      lastManifest = manifest;
      lastCheckAt = DateTime.now();
      final decision = manifest.decide(
        platform: platform,
        currentVersion: currentVersion,
        channel: channel,
        includePrerelease: includePrerelease,
      );
      lastDecision = decision;
      return decision;
    } on SocketException catch (e) {
      lastError = 'network: ${e.message}';
      return const UpdateDecision(action: UpdateAction.none, reason: 'no network');
    } on TimeoutException {
      lastError = 'timed out after ${timeout.inSeconds}s';
      return const UpdateDecision(action: UpdateAction.none, reason: 'update check timed out');
    } on FormatException catch (e) {
      lastError = 'unparseable manifest: ${e.message}';
      return const UpdateDecision(action: UpdateAction.none, reason: 'manifest is malformed');
    } on Object catch (e) {
      lastError = '$e';
      return const UpdateDecision(action: UpdateAction.none, reason: 'update check failed');
    } finally {
      if (ownsClient) httpClient.close(force: true);
    }
  }

  /// Only used by the "Download" affordance; the app never self-updates a
  /// binary it cannot hash-verify.
  static Future<bool> verifySha256(File file, String expectedHex) async {
    if (expectedHex.isEmpty) return false;
    try {
      final digest = await sha256OfFile(file);
      return digest == expectedHex.toLowerCase();
    } on FileSystemException {
      return false;
    }
  }

  static Future<String> sha256OfFile(File file) async {
    // dart:convert has no hasher and we refuse to add a crypto dependency for
    // one call, so shell out to the platform tool that already exists.
    final tool = Platform.isWindows
        ? <String>['powershell', '-NoProfile', '-Command', '(Get-FileHash -Algorithm SHA256 -LiteralPath "${file.path}").Hash']
        : <String>['sha256sum', file.path];
    final r = await Process.run(tool.first, tool.sublist(1));
    if (r.exitCode != 0) throw FileSystemException('hasher unavailable', file.path);
    final out = ('${r.stdout}').trim().toLowerCase();
    return Platform.isWindows ? out : out.split(RegExp(r'\s+')).first;
  }

  static String platformName() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return 'linux';
  }
}
