import 'dart:io';

/// Finds `xray` / `sing-box` on this machine.
///
/// Search order is a security decision as much as a convenience one: a path the
/// user set in Settings wins, then the copy the app installed under its own
/// support dir, then a directory next to the executable (the packaged layout),
/// and only then `PATH`. Searching PATH first would let any `xray` earlier in the
/// lookup order — including one dropped by another program — impersonate the
/// engine that receives all of the user's traffic.
class EngineLocator {
  const EngineLocator({required this.supportDir});

  final Directory supportDir;

  static const Map<String, String> _binaryNames = <String, String>{
    'xray': 'xray',
    'sing-box': 'sing-box',
  };

  bool get _isWindows => Platform.isWindows;

  String fileName(String engine) {
    final base = _binaryNames[engine] ?? engine;
    return _isWindows ? '$base.exe' : base;
  }

  /// Candidate locations, most trusted first.
  List<String> searchPaths(String engine, {String override = ''}) {
    final name = fileName(engine);
    final out = <String>[];
    if (override.isNotEmpty) {
      out.add(override);
      if (!override.endsWith(name)) out.add('$override${Platform.pathSeparator}$name');
    }
    out.add('${supportDir.path}${Platform.pathSeparator}engines${Platform.pathSeparator}$engine${Platform.pathSeparator}$name');
    final exe = File.fromUri(Platform.resolvedExecutable).parent.path;
    out.add('$exe${Platform.pathSeparator}$name');
    out.add('$exe${Platform.pathSeparator}data${Platform.pathSeparator}engines${Platform.pathSeparator}$engine${Platform.pathSeparator}$name');
    if (_isWindows) {
      final local = Platform.environment['LOCALAPPDATA'];
      if (local != null) {
        out.add('$local${Platform.pathSeparator}NaxloTwo${Platform.pathSeparator}engines${Platform.pathSeparator}$engine${Platform.pathSeparator}$name');
      }
    } else {
      out.add('/usr/local/bin/$name');
      out.add('/usr/bin/$name');
      final home = Platform.environment['HOME'];
      if (home != null) {
        out.add('$home/.local/bin/$name');
        out.add('$home/bin/$name');
      }
    }
    return out;
  }

  /// First existing, executable match; null means "the user has to install it".
  Future<String?> find(String engine, {String override = ''}) async {
    for (final path in searchPaths(engine, override: override)) {
      try {
        final f = File(path);
        if (!await f.exists()) continue;
        if (!_isWindows) {
          final stat = await f.stat();
          // 0x49 == owner rwx; a non-executable copy is a download artifact,
          // and `Process.start` on it is a confusing "Permission denied".
          if (!stat.modeString().contains('x')) continue;
        }
        return path;
      } on FileSystemException {
        continue;
      }
    }
    // Last resort: ask the shell, which knows about Windows App Execution
    // Aliases and user-shimmed installs that a manual scan misses.
    final found = await _which(fileName(engine));
    return found;
  }

  Future<String?> _which(String name) async {
    try {
      final result = await Process.run(_isWindows ? 'where' : 'which', <String>[name]);
      if (result.exitCode != 0) return null;
      final out = (result.stdout as String).trim().split(RegExp(r'\r?\n'));
      return out.isEmpty ? null : out.first;
    } on ProcessException {
      return null;
    }
  }

  /// `xray version` / `sing-box version` for the About page. Best-effort: an
  /// engine that answers with anything else is reported verbatim, one that
  /// cannot be run at all returns null.
  Future<String?> versionOf(String binaryPath) async {
    if (binaryPath.isEmpty) return null;
    try {
      final r = await Process.run(binaryPath, <String>['version'],
          workingDirectory: File(binaryPath).parent.path);
      final text = ('${r.stdout}${r.stderr}').trim();
      if (text.isEmpty) return null;
      return text.split(RegExp(r'\r?\n')).first;
    } on ProcessException {
      return null;
    }
  }

  /// Marks a freshly extracted binary executable. POSIX-only no-op on Windows.
  static Future<void> makeExecutable(String path) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', <String>['+x', path]);
    } on ProcessException {
      // Some filesystems (FAT USB sticks, mounted noexec) reject chmod. The
      // caller still gets a path and the process spawn will report the real
      // reason, which is more useful than swallowing an error here.
    }
  }
}
