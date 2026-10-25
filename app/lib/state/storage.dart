import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Persistence boundary. The app never touches `dart:io` from a widget; it asks
/// a [BundleStore]. Tests use [MemoryBundleStore], desktop uses [FileBundleStore].
abstract class BundleStore {
  const BundleStore();

  Future<String?> read();

  Future<void> write(String contents);

  /// Directory the engine config, access log and downloaded binaries live in.
  Future<Directory> supportDir();

  Future<void> delete() async {}
}

class MemoryBundleStore extends BundleStore {
  MemoryBundleStore([this.initial = '']);

  String initial;
  String? contents;
  int writes = 0;

  @override
  Future<String?> read() async => contents ?? (initial.isEmpty ? null : initial);

  @override
  Future<void> write(String value) async {
    contents = value;
    writes++;
  }

  @override
  Future<Directory> supportDir() async => Directory.systemTemp.createTempSync('naxlo-two-test');

  @override
  Future<void> delete() async {
    contents = null;
  }
}

/// JSON file in the platform app-support dir, written atomically.
///
/// Atomicity is the point: a crash during `writeAsString` used to be enough to
/// lose every profile on some Windows setups. `tmp` + rename is the cheap fix,
/// plus one timestamped backup so a bad migration is recoverable by hand.
class FileBundleStore extends BundleStore {
  const FileBundleStore();

  static const String fileName = 'naxlo-two.state.json';
  static const int kKeepBackups = 3;

  @override
  Future<Directory> supportDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}NaxloTwo');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _stateFile() async {
    final dir = await supportDir();
    return File('${dir.path}${Platform.pathSeparator}$fileName');
  }

  @override
  Future<String?> read() async {
    final file = await _stateFile();
    if (!await file.exists()) return null;
    try {
      return await file.readAsString();
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<void> write(String contents) async {
    final file = await _stateFile();
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(contents, flush: true);
    if (await file.exists()) {
      await _backup(file);
    }
    await tmp.rename(file.path);
  }

  Future<void> _backup(File file) async {
    try {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      await file.copy('${file.path}.bak-$stamp');
      final dir = file.parent;
      final backups = <File>[];
      await for (final e in dir.list()) {
        if (e is File && e.path.contains('.state.json.bak-')) backups.add(e);
      }
      backups.sort((a, b) => a.path.compareTo(b.path));
      while (backups.length > kKeepBackups) {
        final oldest = backups.removeAt(0);
        try {
          await oldest.delete();
        } on FileSystemException {
          // Another handle (a second app instance) still holds it; next run will.
        }
      }
    } on FileSystemException {
      // Backups are best-effort; never fail a save over them.
    }
  }

  @override
  Future<void> delete() async {
    final file = await _stateFile();
    if (await file.exists()) await file.delete();
  }

  /// Preserves evidence when the state file cannot be parsed, so a user is not
  /// asked to "just try again" after losing a subscription.
  Future<String?> quarantineCorrupt(String raw) async {
    try {
      final file = await _stateFile();
      final path = '${file.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}';
      await file.writeAsString(raw);
      await File(file.path).rename(path);
      return path;
    } on FileSystemException {
      return null;
    }
  }
}

/// Debounced autosave: the ranker can produce a sample every second, and a
/// synchronous file write per sample on a laptop HDD is how apps get force-quit.
class AutoSaver {
  AutoSaver({required this.store, this.delay = const Duration(milliseconds: 900)});

  final BundleStore store;
  final Duration delay;

  Timer? _timer;
  String? _pending;
  bool _saving = false;
  Completer<void>? _drain;

  /// Drop the armed write without performing it. Called on dispose: an app that
  /// is going away must not write afterwards, and a live [Timer] at the end of a
  /// widget test fails the test.
  void cancelPending() {
    _timer?.cancel();
    _timer = null;
  }

  void schedule(String contents) {
    _pending = contents;
    _timer?.cancel();
    _timer = Timer(delay, flush);
  }

  Future<void> flush() async {
    if (_saving) {
      // A save is mid-flight; chain after it instead of racing the rename.
      await _drain?.future;
    }
    final value = _pending;
    if (value == null) return;
    _pending = null;
    _saving = true;
    _drain = Completer<void>();
    try {
      await store.write(value);
    } on FileSystemException {
      // Keep _pending so the next change retries; the UI must not lose state
      // because the disk hiccuped.
      _pending = value;
    } finally {
      _saving = false;
      _drain?.complete();
      _drain = null;
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
