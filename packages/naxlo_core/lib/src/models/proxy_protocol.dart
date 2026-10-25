import '../json/json_utils.dart';

/// Wire protocols Naxlo Two can terminate as a client. The set mirrors what the
/// engines support out of the box; `shareLinkScheme` is what a pasted URL uses.
enum ProxyProtocol {
  vless('vless', 'VLESS', '3.5.0'),
  vmess('vmess', 'VMess', '1.0.0'),
  trojan('trojan', 'Trojan', ''),
  shadowsocks('shadowsocks', 'Shadowsocks', '2022'),
  socks('socks', 'SOCKS', ''),
  http('http', 'HTTP', '');

  const ProxyProtocol(this.wireName, this.label, this.defaultVersion);

  /// Value written into `outbounds[].protocol` / `outbounds[].type`.
  final String wireName;
  final String label;

  /// VMess/vless `alterId` default and SS cipher family hint.
  final String defaultVersion;

  static ProxyProtocol? tryFrom(String? raw) {
    if (raw == null) return null;
    final s = raw.trim().toLowerCase();
    for (final e in ProxyProtocol.values) {
      if (e.wireName == s || e.name == s) return e;
    }
    if (s == 'ss') return ProxyProtocol.shadowsocks;
    if (s == 'socks5' || s == 'socks4' || s == 'socks4a') return ProxyProtocol.socks;
    return null;
  }

  /// Protocols where user id is a UUID rather than a password.
  bool get usesUuid => this == ProxyProtocol.vless || this == ProxyProtocol.vmess;

  /// Protocols where a password/PSK is the secret.
  bool get usesPassword =>
      this == ProxyProtocol.trojan ||
      this == ProxyProtocol.shadowsocks ||
      this == ProxyProtocol.socks ||
      this == ProxyProtocol.http;

  /// VMess needs `alterId`; the others ignore it.
  bool get hasAlterId => this == ProxyProtocol.vmess;

  bool get supportsReality =>
      this == ProxyProtocol.vless || this == ProxyProtocol.trojan;

  Map<String, Object?> toJson() => <String, Object?>{'protocol': wireName};

  @override
  String toString() => label;
}

/// Symmetric ciphers offered for VMess payload encryption. Xray picks
/// `chacha20-poly1305` when `auto` is requested; we default to `auto` to match.
enum VmessCipher {
  auto('auto'),
  chacha20Poly1305('chacha20-poly1305'),
  aes128Gcm('aes-128-gcm'),
  zero('none');

  const VmessCipher(this.wireName);
  final String wireName;

  static VmessCipher fromName(String? raw) {
    final s = raw?.trim().toLowerCase();
    for (final e in VmessCipher.values) {
      if (e.wireName == s) return e;
    }
    return VmessCipher.auto;
  }
}

/// Shadowsocks AEAD ciphers (SIP002 + 2022 family).
const List<String> kShadowsocksCiphers = <String>[
  'aes-128-gcm',
  'aes-192-gcm',
  'aes-256-gcm',
  'chacha20-ietf-poly1305',
  'xchacha20-ietf-poly1305',
  '2022-blake3-aes-128-gcm',
  '2022-blake3-aes-256-gcm',
  '2022-blake3-chacha20-poly1305',
];

bool isKnownShadowsocksCipher(String? cipher) {
  final c = asString(cipher).trim().toLowerCase();
  return kShadowsocksCiphers.contains(c);
}
