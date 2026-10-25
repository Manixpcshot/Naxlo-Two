import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:naxlo_core/naxlo_core.dart';

import 'engine_locator.dart';
import 'log_buffer.dart';

enum EngineStatus { stopped, starting, running, failed }

/// Result of a start attempt, with the reason attached so the UI can show
/// something better than "failed".
class EngineStartResult {
  const EngineStartResult({required this.ok, this.message = '', this.warnings = const <String>[], this.exitCode});

  static EngineStartResult ok(List<String> warnings) =>
      EngineStartResult(ok: true, warnings: warnings);

  factory EngineStartResult.fail(String message, {int? exitCode, List<String> warnings = const <String>[]}) =>
      EngineStartResult(ok: false, message: message, exitCode: exitCode, warnings: warnings);

  final bool ok;
  final String message;
  final List<String> warnings;
  final int? exitCode;
}

/// Starts, watches and stops the engine process.
///
/// Contract with the caller: [start] never leaves a half-alive process behind.
/// On any failure path it kills what it spawned and restores [EngineStatus.stopped],
/// because a stray Xray holding port 20151 (and the system proxy pointing at it)
/// while the UI says "disconnected" is a leak, not a bug.
class EngineService {
  EngineService({
    required this.logs,
    required this.locator,
    required this.supportDir,
    this.traffic = TrafficTally(),
  });

  final LogBuffer logs;
  final EngineLocator locator;
  final Directory supportDir;
  final TrafficTally traffic;

  Process? _process;
  StreamSubscription<String>? _stdout;
  StreamSubscription<String>? _stderr;
  Timer? _restartTimer;
  int _restartsInWindow = 0;
  int _windowStartMs = 0;

  EngineStatus status = EngineStatus.stopped;

  /// Set when the engine dies on its own, so the UI can distinguish "user
  /// stopped it" from "the server ate the connection".
  String? lastFailure;
  String? activeConfigPath;
  ServerNode? activeNode;
  int? get pid => _process?.pid;
  bool get isRunning => _process != null;

  File _configFile(String profileId) =>
      File('$supportDir${Platform.pathSeparator}config-$profileId.json');

