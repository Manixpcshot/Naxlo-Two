import 'dart:async';

/// Bounded, broadcast log tail shared by the supervisor and the Logs screen.
///
/// The cap matters: Xray at `info` can emit thousands of lines a minute when a
/// server is misbehaving, and an unbounded list in a tray app slowly becomes a
/// gigabyte. 2000 lines is enough to read a failure and small enough to keep in
/// memory without thought.
class LogBuffer {
  LogBuffer({this.capacity = 2000});

  final int capacity;
  final List<LogLine> _lines = <LogLine>[];
  final StreamController<LogLine> _controller = StreamController<LogLine>.broadcast();

  Stream<LogLine> get stream => _controller.stream;
  List<LogLine> get lines => List<LogLine>.unmodifiable(_lines);
  bool get isEmpty => _lines.isEmpty;

  void add(String text, {String source = 'engine', LogLevel level = LogLevel.info}) {
    if (text.trim().isEmpty) return;
    final line = LogLine(
      at: DateTime.now(),
      text: text.trimRight(),
      source: source,
      level: level == LogLevel.info ? _inferLevel(text) : level,
    );
    _lines.add(line);
    if (_lines.length > capacity) {
      _lines.removeRange(0, _lines.length - capacity);
    }
    if (!_controller.isClosed) _controller.add(line);
  }

  /// Engines disagree about severity vocabulary; map both to ours so the UI can
  /// colour lines without knowing which core produced them.
  static LogLevel _inferLevel(String text) {
    final s = text.toLowerCase();
    if (s.contains('.level=error') || s.contains(' error') || s.contains('fatal') || s.contains('critical')) {
      return LogLevel.error;
    }
    if (s.contains('warn') || s.contains('.level=warn')) return LogLevel.warn;
    if (s.contains('debug') || s.contains('trace')) return LogLevel.debug;
    return LogLevel.info;
  }

  void clear() => _lines.clear();

  String dump() => _lines.map((l) => '${l.at.toIso8601String()} ${l.source}: ${l.text}').join('\n');

  Future<void> close() async {
    _lines.clear();
    await _controller.close();
  }
}

enum LogLevel { debug, info, warn, error }

class LogLine {
  const LogLine({required this.at, required this.text, required this.source, required this.level});

  final DateTime at;
  final String text;
  final String source;
  final LogLevel level;

  String get time => '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}:'
      '${at.second.toString().padLeft(2, '0')}';
}

/// Approximate byte counter fed by the engine's access log.
///
/// Neither engine exposes cheap aggregate counters to a client without the gRPC
/// stats API (Xray) or an outbound-tag listener (sing-box), and wiring a gRPC
/// stack into the app for one number is not worth the dependency. So: parse the
/// `… N bytes` trailer Xray writes on connection close. It under-counts open
/// flows and never lies about the direction, which is the right trade for a
/// "am I actually tunneling traffic?" indicator. The UI labels it as an estimate.
class TrafficTally {
  TrafficTally({this.windowSize = 60});

  static final RegExp _bytes = RegExp(r'(\d+)\s+bytes');
  static final RegExp _dir = RegExp(r'(>>>|<<<|inbound|outbound|accept|reject)');

  final int windowSize;
  final List<int> _samples = <int>[];
  int totalUp = 0;
  int totalDown = 0;
  int connections = 0;
  int rejections = 0;
  int _lastTickMs = 0;

  void noteAccessLine(String line) {
    final m = _bytes.firstMatch(line);
    if (m == null) return;
    final n = int.tryParse(m.group(1) ?? '') ?? 0;
    if (n <= 0) return;
    final lower = line.toLowerCase();
    if (lower.contains('>>>') || lower.contains('outbound')) {
      totalUp += n;
    } else if (lower.contains('<<<') || lower.contains('inbound')) {
      totalDown += n;
    } else {
      // No direction marker: count it as download, which is what users expect
      // from a "how much did I pull" number.
      totalDown += n;
    }
    if (_dir.hasMatch(line)) connections++;
    if (lower.contains('reject')) rejections++;
  }

  int get totalBytes => totalUp + totalDown;

  /// Bytes since the last call, as kbit/s, for the sparkline.
  double sample() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final dtMs = _lastTickMs == 0 ? 0 : now - _lastTickMs;
    _lastTickMs = now;
    final current = totalBytes;
    if (_samples.isEmpty || dtMs <= 0) {
      _samples.add(current);
      if (_samples.length > windowSize) _samples.removeAt(0);
      return 0;
    }
    final delta = current - _samples.last;
    _samples.add(current);
    if (_samples.length > windowSize) _samples.removeAt(0);
    if (delta <= 0) return 0;
    return (delta * 8.0) / (dtMs / 1000.0) / 1000.0;
  }

  void reset() {
    totalUp = 0;
    totalDown = 0;
    connections = 0;
    rejections = 0;
    _samples.clear();
    _lastTickMs = 0;
  }
}
