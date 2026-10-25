import 'dart:convert';

import '../json/json_utils.dart';
import '../models/proxy_protocol.dart';
import '../models/security.dart';
import '../models/server_node.dart';
import '../models/transport.dart';
import '../sharelink/share_link.dart';

/// Decoded subscription response.
///
/// Subscriptions are the wild west: a provider may return base64 link lists,
/// plain text, a Clash YAML (which we do not fully honour) or a single link.
/// The parser therefore degrades in a fixed order and reports what it gave up
/// on instead of throwing — a half-working subscription beats an error dialog.
class SubscriptionResult {
  const SubscriptionResult({
    required this.nodes,
    required this.errors,
    this.title = '',
    this.updateInfo,
    this.looksLikeClash = false,
  });

  final List<ServerNode> nodes;
  final List<String> errors;
  final String title;
  final SubscriptionUserinfo? updateInfo;

  /// True when the body contained `proxies:`/`port:` keys we can't map — the UI
  /// should say "this is a Clash config; import its links instead".
  final bool looksLikeClash;

  bool get isEmpty => nodes.isEmpty;
  int get count => nodes.length;
}

/// `subscription-userinfo` / `profile-update-info` headers.
class SubscriptionUserinfo {
  const SubscriptionUserinfo({this.upload = 0, this.download = 0, this.total = 0, this.expire = 0});

  final int upload;
  final int download;

  /// Byte quota, 0 = unlimited.
  final int total;

  /// Unix seconds, 0 = never.
  final int expire;

  int get usedBytes => upload + download;
  bool get hasQuota => total > 0;
  bool get hasExpiry => expire > 0;

  double get ratio {
    if (!hasQuota) return 0;
    return (usedBytes / total).clamp(0.0, 1.0).toDouble();
  }

  /// Accepts `upload=1; download=2; total=0; expire=0` (spaces and `;`
  /// optional — both variants exist in the wild).
  static SubscriptionUserinfo? parse(String? header) {
    final raw = asString(header).trim();
    if (raw.isEmpty) return null;
    final out = <String, int>{};
    for (final part in raw.split(RegExp(r'[;,]'))) {
      final eq = part.indexOf('=');
      if (eq <= 0) continue;
      final k = part.substring(0, eq).trim().toLowerCase();
      out[k] = int.tryParse(part.substring(eq + 1).trim()) ?? 0;
    }
    if (out.isEmpty) return null;
    return SubscriptionUserinfo(
      upload: out['upload'] ?? 0,
      download: out['download'] ?? 0,
      total: out['total'] ?? 0,
      expire: out['expire'] ?? out['valid_until'] ?? 0,
    );
  }
}

class SubscriptionParser {
  /// [body] is the response text, [headers] the response headers (case
  /// insensitive lookup is done here).
  static SubscriptionResult decode(
    String body, {
    Map<String, String> headers = const <String, String>{},
    String sourceId = '',
  }) {
    final errors = <String>[];
    var text = body.trim();
    if (text.isEmpty) {
      return SubscriptionResult(
        nodes: const <ServerNode>[],
        errors: const <String>['empty response body'],
      );
    }

    final clashish = text.contains('\nproxies:') || text.startsWith('proxies:') || text.contains('\nports:');

    // A subscription endpoint may return: links, base64 of links, or base64 of
    // base64 of links (yes, really). Try each in turn and keep the first that
    // yields nodes.
    var import = ShareLinkParser.parseMany(text, sourceId: sourceId);
    if (import.nodes.isEmpty) {
      final decoded = _maybeBase64(text);
      if (decoded != null) {
        import = ShareLinkParser.parseMany(decoded, sourceId: sourceId);
        if (import.nodes.isNotEmpty) text = decoded;
      }
    }
    if (import.nodes.isEmpty && _looksLikeSingleJson(text)) {
      // A single inbounds JSON config, not a link list.
      final node = _nodeFromOutboundJson(text);
      if (node != null) {
        import = ShareLinkImport(nodes: <ServerNode>[node], errors: const <String>[]);
      }
    }

    errors.addAll(import.errors);

    var title = _headerValue(headers, 'profile-title');
    if (title.isEmpty) {
      title = _headerValue(headers, 'subscription-title');
    }
    if (title.isEmpty) {
      // Many panels put the name in a `#` comment on the first line.
      final firstLine = text.split('\n').first.trim();
      if (firstLine.startsWith('#')) title = Uri.decodeComponent(firstLine.substring(1).trim());
    }
    if (title.isNotEmpty && title.codeUnitAt(0) == 0xFEFF) title = title.substring(1);

    return SubscriptionResult(
      nodes: dedupeNodes(import.nodes),
      errors: errors,
      title: title,
      updateInfo: SubscriptionUserinfo.parse(
        _headerValue(headers, 'subscription-userinfo').isEmpty
            ? _headerValue(headers, 'profile-update-info')
            : _headerValue(headers, 'subscription-userinfo'),
      ),
      looksLikeClash: clashish && import.nodes.isEmpty,
    );
  }

  /// Drops duplicate endpoints, keeping the first remark seen. Providers
  /// routinely list the same VPS three times under `TL1`, `TL2`, `TL3`.
  static List<ServerNode> dedupeNodes(List<ServerNode> nodes) {
    final seen = <String>{};
    final out = <ServerNode>[];
    for (final n in nodes) {
      if (seen.add(n.fingerprint)) out.add(n);
    }
    return out;
  }

