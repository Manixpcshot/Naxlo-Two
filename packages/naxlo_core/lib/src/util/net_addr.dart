/// Address:port handling shared by the parsers, the prober and the config
/// builders. Kept tiny and allocation-light: it runs per probe.
class NetAddr {
  const NetAddr(this.host, this.port);

  final String host;
  final int port;

  /// Accepts `1.2.3.4:443`, `[::1]:443`, `example.com:8443` and bare hosts
  /// (port = 0). Returns null for garbage so callers can collect errors.
  static NetAddr? tryParse(String raw, {int defaultPort = 0}) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    if (s.startsWith('[')) {
      final close = s.indexOf(']');
      if (close < 0) return null;
      final host = s.substring(1, close);
      var port = defaultPort;
      if (s.length > close + 1) {
        if (s[close + 1] != ':') return null;
        port = int.tryParse(s.substring(close + 2)) ?? defaultPort;
      }
      if (port < 0 || port > 65535) return null;
      return NetAddr(host, port);
    }
    final firstColon = s.indexOf(':');
    final lastColon = s.lastIndexOf(':');
    // More than one colon without brackets means a bare IPv6, no port.
    if (firstColon != lastColon) {
      return NetAddr(_strip(s), defaultPort);
    }
    if (firstColon < 0) return NetAddr(_strip(s), defaultPort);
    final host = s.substring(0, firstColon);
    final port = int.tryParse(s.substring(firstColon + 1)) ?? defaultPort;
    if (host.isEmpty) return null;
    if (port < 0 || port > 65535) return null;
    return NetAddr(host, port);
  }

  static String _strip(String host) {
    var h = host;
    if (h.endsWith('.')) h = h.substring(0, h.length - 1);
    return h;
  }

  /// `host:port`, bracketing IPv6 literals as RFC 3986 requires.
  @override
  String toString() {
    if (isIpv6) return '[$host]:$port';
    return '$host:$port';
  }

  String get hostOrIp => host;

  bool get isIpv6 => host.contains(':');

  bool get isIpv4 {
    final parts = host.split('.');
    if (parts.length != 4) return false;
    for (final p in parts) {
      final v = int.tryParse(p);
      if (v == null || v < 0 || v > 255) return false;
    }
    return true;
  }

  bool get isIpAddress => isIpv4 || isIpv6;
}
