import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:naxlo_core/naxlo_core.dart';
import 'package:naxlo_two/state/update_service.dart';

/// The decision layer (GitHub's response shape, the merge with the repo
/// manifest, the version ordering) is tested in naxlo_core, where it needs no
/// sockets at all. What belongs here is the part that only exists in the app:
/// fetching from a server that is live but untrustworthy, and the file-name
/// guard on the way to the filesystem.
void main() {
  group('file names from the network', () {
    test('cannot escape the download directory', () {
      for (final raw in <String>[
        '../../../../etc/passwd',
        r'..\..\..\windows\system32\x.exe',
        '/setup.exe',
        r'C:\Windows\Temp\setup.exe',
      ]) {
        final name = UpdateService.safeFileName(raw);
        expect(name, isNot(contains('/')), reason: raw);
        expect(name, isNot(contains(r'\')), reason: raw);
        expect(name, isNot(startsWith('..')), reason: raw);
        expect(name, isNotEmpty, reason: '$raw must still produce something usable');
      }
    });

    test('quotes, semicolons and shell metacharacters become underscores', () {
      // Not a matter of tidiness: this name reaches a PowerShell `-LiteralPath`
      // argument on Windows, where an unescaped quote changes the command.
      final name = UpdateService.safeFileName("x'; rm -rf /.exe");
      expect(name, isNot(contains("'")), reason: name);
      expect(name, isNot(contains(';')), reason: name);
      expect(name.toLowerCase(), endsWith('.exe'));
    });

    test('a real asset name survives untouched, and absurd input is bounded', () {
      expect(UpdateService.safeFileName('setup-Naxlo.x64.exe'), 'setup-Naxlo.x64.exe');
      expect(UpdateService.safeFileName('  '), isEmpty);
      expect(UpdateService.safeFileName('a' * 400).length, lessThanOrEqualTo(120));
    });
  });

  group('byte labels', () {
    test('say unknown rather than zero', () {
      expect(UpdateService.describeBytes(0), 'unknown size');
      expect(UpdateService.describeBytes(709), '709 B');
      expect(UpdateService.describeBytes(39952829), '38.1 MB');
      expect(UpdateService.describeBytes(3 * 1024 * 1024 * 1024), '3.0 GB');
    });
  });

  group('against a server we do not trust', () {
    late HttpServer server;
    late Future<void> serving;
    late Future<void> Function(HttpRequest) handler;
    final Completer<void> hold = Completer<void>();

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      handler = (HttpRequest request) async {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      };
      serving = server.forEach((HttpRequest request) async {
        await handler(request);
      });
    });
    tearDown(() async {
      if (!hold.isCompleted) hold.complete();
      await server.close(force: true);
      await serving.timeout(const Duration(seconds: 2), onTimeout: () {});
    });

    String url() => 'http://127.0.0.1:${server.port}/release';

    test('a reachable manifest decides, and says where it learned', () async {
      final svc = UpdateService(platform: 'linux', currentVersion: '0.3.0');
      handler = (HttpRequest request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(json.encode(<String, Object?>{
            'app': 'naxlo_two',
            'linux': <String, Object?>{
              'stable': <String, Object?>{
                'version': '0.4.0',
                'link': 'https://github.com/Manixpcshot/Naxlo-Two/releases/download/v0.4.0/Naxlo.linux.x64.deb',
                'sha256': 'ab' * 32,
                'size': 40108896,
              },
            },
          }));
        await request.response.close();
      };
      final decision = await svc.check(overrideUrl: url());
      expect(decision.action, UpdateAction.update);
      expect(decision.available, '0.4.0');
      expect(decision.sha256, 'ab' * 32, reason: 'integrity data reaches the UI');
      expect(decision.assetName, 'Naxlo.linux.x64.deb');
      // The label matters as much as the verdict: "up to date" from a dead
      // endpoint has to be distinguishable from "up to date" from GitHub.
      expect(svc.lastSource, 'release manifest');
      expect(svc.lastCheckAt, isNotNull);
    });

    test('a server that accepts and never answers cannot hang the check', () async {
      final svc = UpdateService(platform: 'linux', currentVersion: '0.3.0');
      handler = (HttpRequest request) => hold.future;
      final sw = Stopwatch()..start();
      final decision = await svc.check(overrideUrl: url(), timeout: const Duration(milliseconds: 400));
      sw.stop();
      expect(sw.elapsed.inSeconds, lessThan(5), reason: 'one timeout has to bound the whole read');
      expect(decision.action, UpdateAction.none);
      expect(svc.lastError, contains('timed out'));
    });

    test('an enormous body is refused instead of parsed', () async {
      final svc = UpdateService(platform: 'linux', currentVersion: '0.3.0');
      final String oversized = '{"a":${'x' * 700 * 1024}}';
      handler = (HttpRequest request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..write(oversized);
        await request.response.close();
      };
      final decision = await svc.check(overrideUrl: url(), timeout: const Duration(seconds: 8));
      expect(decision.action, UpdateAction.none);
      expect(svc.lastError, contains('exceeded'));
    });

    test('a 404 is reported as unreachable, never as up to date', () async {
      final svc = UpdateService(platform: 'linux', currentVersion: '0.3.0');
      final decision = await svc.check(overrideUrl: url());
      expect(decision.action, UpdateAction.none);
      expect(decision.reason, isNot(contains('up to date')));
      expect(svc.lastError, contains('HTTP 404'));
      expect(svc.lastSource, 'nothing reachable');
    });

    test('a non-https installer URL is never fetched', () async {
      final svc = UpdateService(platform: 'linux', currentVersion: '0.3.0');
      final result = await svc.download(UpdateDecision(
        action: UpdateAction.update,
        reason: 'x',
        available: '0.4.0',
        downloadUrl: 'http://127.0.0.1:${server.port}/setup.exe',
      ));
      expect(result.failed, isTrue);
      expect(result.message, contains('https'));
    });
  });
}
