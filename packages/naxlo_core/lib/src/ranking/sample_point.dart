import '../json/json_utils.dart';

/// Where an observation came from. Traffic-derived samples are trustworthy but
/// sparse; probe samples are regular but measure a handshake, not a download.
enum SampleSource {
  probe('probe', 1.0),
  handshake('handshake', 1.0),
  engineLog('engine', 0.8),
  traffic('traffic', 0.6),
  manual('manual', 1.0);

  const SampleSource(this.wireName, this.reliability);
  final String wireName;

  /// Multiplier on how much a sample moves the estimates.
  final double reliability;

  static SampleSource fromName(String? raw) {
    final s = asString(raw).trim();
    for (final e in SampleSource.values) {
      if (e.wireName == s) return e;
    }
    return SampleSource.probe;
  }
}

/// A single measurement of a server.
///
/// [latencyMs] is the time to establish a usable tunnel (TCP connect, or TLS
/// handshake when the node is encrypted). Negative means "no measurement",
/// which is distinct from a failure: a failure is evidence, an absent sample is
/// only missing information.
class SamplePoint {
  const SamplePoint({
    required this.atMs,
    required this.ok,
    required this.latencyMs,
    this.bytes = 0,
    this.error = '',
    this.source = SampleSource.probe,
  });

  factory SamplePoint.success({
    required int atMs,
    required int latencyMs,
    int bytes = 0,
    SampleSource source = SampleSource.probe,
  }) =>
      SamplePoint(atMs: atMs, ok: true, latencyMs: latencyMs, bytes: bytes, source: source);

  factory SamplePoint.failure({
    required int atMs,
    required String error,
    SampleSource source = SampleSource.probe,
  }) =>
      SamplePoint(atMs: atMs, ok: false, latencyMs: -1, error: error, source: source);

  final int atMs;
  final bool ok;
  final int latencyMs;

  /// Bytes moved during the measurement window, if known.
  final int bytes;
  final String error;
  final SampleSource source;

  Duration get latencyDuration => latencyMs < 0 ? Duration.zero : Duration(milliseconds: latencyMs);

  Map<String, Object?> toJson() => <String, Object?>{
        'at': atMs,
        'ok': ok,
        if (latencyMs >= 0) 'lat': latencyMs,
        if (bytes > 0) 'bytes': bytes,
        if (error.isNotEmpty) 'err': error,
        'src': source.wireName,
      };

  static SamplePoint fromJson(Map<String, Object?> json) => SamplePoint(
        atMs: asInt(json['at']),
        ok: asBool(json['ok'], fallback: true),
        latencyMs: asInt(json['lat'], fallback: -1),
        bytes: asInt(json['bytes']),
        error: asString(json['err']),
        source: SampleSource.fromName(asString(json['src'])),
      );

  @override
  String toString() => ok ? 'ok(${latencyMs}ms)' : 'fail($error)';
}