  /// Writes the config, verifies it with the engine's own `test`/`check`
  /// subcommand, then starts it. Verification costs ~50ms and saves the
  /// "engine exited instantly with no explanation" class of support ticket.
  Future<EngineStartResult> start({
    required Profile profile,
    required ServerNode node,
    required RuntimeSettings settings,
  }) async {
    await stop(silent: true);
    status = EngineStatus.starting;
    lastFailure = null;

    final generated = _generate(profile, node, settings);
    if (generated.warnings.isNotEmpty) {
      for (final w in generated.warnings) {
        logs.add(w, source: 'config', level: LogLevel.warn);
      }
    }

    final binary = await locator.find(
      profile.engine.cliName,
      override: profile.engine == EngineKind.xray ? settings.xrayBinaryPath : settings.singBoxBinaryPath,
    );
    if (binary == null) {
      status = EngineStatus.failed;
      final msg = 'no ${profile.engine.cliName} binary found (searched app dir, exe dir and PATH)';
      lastFailure = msg;
      logs.add(msg, source: 'engine', level: LogLevel.error);
      return EngineStartResult.fail(msg, warnings: generated.warnings);
    }

    final file = _configFile(profile.id);
    try {
      await file.writeAsString(generated.compactJson, flush: true);
    } on FileSystemException catch (e) {
      status = EngineStatus.failed;
      lastFailure = e.message;
      return EngineStartResult.fail('cannot write config: ${e.message}', warnings: generated.warnings);
    }
    activeConfigPath = file.path;
    activeNode = node;

    final verify = await _verify(binary: binary, configPath: file.path, engine: profile.engine);
    if (!verify.ok) {
      status = EngineStatus.failed;
      lastFailure = verify.message;
      logs.add('config rejected: ${verify.message}', source: 'engine', level: LogLevel.error);
      return EngineStartResult.fail(verify.message, exitCode: verify.exitCode, warnings: generated.warnings);
    }

    try {
      _process = await Process.start(
        binary,
        profile.engine.runArgs(file.path),
        workingDirectory: File(binary).parent.path,
        mode: ProcessStartMode.normal,
      );
    } on ProcessException catch (e) {
      status = EngineStatus.failed;
      lastFailure = e.message;
      logs.add('spawn failed: ${e.message}', source: 'engine', level: LogLevel.error);
      return EngineStartResult.fail(e.message, warnings: generated.warnings);
    }

    _stdout = _process!.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(_onLine);
    _stderr = _process!.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(_onLine);

    final exited = _process!.exit;
    unawaited(
      exited.then((code) async {
        await _detachStreams();
        final wasRunning = status == EngineStatus.running;
        _process = null;
        if (code == 0 || !wasRunning) {
          status = EngineStatus.stopped;
          return;
        }
        status = EngineStatus.failed;
        lastFailure = 'engine exited with code $code';
        logs.add(lastFailure!, source: 'engine', level: LogLevel.error);
        if (settings.killSwitch) {
          // Do not let traffic silently revert to plain while the user believes
          // they are tunnelled: report it, and let AppState drop the system proxy.
          logs.add('kill switch engaged: the system proxy is being cleared',
              source: 'engine', level: LogLevel.warn);
        }
        if (settings.autoRestartEngine && _shouldRetry()) {
          _restartTimer?.cancel();
          final delay = Duration(seconds: [2, 4, 8, 15, 30][_restartsInWindow.clamp(0, 4)]);
          logs.add('restarting in ${delay.inSeconds}s '
              '(attempt ${_restartsInWindow + 1}/${settings.maxRestarts})', source: 'engine');
          _restartTimer = Timer(delay, () {
            unawaited(start(profile: profile, node: node, settings: settings));
          });
        } else if (settings.autoRestartEngine) {
          logs.add('giving up after ${settings.maxRestarts} restarts; the node or config is at fault',
              source: 'engine', level: LogLevel.error);
        }
      }),
    );

    // Xray prints "Xray ..." then binds; a short settle window avoids the race
    // where the first probe hits a port that is 100ms from being open.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (_process == null) {
      final msg = lastFailure ?? 'engine exited during startup';
      return EngineStartResult.fail(msg, warnings: generated.warnings);
    }
    status = EngineStatus.running;
    traffic.reset();
    logs.add('engine running (pid ${_process!.pid}) on ${profile.engine.cliName}', source: 'engine');
    return EngineStartResult.ok(generated.warnings);
  }

  /// Exponential backoff with a hard cap, and a *reason* kept in the log: an
  /// unbounded restart loop on a revoked subscription is a battery fire.
  bool _shouldRetry() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _windowStartMs > 60000) {
      _windowStartMs = now;
      _restartsInWindow = 0;
    }
    _restartsInWindow++;
    return _restartsInWindow <= 5;
  }

  GeneratedConfig _generate(Profile profile, ServerNode node, RuntimeSettings settings) {
    final withLogs = settings.logDir.isEmpty
        ? settings
        : settings.copyWith(
            accessLogPath: '${settings.logDir}${Platform.pathSeparator}access.log',
            errorLogPath: '${settings.logDir}${Platform.pathSeparator}engine.log',
          );
    switch (profile.engine) {
      case EngineKind.xray:
        return XrayConfigBuilder(profile, node, withLogs).build();
      case EngineKind.singBox:
        return SingBoxConfigBuilder(profile, node, withLogs).build();
    }
  }

  Future<EngineStartResult> _verify({
    required String binary,
    required String configPath,
    required EngineKind engine,
  }) async {
    try {
      final r = await Process.run(
        binary,
        engine.verifyArgs(configPath),
        workingDirectory: File(binary).parent.path,
      );
      if (r.exitCode == 0) return EngineStartResult.ok(const <String>[]);
      final text = ('${r.stdout}\n${r.stderr}').trim();
      final relevant = text
          .split(RegExp(r'\r?\n'))
          .where((l) => l.toLowerCase().contains('error') || l.toLowerCase().contains('failed'))
          .toList();
      return EngineStartResult.fail(
        relevant.isEmpty ? text : relevant.join(' · '),
        exitCode: r.exitCode,
      );
    } on ProcessException catch (e) {
      return EngineStartResult.fail('cannot verify config: ${e.message}');
    }
  }

  void _onLine(String line) {
    logs.add(line, source: 'engine');
    if (status == EngineStatus.running && line.contains('bytes')) {
      traffic.noteAccessLine(line);
    }
  }

  Future<void> _detachStreams() async {
    await _stdout?.cancel();
    await _stderr?.cancel();
    _stdout = null;
    _stderr = null;
  }

  Future<void> stop({bool silent = false}) async {
    _restartTimer?.cancel();
    _restartTimer = null;
    final p = _process;
    _process = null;
    status = EngineStatus.stopped;
    activeNode = null;
    await _detachStreams();
    if (p == null) return;
    // SIGTERM first: Xray flushes its access log and closes listeners on
    // signal. `kill()` (SIGKILL) is only for a process that ignores us.
    p.kill(ProcessSignal.sigterm);
    final deadline = DateTime.now().add(const Duration(seconds: 4));
    while (DateTime.now().isBefore(deadline)) {
      try {
        await p.exit.timeout(const Duration(milliseconds: 200));
        break;
      } on TimeoutException {
        continue;
      }
    }
    try {
      p.kill(ProcessSignal.sigkill);
    } on Object {
      // already gone
    }
    if (!silent) logs.add('engine stopped', source: 'engine');
  }

  Future<void> dispose() async {
    await stop(silent: true);
    await logs.close();
  }
}
