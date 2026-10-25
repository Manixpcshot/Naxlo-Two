import '../json/json_utils.dart';

/// TLS layer in front of the transport. `reality` is VLESS/Trojan's anti-MITM
/// handshake (XTLS Reality) and deliberately has no `allowInsecure` escape.
enum SecurityLayer {
  none('none'),
  tls('tls'),
  reality('reality');

  const SecurityLayer(this.wireName);
  final String wireName;

  static SecurityLayer fromName(String? raw) {
    final s = asString(raw).trim().toLowerCase();
    for (final e in SecurityLayer.values) {
      if (e.wireName == s) return e;
    }
    return SecurityLayer.none;
  }

  bool get encrypted => this != SecurityLayer.none;
}

/// uTLS fingerprints used to imitate a real browser ClientHello. `boring` (a.k.a.
/// "" for Xray) means "use the engine's own stack".
const List<String> kTlsFingerprints = <String>[
  'chrome',
  'firefox',
  'safari',
  'edge',
  '360',
  'qq',
  'random',
  'randomized',
  'ios',
  'android',
  'boring',
];

/// A TLS/Reality block shared by both config generators' vocabulary.
class TlsOptions {
  const TlsOptions({
    this.security = SecurityLayer.none,
    this.serverName = '',
    this.alpn = const <String>[],
    this.fingerprint = '',
    this.allowInsecure = false,
    this.publicKey = '',
    this.shortId = '',
    this.spiderX = '',
    this.grpcServiceName = '',
    this.echQuery = '',
  });

  final SecurityLayer security;

  /// SNI / `peerCertIssuerFallback`. Also Reality's `handshake server name`.
  final String serverName;
  final List<String> alpn;

  /// uTLS fingerprint; empty means "no uTLS".
  final String fingerprint;
  final bool allowInsecure;

  /// Reality: `pbk`.
  final String publicKey;

  /// Reality: `sid`.
  final String shortId;

  /// Reality: `spx`.
  final String spiderX;

  /// gRPC `serviceName` lives here because both engines put it near TLS-ish
  /// stream settings in share links (`?serviceName=`).
  final String grpcServiceName;

  /// TLS ECH config query (`ech`).
  final String echQuery;

  TlsOptions copyWith({
    SecurityLayer? security,
    String? serverName,
    List<String>? alpn,
    String? fingerprint,
    bool? allowInsecure,
    String? publicKey,
    String? shortId,
    String? spiderX,
    String? grpcServiceName,
    String? echQuery,
  }) {
    return TlsOptions(
      security: security ?? this.security,
      serverName: serverName ?? this.serverName,
      alpn: alpn ?? this.alpn,
      fingerprint: fingerprint ?? this.fingerprint,
      allowInsecure: allowInsecure ?? this.allowInsecure,
      publicKey: publicKey ?? this.publicKey,
      shortId: shortId ?? this.shortId,
      spiderX: spiderX ?? this.spiderX,
      grpcServiceName: grpcServiceName ?? this.grpcServiceName,
      echQuery: echQuery ?? this.echQuery,
    );
  }

  bool get isReality => security == SecurityLayer.reality && publicKey.isNotEmpty;

  Map<String, Object?> toJson() => pruneNulls(<String, Object?>{
        'security': security.wireName,
        'serverName': serverName,
        'alpn': alpn.isEmpty ? null : List<String>.from(alpn),
        'fingerprint': fingerprint,
        'allowInsecure': allowInsecure ? true : null,
        'publicKey': publicKey,
        'shortId': shortId,
        'spiderX': spiderX,
        'grpcServiceName': grpcServiceName,
        'ech': echQuery,
      });

  static TlsOptions fromJson(Map<String, Object?> json) {
    return TlsOptions(
      security: SecurityLayer.fromName(asString(json['security'])),
      serverName: asString(json['serverName']),
      alpn: asStringList(json['alpn']),
      fingerprint: asString(json['fingerprint']),
      allowInsecure: asBool(json['allowInsecure']),
      publicKey: asString(json['publicKey']),
      shortId: asString(json['shortId']),
      spiderX: asString(json['spiderX']),
      grpcServiceName: asString(json['grpcServiceName']),
      echQuery: asString(json['ech']),
    );
  }
}
