import '../json/json_utils.dart';

/// Small, dependency-free geo data. A full GeoIP/GeoSite load is deliberately
/// *not* bundled: the engines ship their own .dat files, and shipping
/// CC-BY-NC-SA data in a release artifact would be a license problem. These
/// lists cover the cases that actually need to be right on a client.

/// RFC1918 + loopback + link-local + CGNAT + doc ranges.
const List<String> kPrivateIpv4Cidrs = <String>[
  '0.0.0.0/8',
  '10.0.0.0/8',
  '100.64.0.0/10',
  '127.0.0.0/8',
  '169.254.0.0/16',
  '172.16.0.0/12',
  '192.0.0.0/24',
  '192.168.0.0/16',
  '198.18.0.0/15',
  '224.0.0.0/4',
  '240.0.0.0/4',
];

const List<String> kPrivateIpv6Cidrs = <String>[
  '::/128',
  '::1/128',
  'fc00::/7',
  'fe80::/10',
  'ff00::/8',
];

/// Names that must never go through a tunnel.
const List<String> kLanDomainSuffixes = <String>[
  'local',
  'localhost',
  'localdomain',
  'internal',
  'in-addr.arpa',
  'ip6.arpa',
  'home.arpa',
];

/// A short, conservative ad/tracker list for the `blockAds` preset. Users who
/// want real coverage point the engine at their own geosite file instead.
const List<String> kAdDomains = <String>[
  'doubleclick.net',
  'googlesyndication.com',
  'googleadservices.com',
  'adnxs.com',
  'adsafeprotected.com',
  'moatads.com',
  'scorecardresearch.com',
  'criteo.com',
  'taboola.com',
  'popads.net',
];

/// `10.0.0.0/24`-style containment for IPv4. Returns false for IPv6 input;
/// [ipv6MatchesPrefix] handles those.
bool ipv4InCidr(String ip, String cidr) {
  final slash = cidr.indexOf('/');
  final base = slash < 0 ? cidr : cidr.substring(0, slash);
  final bits = slash < 0 ? 32 : (int.tryParse(cidr.substring(slash + 1)) ?? 32);
  if (bits < 0 || bits > 32) return false;
  final a = _ipv4ToInt(ip);
  final b = _ipv4ToInt(base);
  if (a == null || b == null) return false;
  if (bits == 0) return true;
  final mask = (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF;
  return (a & mask) == (b & mask);
}

int? _ipv4ToInt(String ip) {
  final parts = ip.split('.');
  if (parts.length != 4) return null;
  var v = 0;
  for (final p in parts) {
    final n = int.tryParse(p);
    if (n == null || n < 0 || n > 255) return null;
    v = (v << 8) | n;
  }
  return v;
}

/// Compare two IPv6 addresses against a prefix length. Written on 128-bit
/// halves to stay allocation-free per probe.
bool ipv6MatchesPrefix(String ip, String prefix) {
  final slash = prefix.indexOf('/');
  final base = slash < 0 ? prefix : prefix.substring(0, slash);
  final bits = slash < 0 ? 128 : (int.tryParse(prefix.substring(slash + 1)) ?? 128);
  if (bits < 0 || bits > 128) return false;
  final a = _ipv6ToBytes(ip);
  final b = _ipv6ToBytes(base);
  if (a == null || b == null) return false;
  for (var i = 0; i < 16; i++) {
    final bitStart = i * 8;
    if (bitStart >= bits) return true;
    final remaining = bits - bitStart;
    if (remaining >= 8) {
      if (a[i] != b[i]) return false;
    } else {
      final mask = (0xFF << (8 - remaining)) & 0xFF;
      if ((a[i] & mask) != (b[i] & mask)) return false;
      return true;
    }
  }
  return true;
}

List<int>? _ipv6ToBytes(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return null;
  if (s.startsWith('[') && s.endsWith(']')) s = s.substring(1, s.length - 1);
  if (!s.contains(':')) return null;
  final halves = s.split('::');
  if (halves.length > 2) return null;

  List<int> parse(String part) {
    final out = <int>[];
    if (part.isEmpty) return out;
    for (final g in part.split(':')) {
      if (g.isEmpty) return const <int>[];
      final v = int.tryParse(g, radix: 16);
      if (v == null || v < 0 || v > 0xFFFF) return const <int>[];
      out.add((v >> 8) & 0xFF);
      out.add(v & 0xFF);
    }
    return out;
  }

  final head = parse(halves[0]);
  if (halves.length == 1) {
    final groups = s.split(':').length;
    if (groups != 8 || head.length != 16) return null;
    return head;
  }
  final tail = parse(halves[1]);
  if (head.length + tail.length > 16) return null;
  final out = <int>[...head];
  while (out.length < 16 - tail.length) {
    out.add(0);
  }
  out.addAll(tail);
  return out;
}

/// True for loopback/RFC1918/CGNAT/link-local (v4 or v6).
bool isPrivateAddress(String address) {
  if (address.contains(':')) {
    for (final cidr in kPrivateIpv6Cidrs) {
      if (ipv6MatchesPrefix(address, cidr)) return true;
    }
    return false;
  }
  for (final cidr in kPrivateIpv4Cidrs) {
    if (ipv4InCidr(address, cidr)) return true;
  }
  return false;
}

/// Rule-list helper: `["10.0.0.0/8", "fe80::/10"]` vs a target address.
bool cidrMatchesAny(List<String> cidrs, String address) {
  final v6 = address.contains(':');
  for (final raw in cidrs) {
    final cidr = raw.trim();
    if (cidr.isEmpty) continue;
    if (cidr.contains('/')) {
      final isCidrV6 = cidr.substring(0, cidr.indexOf('/')).contains(':');
      if (isCidrV6 != v6) continue;
      if (isCidrV6) {
        if (ipv6MatchesPrefix(address, cidr)) return true;
      } else if (ipv4InCidr(address, cidr)) {
        return true;
      }
      continue;
    }
    // bare address == /128 or /32
    if (cidr.toLowerCase() == address.toLowerCase()) return true;
  }
  return false;
}

/// Parses the `geo:` / `ext:` / `` prefixes users paste from v2ray configs.
Map<String, Object?> ruleValuesToEngineList(List<String> values) {
  final domains = <String>[];
  final cidrs = <String>[];
  for (final raw in values) {
    final v = raw.trim();
    if (v.isEmpty) continue;
    if (v.contains('/') && (v.contains('.') || v.contains(':'))) {
      cidrs.add(v);
    } else if (RegExp(r'^[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)+$').hasMatch(v)) {
      domains.add(v);
    } else {
      domains.add(v);
    }
  }
  return <String, Object?>{
    'domain': List<String>.unmodifiable(domains),
    'cidr': List<String>.unmodifiable(cidrs),
  };
}
