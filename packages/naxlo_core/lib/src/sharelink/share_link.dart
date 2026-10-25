import 'dart:convert';

import '../json/json_utils.dart';
import '../models/proxy_protocol.dart';
import '../models/security.dart';
import '../models/server_node.dart';
import '../models/transport.dart';

/// Parsed or generated share link.
///
/// Supported shapes (the same set Happ accepts, plus the HTTP transport):
///
/// ```
/// vless://uuid@host:port?encryption=none&security=reality&pbk=…#Name
/// vmess://<base64 json>                       (and vmess://uuid@host:port?… variants)
/// trojan://password@host:port?allowInsecure=1&sni=…#Name
/// ss://base64(cipher:password)@host:port#Name (SIP002) and ss://base64(cipher:pw@host:port)
/// socks5://user:pass@host:port#Name
/// http://user:pass@host:port#Name
/// ```
class ShareLink {
  const ShareLink({required this.link, required this.node});

  final String link;
  final ServerNode node;
}

/// Outcome of parsing a blob of text that may contain several links.
class ShareLinkImport {
  const ShareLinkImport({required this.nodes, required this.errors});

  final List<ServerNode> nodes;

  /// `line → message`, so the UI can say "3 of 5 imported" instead of failing.
  final List<String> errors;

  bool get isEmpty => nodes.isEmpty;
  int get count => nodes.length;
}

/// The pieces of `scheme://userInfo@host:port/path?query#fragment`.
///
/// Split by hand on purpose. `Uri.parse` treats the **first** `@` as the
/// userinfo boundary, so a Trojan password of `p@ss` silently yields host
/// `ss@1.2.3.4` — the classic "import worked, connect fails" bug. Proxy
/// secrets are arbitrary base64-ish text, so we take the **last** `@`.
class _Link {
  _Link._(this.userInfo, this.host, this.port, this.path, this.query, this.fragment);

  final String userInfo;
  final String host;
  final int port;
  final String path;
  final Map<String, String> query;
  final String fragment;

  String get secret => _decode(userInfo);

  static _Link? tryParse(String scheme, String raw) {
    var rest = raw.trim();
    final prefix = '$scheme://';
    if (!rest.toLowerCase().startsWith(prefix)) return null;
    rest = rest.substring(prefix.length);

    var fragment = '';
    final hash = rest.indexOf('#');
    if (hash >= 0) {
      fragment = _decode(rest.substring(hash + 1));
      rest = rest.substring(0, hash);
    }

    var query = <String, String>{};
    final q = rest.indexOf('?');
    if (q >= 0) {
      query = _splitQuery(rest.substring(q + 1));
      rest = rest.substring(0, q);
    }

    var path = '';
    final slash = rest.indexOf('/');
    if (slash >= 0) {
      path = _decode(rest.substring(slash + 1));
      rest = rest.substring(0, slash);
    }

    var userInfo = '';
    var hostPort = rest;
    final at = rest.lastIndexOf('@');
    if (at >= 0) {
      userInfo = rest.substring(0, at);
      hostPort = rest.substring(at + 1);
    }

    var host = '';
    var port = 0;
    if (hostPort.startsWith('[')) {
      final close = hostPort.indexOf(']');
      if (close < 0) return null;
      host = hostPort.substring(1, close);
      final tail = hostPort.substring(close + 1);
      if (tail.startsWith(':')) port = int.tryParse(tail.substring(1)) ?? 0;
    } else {
      final colon = hostPort.lastIndexOf(':');
      if (colon < 0) {
        host = hostPort;
      } else {
        host = hostPort.substring(0, colon);
        port = int.tryParse(hostPort.substring(colon + 1)) ?? 0;
      }
    }
    if (host.isEmpty) return null;
    if (port < 0 || port > 65535) return null;
    return _Link._(userInfo, host, port, path, query, fragment);
  }

  String param(String name, {String fallback = ''}) {
    final v = query[name];
    if (v == null) return fallback;
    return v;
  }
}