  static String _headerValue(Map<String, String> headers, String name) {
    for (final e in headers.entries) {
      if (e.key.toLowerCase() == name.toLowerCase()) return e.value.trim();
    }
    return '';
  }

  static String? _maybeBase64(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), '');
    if (flat.length % 4 != 0 || flat.length < 16) return null;
    if (!RegExp(r'^[A-Za-z0-9+/=_-]+$').hasMatch(flat)) return null;
    final decoded = ShareLinkParser.decodeBase64Loose(flat);
    if (decoded.isEmpty) return null;
    if (!decoded.contains('://')) return null;
    return decoded;
  }

  static bool _looksLikeSingleJson(String text) {
    final t = text.trimLeft();
    return t.startsWith('{') && t.contains('outbounds');
  }

  /// Best-effort: pull the first usable outbound out of an imported Xray JSON.
  static ServerNode? _nodeFromOutboundJson(String text) {
    try {
      final decoded = json.decode(text);
      if (decoded is! Map) return null;
      final outbounds = asList(decoded['outbounds']);
      for (final raw in outbounds) {
        final ob = asMap(raw);
        final protocol = ProxyProtocol.tryFrom(asString(ob['protocol']));
        if (protocol == null) continue;
        final settings = asMap(ob['settings']);
        final stream = asMap(ob['streamSettings']);
        // VLESS does not use `settings.servers`: it nests `vnext[]`, with the id and
        // flow one level deeper in `users[]`. Reading only `servers` found nothing in
        // the most common exported panel config, so "import a JSON file" produced zero
        // nodes and an empty profile with no error.
        final servers = <Map<String, Object?>>[
          for (final e in asList(settings['servers'])) asMap(e),
          for (final e in asList(settings['vnext'])) asMap(e),
        ];
        final firstServer = servers.isEmpty ? <String, Object?>{} : servers.first;
        final users = asList(firstServer['users']);
        final user = users.isEmpty ? const <String, Object?>{} : asMap(users.first);
        final address = asString(firstServer['address'], fallback: asString(settings['address']));
        if (address.isEmpty) continue;
        return ServerNode(
          id: 'imported${DateTime.now().millisecondsSinceEpoch}',
          name: asString(ob['tag'], fallback: address),
          address: address,
          port: asInt(firstServer['port'], fallback: asInt(settings['port'], fallback: 443)),
          protocol: protocol,
          userId: asString(user['id'],
              fallback: asString(firstServer['id'], fallback: asString(settings['password']))),
          password: asString(settings['password']),
          alterId: asInt(firstServer['alterId']),
          tls: TlsOptions(
            security: SecurityLayer.fromName(asString(stream['security'])),
            serverName: asString(asMap(stream['tlsSettings'])['serverName']),
          ),
          transportOptions: TransportOptions(
            transport: Transport.fromName(asString(stream['network'])),
            path: asString(asMap(stream['wsSettings'])['path']),
            host: asString(asMap(asMap(stream['wsSettings'])['headers'])['Host']),
          ),
        );
      }
    } on Object {
      return null;
    }
    return null;
  }
}

/// Merges freshly fetched nodes into an existing profile without throwing away
/// the latency history of the nodes that survived — that history is what makes
/// the ranker useful across subscription refreshes.
class SubscriptionMerger {
  const SubscriptionMerger();

  static MergeReport merge({
    required List<ServerNode> existing,
    required List<ServerNode> incoming,
    bool keepDisabled = true,
    bool rename = true,
  }) {
    final byFingerprint = <String, ServerNode>{
      for (final n in existing) n.fingerprint: n,
    };
    final result = <ServerNode>[];
    final added = <String>[];
    final removed = <String>[];
    final keptIds = <String>{};

    for (final node in incoming) {
      final previous = byFingerprint[node.fingerprint];
      if (previous == null) {
        result.add(node);
        added.add(node.displayName);
      } else {
        keptIds.add(previous.id);
        result.add(previous.copyWith(
          // New remark wins (providers rename for a reason), but id, enabled
          // flag and manual weight survive the refresh.
          name: rename ? node.name : previous.name,
          country: node.country.isEmpty ? previous.country : node.country,
          labels: node.labels.isEmpty ? previous.labels : node.labels,
          enabled: keepDisabled ? previous.enabled : true,
        ));
      }
    }
    for (final n in existing) {
      if (!keptIds.contains(n.id) && !added.contains(n.displayName)) {
        removed.add(n.displayName);
      }
    }
    return MergeReport(
      servers: result,
      added: added,
      removed: removed,
      retainedHistoryIds: keptIds,
    );
  }
}

class MergeReport {
  const MergeReport({
    required this.servers,
    required this.added,
    required this.removed,
    required this.retainedHistoryIds,
  });

  final List<ServerNode> servers;
  final List<String> added;
  final List<String> removed;

  /// Ids whose ranker history was carried over — the caller keeps their
  /// `ServerMetrics` entries and prunes the rest.
  final Set<String> retainedHistoryIds;

  int get netChange => added.length - removed.length;
  String get summary {
    final parts = <String>['${servers.length} nodes'];
    if (added.isNotEmpty) parts.add('+${added.length} new');
    if (removed.isNotEmpty) parts.add('-${removed.length} gone');
    return parts.join(', ');
  }
}