class ShareLinkParser {
  /// Parse one link. Returns null for anything that is not a proxy URL, so the
  /// caller can show a per-line error instead of aborting the whole import.
  static ServerNode? tryParse(String raw, {String sourceId = '', String? forcedId}) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    final lower = s.toLowerCase();
    final id = forcedId ?? _newId();
    try {
      if (lower.startsWith('vless://')) return _parseVless(s, id, sourceId);
      if (lower.startsWith('vmess://')) return _parseVmess(s, id, sourceId);
      if (lower.startsWith('trojan://')) return _parseTrojan(s, id, sourceId);
      if (lower.startsWith('ss://')) return _parseShadowsocks(s, id, sourceId);
      if (lower.startsWith('socks://') || lower.startsWith('socks5://')) {
        return _parseSocks(s, id, sourceId);
      }
      if (lower.startsWith('http://')) return _parseHttp(s, id, sourceId);
    } on FormatException {
      return null;
    } on Object {
      return null;
    }
    return null;
  }

  /// Parse a multi-line blob (a paste from a panel, or a decoded subscription).
  static ShareLinkImport parseMany(String blob, {String sourceId = ''}) {
    final nodes = <ServerNode>[];
    final errors = <String>[];
    // Split on ONE newline, not `[\r\n]+`: collapsing blank lines shifts every
    // subsequent index, so a bad link on line 5 was reported as "line 4" and the
    // user went looking at the wrong line of a 200-line subscription.
    final lines = blob.split(RegExp(r'\r?\n'));
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith('//')) continue;
      final node = tryParse(line, sourceId: sourceId);
      if (node == null) {
        errors.add('line ${i + 1}: unrecognized link "${_ellipsis(line)}"');
      } else {
        nodes.add(node);
      }
    }
    return ShareLinkImport(nodes: nodes, errors: errors);
  }

  static String _ellipsis(String s) => s.length <= 42 ? s : '${s.substring(0, 42)}…';

  static int _counter = 0;
  static String _newId() {
    _counter++;
    return 'srv${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}${_counter.toRadixString(36)}';
  }

  // ── protocol parsers ────────────────────────────────────────────────────

  static ServerNode _parseVless(String s, String id, String sourceId) {
    final link = _Link.tryParse('vless', s)!;
    final security = SecurityLayer.fromName(
      link.param('security') == 'reality' ? 'reality' : link.param('security'),
    );
    return ServerNode(
      id: id,
      name: link.fragment.isEmpty ? link.host : link.fragment,
      address: link.host,
      port: link.port == 0 ? 443 : link.port,
      protocol: ProxyProtocol.vless,
      userId: link.secret,
      flow: link.param('flow'),
      tls: TlsOptions(
        security: security,
        serverName: link.param('sni', fallback: link.param('peer')),
        alpn: _splitAlpn(link.param('alpn')),
        fingerprint: link.param('fp'),
        allowInsecure: _truthy(link.param('allowInsecure')),
        publicKey: link.param('pbk'),
        shortId: link.param('sid'),
        spiderX: link.param('spx'),
        echQuery: link.param('ech'),
      ),
      transportOptions: TransportOptions(
        transport: Transport.fromName(link.param('type', fallback: link.param('network'))),
        host: link.param('host'),
        path: link.param('path', fallback: link.path),
        headers: _headersFrom(link.query),
        xhttpMode: link.param('mode', fallback: 'auto'),
      ),
      sourceId: sourceId,
      rawRemark: link.fragment,
    );
  }

  static ServerNode _parseVmess(String s, String id, String sourceId) {
    final body = s.substring('vmess://'.length).trim();
    // Base64-JSON is by far the common case. Some panels emit a URL instead,
    // so fall back to that only when the payload is clearly not JSON-ish.
    if (body.contains('@') && !_looksLikeBase64(body)) {
      final link = _Link.tryParse('vmess', 'vmess://$body')!;
      return ServerNode(
        id: id,
        name: link.fragment.isEmpty ? link.host : link.fragment,
        address: link.host,
        port: link.port == 0 ? 443 : link.port,
        protocol: ProxyProtocol.vmess,
        userId: link.secret,
        alterId: asInt(link.param('aid')),
        cipher: VmessCipher.fromName(link.param('scy')),
        tls: TlsOptions(
          security: SecurityLayer.fromName(
            link.param('tls', fallback: link.param('security')),
          ),
          serverName: link.param('sni'),
          alpn: _splitAlpn(link.param('alpn')),
          fingerprint: link.param('fp'),
          allowInsecure: _truthy(link.param('allowInsecure')),
        ),
        transportOptions: TransportOptions(
          transport: Transport.fromName(link.param('type', fallback: link.param('net'))),
          host: link.param('host'),
          path: link.param('path', fallback: link.path),
          headers: _headersFrom(link.query),
        ),
        sourceId: sourceId,
      );
    }
    final json = _decodeBase64Json(body);
    if (json == null) {
      throw const FormatException('vmess payload is not base64-encoded JSON');
    }
    final portValue = json['port'];
    final port = portValue is String ? (int.tryParse(portValue) ?? 0) : asInt(portValue);
    final remark = _decode(asString(json['ps']));
    final headers = <String, String>{};
    final rawHeaders = json['hdr'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((k, v) => headers[k.toString()] = v.toString());
    }
    if (headers['Host'] == null) {
      final host = asString(json['host']);
      if (host.isNotEmpty) headers['Host'] = host;
    }
    return ServerNode(
      id: id,
      name: remark.isEmpty ? 'vmess $port' : remark,
      address: asString(json['add']),
      port: port,
      protocol: ProxyProtocol.vmess,
      userId: asString(json['id']),
      alterId: asInt(json['aid']),
      cipher: VmessCipher.fromName(asString(json['scy'])),
      tls: TlsOptions(
        security: SecurityLayer.fromName(asString(json['tls'])),
        serverName: asString(json['sni']),
        alpn: _splitAlpn(asString(json['alpn'])),
        allowInsecure: _truthy(asString(json['allowInsecure'])),
      ),
      transportOptions: TransportOptions(
        transport: Transport.fromName(asString(json['net'])),
        host: asString(json['host']),
        path: asString(json['path']),
        headers: headers,
      ),
      sourceId: sourceId,
      rawRemark: remark,
    );
  }

  static ServerNode _parseTrojan(String s, String id, String sourceId) {
    final link = _Link.tryParse('trojan', s)!;
    final securityParam = link.param('security');
    final SecurityLayer security;
    if (link.param('type') == 'reality' || securityParam == 'reality') {
      security = SecurityLayer.reality;
    } else if (securityParam == 'tls' || link.param('sni').isNotEmpty || link.param('peer').isNotEmpty) {
      security = SecurityLayer.tls;
    } else {
      security = SecurityLayer.none;
    }
    return ServerNode(
      id: id,
      name: link.fragment.isEmpty ? link.host : link.fragment,
      address: link.host,
      port: link.port == 0 ? 443 : link.port,
      protocol: ProxyProtocol.trojan,
      password: link.secret,
      tls: TlsOptions(
        security: security,
        serverName: link.param('sni', fallback: link.param('peer')),
        alpn: _splitAlpn(link.param('alpn')),
        fingerprint: link.param('fp'),
        allowInsecure: _truthy(link.param('allowInsecure')),
        publicKey: link.param('pbk'),
        shortId: link.param('sid'),
        spiderX: link.param('spx'),
      ),
      transportOptions: TransportOptions(
        // `type=reality` is a security field, not a transport: the transport is
        // whatever `network`/`headerType` says, else tcp.
        transport: Transport.fromName(link.param('type') == 'reality' ? '' : link.param('type')),
        host: link.param('host'),
        path: link.param('path', fallback: link.path),
        headers: _headersFrom(link.query),
      ),
      sourceId: sourceId,
      rawRemark: link.fragment,
    );
  }

  static ServerNode _parseShadowsocks(String s, String id, String sourceId) {
    var body = s.substring('ss://'.length).trim();
    var remark = '';
    final hash = body.indexOf('#');
    if (hash >= 0) {
      remark = _decode(body.substring(hash + 1));
      body = body.substring(0, hash);
    }
    var query = <String, String>{};
    final q = body.indexOf('?');
    if (q >= 0) {
      query = _splitQuery(body.substring(q + 1));
      body = body.substring(0, q);
    }

    var cipher = '';
    var password = '';
    var host = '';
    var port = 0;

    final at = body.lastIndexOf('@');
    if (at >= 0) {
      // SIP002: base64url(method:password)@host:port
      final creds = _base64DecodeLoose(body.substring(0, at));
      final tail = body.substring(at + 1);
      final colon = tail.lastIndexOf(':');
      if (colon >= 0) {
        host = tail.substring(0, colon);
        port = int.tryParse(tail.substring(colon + 1)) ?? 0;
      } else {
        host = tail;
      }
      final c = creds.indexOf(':');
      if (c >= 0) {
        cipher = creds.substring(0, c);
        password = creds.substring(c + 1);
      } else {
        cipher = query['method'] ?? query['cipher'] ?? 'aes-256-gcm';
        password = creds;
      }
      // `?plugin=obfs-local;obfs=http;obfs-host=…` carries a ws path/host.
      final plugin = query['plugin'];
      var transport = Transport.tcp;
      var path = '';
      var pluginHost = '';
      if (plugin != null && plugin.contains('obfs')) {
        transport = Transport.ws;
        for (final part in plugin.split(';').skip(1)) {
          final kv = part.split('=');
          if (kv.length == 2) {
            // `#` ends the value: panels frequently append their own remark
            // unencoded (`…;obfs-host=cdn#Node-7`), and the query split above has
            // already consumed the *real* fragment, so a surviving `#` is junk. A
            // hostname can never contain one, so truncating is strictly safer than
            // handing `cdn#Node-7` to the engine as a TLS SNI.
            if (kv[0] == 'obfs-host') pluginHost = kv[1].split('#').first.trim();
            if (kv[0] == 'obfs-uri') path = _decode(kv[1]);
          }
        }
      }
      return ServerNode(
        id: id,
        name: remark.isEmpty ? 'ss $host' : remark,
        address: host,
        port: port,
        protocol: ProxyProtocol.shadowsocks,
        password: password,
        // The SS cipher travels in `userId` so the editor, config builders and
        // the exporter all have one place to read it from.
        userId: cipher,
        tls: const TlsOptions(security: SecurityLayer.none),
        transportOptions: TransportOptions(
          transport: transport,
          host: pluginHost,
          path: path,
        ),
        sourceId: sourceId,
        rawRemark: remark,
      );
    }

    // Legacy: base64("cipher:password@host:port")
    final full = _base64DecodeLoose(body);
    final m = RegExp(r'^(.+)@([^@:]+):(\d+)$').firstMatch(full);
    if (m == null) throw const FormatException('ss:// payload is neither SIP002 nor legacy');
    final creds = m.group(1)!;
    host = m.group(2)!;
    port = int.parse(m.group(3)!);
    final c = creds.indexOf(':');
    cipher = c >= 0 ? creds.substring(0, c) : creds;
    password = c >= 0 ? creds.substring(c + 1) : '';
    if (cipher.isEmpty) cipher = 'aes-256-gcm';
    return ServerNode(
      id: id,
      name: remark.isEmpty ? 'ss $host' : remark,
      address: host,
      port: port,
      protocol: ProxyProtocol.shadowsocks,
      password: password,
      userId: cipher,
      sourceId: sourceId,
      rawRemark: remark,
    );
  }

  static ServerNode _parseSocks(String s, String id, String sourceId) {
    final link = _Link.tryParse(s.toLowerCase().startsWith('socks5://') ? 'socks5' : 'socks', s)!;
    final split = _userPass(link.userInfo);
    return ServerNode(
      id: id,
      name: link.fragment.isEmpty ? 'socks ${link.host}' : link.fragment,
      address: link.host,
      port: link.port == 0 ? 1080 : link.port,
      protocol: ProxyProtocol.socks,
      userId: split.$1,
      password: split.$2,
      tls: TlsOptions(
        security: SecurityLayer.fromName(link.param('security', fallback: link.param('type'))),
        serverName: link.param('sni'),
        allowInsecure: _truthy(link.param('allowInsecure')),
      ),
      sourceId: sourceId,
      rawRemark: link.fragment,
    );
  }

  static ServerNode _parseHttp(String s, String id, String sourceId) {
    final link = _Link.tryParse('http', s)!;
    final split = _userPass(link.userInfo);
    return ServerNode(
      id: id,
      name: link.fragment.isEmpty ? 'http ${link.host}' : link.fragment,
      address: link.host,
      port: link.port == 0 ? 80 : link.port,
      protocol: ProxyProtocol.http,
      userId: split.$1,
      password: split.$2,
      sourceId: sourceId,
      rawRemark: link.fragment,
    );
  }

  // ── helpers ───────────────────────────────────────────────────────────────

  static (String, String) _userPass(String raw) {
    final info = _decode(raw);
    if (info.isEmpty) return ('', '');
    final i = info.indexOf(':');
    if (i < 0) return ('', info);
    return (info.substring(0, i), info.substring(i + 1));
  }

  static List<String> _splitAlpn(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return const <String>[];
    return s.split(RegExp(r'[, ]+')).where((e) => e.isNotEmpty).toList(growable: false);
  }

  /// `Host` plus any repeated `headers[K]=V` pairs.
  static Map<String, String> _headersFrom(Map<String, String> query) {
    final headers = <String, String>{};
    query.forEach((k, v) {
      final key = k.toLowerCase();
      if (key == 'host' || key == 'path' || key == 'type' || key == 'network') return;
      if (key.startsWith('headers[') && key.endsWith(']')) {
        headers[k.substring(8, k.length - 1)] = v;
      }
    });
    final host = query['host'];
    if (host != null && host.isNotEmpty) headers['Host'] = host;
    return headers;
  }

  static bool _truthy(String raw) {
    final s = raw.trim().toLowerCase();
    return s == '1' || s == 'true' || s == 'yes';
  }

  static bool _looksLikeBase64(String body) {
    final flat = body.replaceAll(RegExp(r'\s+'), '');
    if (flat.length < 16 || flat.contains('/')) return false;
    return RegExp(r'^[A-Za-z0-9+_/=-]+$').hasMatch(flat);
  }


  static Map<String, Object?>? _decodeBase64Json(String body) {
    final text = _base64DecodeLoose(body);
    if (text.isEmpty) return null;
    try {
      final decoded = json.decode(text);
      if (decoded is Map) {
        return <String, Object?>{for (final e in decoded.entries) e.key.toString(): e.value};
      }
    } on FormatException {
      return null;
    }
    return null;
  }


  /// Base64 that tolerates URL-safe alphabets and missing padding — every panel
  /// does this slightly differently and rejecting an import over `+` vs `-` is
  /// not a trade worth making.
  static String decodeBase64Loose(String input) => _base64DecodeLoose(input);

  static String _base64DecodeLoose(String input) {
    var s = input.trim().replaceAll('-', '+').replaceAll('_', '/');
    if (s.contains('%')) s = _decode(s);
    final pad = s.length % 4;
    if (pad != 0) s = s.padRight(s.length + (4 - pad), '=');
    try {
      return utf8.decode(base64.decode(s), allowMalformed: true);
    } on FormatException {
      return '';
    }
  }
}

/// Generates the canonical share link for a node, so users can export what
/// they imported and move profiles between devices.
class ShareLinkWriter {
  static String forNode(ServerNode n, {bool includeRemark = true}) {
    switch (n.protocol) {
      case ProxyProtocol.vless:
        return _vless(n, includeRemark);
      case ProxyProtocol.vmess:
        return _vmess(n, includeRemark);
      case ProxyProtocol.trojan:
        return _trojan(n, includeRemark);
      case ProxyProtocol.shadowsocks:
        return _ss(n, includeRemark);
      case ProxyProtocol.socks:
        return _socks(n, includeRemark);
      case ProxyProtocol.http:
        return _http(n, includeRemark);
    }
  }

  static String _query(Map<String, String> params) {
    if (params.isEmpty) return '';
    return params.entries.map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}').join('&');
  }

  static String _authority(String secret, ServerNode n) {
    final encoded = Uri.encodeComponent(secret);
    final host = n.address.contains(':') ? '[${n.address}]' : n.address;
    // `${n.port}`, not `$n.port`: in a Dart string `$n` grabs only the identifier,
    // so `$n.port` interpolated the node's *toString()* and appended the literal
    // ".port". Every exported vless/trojan/socks link came out as
    // `...@1.2.3.4:ServerNode(Finland, 1.2.3.4:2053, vless).port` — unparseable by
    // any client, including this one. The round-trip test caught it.
    return encoded.isEmpty ? host : '$encoded@$host:${n.port}';
  }

  static String _remark(ServerNode n, bool include) {
    if (!include || n.name.isEmpty) return '';
    return '#${Uri.encodeComponent(n.name)}';
  }

  static String _vless(ServerNode n, bool include) {
    final q = <String, String>{
      'encryption': 'none',
      if (n.flow.isNotEmpty) 'flow': n.flow,
      if (n.tls.security != SecurityLayer.none) 'security': n.tls.security.wireName,
      if (n.tls.serverName.isNotEmpty) 'sni': n.tls.serverName,
      if (n.tls.fingerprint.isNotEmpty) 'fp': n.tls.fingerprint,
      if (n.tls.alpn.isNotEmpty) 'alpn': n.tls.alpn.join(','),
      if (n.tls.publicKey.isNotEmpty) 'pbk': n.tls.publicKey,
      if (n.tls.shortId.isNotEmpty) 'sid': n.tls.shortId,
      if (n.tls.spiderX.isNotEmpty) 'spx': n.tls.spiderX,
      if (n.tls.allowInsecure) 'allowInsecure': '1',
      if (n.transportOptions.transport != Transport.tcp) 'type': n.transportOptions.transport.wireName,
      if (n.transportOptions.host.isNotEmpty) 'host': n.transportOptions.host,
      if (n.transportOptions.path.isNotEmpty) 'path': n.transportOptions.path,
    };
    return 'vless://${_authority(n.userId, n)}${_query(q)}${_remark(n, include)}';
  }

  static String _vmess(ServerNode n, bool include) {
    final map = <String, Object?>{
      'v': '2',
      'ps': n.name,
      'add': n.address,
      'port': '${n.port}',
      'id': n.userId,
      'aid': n.alterId,
      'scy': n.cipher.wireName,
      'net': n.transportOptions.transport.wireName,
      'type': 'none',
      if (n.transportOptions.host.isNotEmpty) 'host': n.transportOptions.host,
      if (n.transportOptions.path.isNotEmpty) 'path': n.transportOptions.path,
      if (n.tls.security == SecurityLayer.tls) 'tls': 'tls',
      if (n.tls.serverName.isNotEmpty) 'sni': n.tls.serverName,
      if (n.tls.alpn.isNotEmpty) 'alpn': n.tls.alpn.join(','),
      if (include) 'remarks': n.name,
    };
    final encoded = base64.encode(utf8.encode(json.encode(map)));
    return 'vmess://$encoded';
  }

  static String _trojan(ServerNode n, bool include) {
    final q = <String, String>{
      if (n.tls.security != SecurityLayer.none) 'security': n.tls.security.wireName,
      if (n.tls.serverName.isNotEmpty) 'sni': n.tls.serverName,
      if (n.tls.alpn.isNotEmpty) 'alpn': n.tls.alpn.join(','),
      if (n.tls.fingerprint.isNotEmpty) 'fp': n.tls.fingerprint,
      if (n.tls.allowInsecure) 'allowInsecure': '1',
      if (n.transportOptions.transport != Transport.tcp) 'type': n.transportOptions.transport.wireName,
      if (n.transportOptions.host.isNotEmpty) 'host': n.transportOptions.host,
      if (n.transportOptions.path.isNotEmpty) 'path': n.transportOptions.path,
      if (n.tls.publicKey.isNotEmpty) 'pbk': n.tls.publicKey,
      if (n.tls.shortId.isNotEmpty) 'sid': n.tls.shortId,
    };
    return 'trojan://${_authority(n.password, n)}${_query(q)}${_remark(n, include)}';
  }

  static String _ss(ServerNode n, bool include) {
    final cipher = n.userId.isEmpty ? 'aes-256-gcm' : n.userId;
    final creds = base64Url.encode(utf8.encode('$cipher:${n.password}')).replaceAll('=', '');
    final host = n.address.contains(':') ? '[${n.address}]' : n.address;
    return 'ss://$creds@$host:${n.port}${_remark(n, include)}';
  }

  static String _socks(ServerNode n, bool include) {
    var auth = '';
    if (n.userId.isNotEmpty || n.password.isNotEmpty) {
      auth = '${Uri.encodeComponent(n.userId)}:${Uri.encodeComponent(n.password)}@';
    }
    final host = n.address.contains(':') ? '[${n.address}]' : n.address;
    return 'socks://$auth$host:${n.port}${_remark(n, include)}';
  }

  static String _http(ServerNode n, bool include) {
    var auth = '';
    if (n.userId.isNotEmpty || n.password.isNotEmpty) {
      auth = '${Uri.encodeComponent(n.userId)}:${Uri.encodeComponent(n.password)}@';
    }
    return 'http://$auth${n.address}:${n.port}${_remark(n, include)}';
  }
}

/// Splits `a=1&b=2` on the first `=` of each pair, percent-decoding both sides.
/// `Uri.splitQueryString` is deliberately not used: its treatment of `+` mangles
/// base64-ish values such as `path=/x+y`, and `+` is legal in a share link.
Map<String, String> _splitQuery(String query) {
  final out = <String, String>{};
  if (query.isEmpty) return out;
  for (final part in query.split('&')) {
    if (part.isEmpty) continue;
    final eq = part.indexOf('=');
    if (eq < 0) {
      out[_decode(part)] = '';
    } else {
      out[_decode(part.substring(0, eq))] = _decode(part.substring(eq + 1));
    }
  }
  return out;
}

String _decode(String raw) {
  if (!raw.contains('%')) return raw;
  try {
    return Uri.decodeComponent(raw);
  } on FormatException {
    return raw;
  }
}
