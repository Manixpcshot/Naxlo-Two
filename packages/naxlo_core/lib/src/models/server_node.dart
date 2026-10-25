import '../json/json_utils.dart';
import '../util/net_addr.dart';
import 'dns_config.dart';
import 'engine_kind.dart';
import 'proxy_protocol.dart';
import 'routing.dart';
import 'security.dart';
import 'transport.dart';

/// One proxy endpoint plus everything needed to speak to it. This is the unit
/// the ranker scores, the prober measures and the config builders emit.
class ServerNode {
  ServerNode({
    required this.id,
    required this.name,
    required this.address,
    required this.port,
    required this.protocol,
    this.userId = '',
    this.password = '',
    this.alterId = 0,
    this.cipher = VmessCipher.auto,
    this.flow = '',
    this.tls = const TlsOptions(),
    this.transportOptions = const TransportOptions(),
    this.mux = MuxOptions.disabled,
    this.enabled = true,
    this.labels = const <String>[],
    this.weight = 0,
    this.country = '',
    this.sourceId = '',
    this.rawRemark = '',
  });

  final String id;
  final String name;
  final String address;
  final int port;
  final ProxyProtocol protocol;

  /// UUID for VLESS/VMess, password for Trojan/Socks/HTTP, key for SS.
  final String userId;
  final String password;
  final int alterId;
  final VmessCipher cipher;

  /// VLESS-X over TLS flow (`xtls-rprx-vision`). Only meaningful for
  /// VLESS+TCP/TLS or VLESS+Reality; the config builders drop it elsewhere,
  /// because a flow on a WebSocket node is a fatal config error in Xray.
  final String flow;

  final TlsOptions tls;
  final TransportOptions transportOptions;
  final MuxOptions mux;

  /// Disabled nodes stay in the profile but never enter the candidate set.
  final bool enabled;

  /// Free-form tags the user can type (`chatgpt`, `ix-below`, `stale`) — used
  /// by routing rules and by the filter chips in the servers screen.
  final List<String> labels;

  /// Manual bias in [-100, 100] added by the ranker; lets a user pin a node up
  /// or down without breaking the adaptive logic.
  final int weight;

  /// Two-letter hint imported from subscriptions when present, for the badge.
  final String country;

  /// Subscription/profile this node came from (empty for manual nodes).
  final String sourceId;

  /// Original remark before de-duplication, used for search.
  final String rawRemark;

  String get host => address;

  NetAddr get netAddr => NetAddr(address, port);

  String get endpoint => netAddr.toString();

  /// Identity used to de-duplicate nodes inside a profile and across
  /// subscription refreshes. Deliberately excludes name/labels: those change
  /// when a provider renames a node, and we must keep its latency history.
  String get fingerprint {
    final parts = <String>[
      protocol.wireName,
      address.toLowerCase(),
      '$port',
      userId.isEmpty ? password : userId,
      tls.security.wireName,
      tls.publicKey,
      transportOptions.transport.wireName,
      transportOptions.path,
    ];
    return parts.join('|');
  }

  bool get hasReality => tls.isReality;

  /// Vision flow is only valid on TCP (or direct) transports with TLS/Reality.
  bool get flowIsUsable =>
      flow.isNotEmpty &&
      protocol == ProxyProtocol.vless &&
      (transportOptions.transport == Transport.tcp) &&
      tls.security != SecurityLayer.none;
  bool get hasTls => tls.security == SecurityLayer.tls || tls.security == SecurityLayer.reality;
  bool get isPlaintext => !hasTls;

  /// Shown in the list; falls back to the endpoint so an unnamed import is
  /// never rendered as a blank row.
  String get displayName => name.isEmpty ? endpoint : name;

  ServerNode copyWith({
    String? id,
    String? name,
    String? address,
    int? port,
    ProxyProtocol? protocol,
    String? userId,
    String? password,
    int? alterId,
    VmessCipher? cipher,
    String? flow,
    TlsOptions? tls,
    TransportOptions? transportOptions,
    MuxOptions? mux,
    bool? enabled,
    List<String>? labels,
    int? weight,
    String? country,
    String? sourceId,
    String? rawRemark,
  }) {
    return ServerNode(
      id: id ?? this.id,
      name: name ?? this.name,
      address: address ?? this.address,
      port: port ?? this.port,
      protocol: protocol ?? this.protocol,
      userId: userId ?? this.userId,
      password: password ?? this.password,
      alterId: alterId ?? this.alterId,
      cipher: cipher ?? this.cipher,
      flow: flow ?? this.flow,
      tls: tls ?? this.tls,
      transportOptions: transportOptions ?? this.transportOptions,
      mux: mux ?? this.mux,
      enabled: enabled ?? this.enabled,
      labels: labels ?? this.labels,
      weight: weight ?? this.weight,
      country: country ?? this.country,
      sourceId: sourceId ?? this.sourceId,
      rawRemark: rawRemark ?? this.rawRemark,
    );
  }

  Map<String, Object?> toJson() => pruneNulls(<String, Object?>{
        'id': id,
        'name': name,
        'address': address,
        'port': port,
        'protocol': protocol.wireName,
        'userId': userId,
        'password': password,
        'alterId': alterId == 0 ? null : alterId,
        'cipher': protocol == ProxyProtocol.vmess ? cipher.wireName : null,
        if (flow.isNotEmpty) 'flow': flow,
        'tls': tls.toJson(),
        'transport': transportOptions.toJson(),
        'mux': mux.toJson(),
        'enabled': enabled,
        if (labels.isNotEmpty) 'labels': List<String>.from(labels),
        if (weight != 0) 'weight': weight,
        if (country.isNotEmpty) 'country': country,
        if (sourceId.isNotEmpty) 'sourceId': sourceId,
        if (rawRemark.isNotEmpty) 'rawRemark': rawRemark,
      });

  static ServerNode fromJson(Map<String, Object?> json) {
    final protocol = ProxyProtocol.tryFrom(asString(json['protocol'])) ?? ProxyProtocol.vless;
    return ServerNode(
      id: asString(json['id']),
      name: asString(json['name']),
      address: asString(json['address']),
      port: asInt(json['port'], fallback: 443),
      protocol: protocol,
      userId: asString(json['userId'], fallback: asString(json['uuid'])),
      password: asString(json['password']),
      alterId: asInt(json['alterId']),
      cipher: VmessCipher.fromName(asString(json['cipher'])),
      flow: asString(json['flow']),
      tls: TlsOptions.fromJson(asMap(json['tls'])),
      transportOptions: TransportOptions.fromJson(asMap(json['transport'])),
      mux: MuxOptions.fromJson(asMap(json['mux'])),
      enabled: asBool(json['enabled'], fallback: true),
      labels: asStringList(json['labels']),
      weight: asInt(json['weight']),
      country: asString(json['country']),
      sourceId: asString(json['sourceId']),
      rawRemark: asString(json['rawRemark']),
    );
  }

  @override
  String toString() => 'ServerNode($displayName, $endpoint, ${protocol.wireName})';
}

/// A named collection of nodes with its own routing/DNS/engine choices — the
/// thing a user thinks of as "a config". Mirrors Happ's profile concept.
class Profile {
  Profile({
    required this.id,
    required this.name,
    List<ServerNode> servers = const <ServerNode>[],
    this.routing = const RoutingConfig.defaults(),
    this.dns = const DnsConfig.defaults(),
    this.engine = EngineKind.xray,
    this.subscription,
    this.selectedServerId = '',
    this.autoSelect = true,
    this.notes = '',
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  final String id;
  final String name;
  final List<ServerNode> servers;
  final RoutingConfig routing;
  final DnsConfig dns;
  final EngineKind engine;
  final SubscriptionSource? subscription;

  /// "" means "auto": the selector decides. Otherwise a manual pin.
  final String selectedServerId;

  /// When false the ranker still scores, but never moves the active node.
  final bool autoSelect;
  final String notes;
  final int createdAt;
  final int updatedAt;

  List<ServerNode> get candidates =>
      servers.where((s) => s.enabled && s.address.isNotEmpty).toList(growable: false);

  ServerNode? byId(String serverId) {
    for (final s in servers) {
      if (s.id == serverId) return s;
    }
    return null;
  }

  ServerNode? get selected {
    if (selectedServerId.isEmpty) return null;
    final node = byId(selectedServerId);
    return (node != null && node.enabled) ? node : null;
  }

  Profile copyWith({
    String? name,
    List<ServerNode>? servers,
    RoutingConfig? routing,
    DnsConfig? dns,
    EngineKind? engine,
    SubscriptionSource? subscription,
    String? selectedServerId,
    bool? autoSelect,
    String? notes,
    int? updatedAt,
  }) {
    return Profile(
      id: id,
      name: name ?? this.name,
      servers: servers ?? this.servers,
      routing: routing ?? this.routing,
      dns: dns ?? this.dns,
      engine: engine ?? this.engine,
      subscription: subscription ?? this.subscription,
      selectedServerId: selectedServerId ?? this.selectedServerId,
      autoSelect: autoSelect ?? this.autoSelect,
      notes: notes ?? this.notes,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toJson() => pruneNulls(<String, Object?>{
        'id': id,
        'name': name,
        'servers': <Object?>[for (final s in servers) s.toJson()],
        'routing': routing.toJson(),
        'dns': dns.toJson(),
        'engine': engine.cliName,
        if (subscription != null) 'subscription': subscription!.toJson(),
        'selectedServerId': selectedServerId,
        'autoSelect': autoSelect,
        'notes': notes,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      });

  static Profile fromJson(Map<String, Object?> json) {
    return Profile(
      id: asString(json['id']),
      name: asString(json['name'], fallback: 'Profile'),
      servers: <ServerNode>[
        for (final raw in asList(json['servers'])) ServerNode.fromJson(asMap(raw)),
      ],
      routing: RoutingConfig.fromJson(asMap(json['routing'])),
      dns: DnsConfig.fromJson(asMap(json['dns'])),
      engine: EngineKind.fromName(asString(json['engine'])),
      subscription: json['subscription'] == null
          ? null
          : SubscriptionSource.fromJson(asMap(json['subscription'])),
      selectedServerId: asString(json['selectedServerId']),
      autoSelect: asBool(json['autoSelect'], fallback: true),
      notes: asString(json['notes']),
      createdAt: asInt(json['createdAt']),
      updatedAt: asInt(json['updatedAt']),
    );
  }
}

/// Where a profile's nodes came from, and what the last refresh said about
/// quota. `subscription-userinfo` values are bytes.
class SubscriptionSource {
  const SubscriptionSource({
    required this.url,
    this.title = '',
    this.lastFetchAtMs = 0,
    this.bytesUsed = 0,
    this.bytesQuota = 0,
    this.expiresAtMs = 0,
    this.refreshIntervalSec = 0,
    this.nodeCount = 0,
  });

  final String url;
  final String title;
  final int lastFetchAtMs;
  final int bytesUsed;

  /// 0 == unlimited / unknown.
  final int bytesQuota;

  /// 0 == never expires / unknown.
  final int expiresAtMs;

  /// `profile-update-interval` header, seconds.
  final int refreshIntervalSec;
  final int nodeCount;

  bool get hasQuota => bytesQuota > 0;
  bool get hasExpiry => expiresAtMs > 0;

  /// True when the provider says we should not have fetched yet.
  bool isTooEarly(int nowMs) {
    if (refreshIntervalSec <= 0 || lastFetchAtMs <= 0) return false;
    return nowMs - lastFetchAtMs < refreshIntervalSec * 1000;
  }

  double get usageRatio {
    if (!hasQuota || bytesQuota <= 0) return 0;
    return (bytesUsed / bytesQuota).clamp(0.0, 1.0).toDouble();
  }

  SubscriptionSource copyWith({
    String? url,
    String? title,
    int? lastFetchAtMs,
    int? bytesUsed,
    int? bytesQuota,
    int? expiresAtMs,
    int? refreshIntervalSec,
    int? nodeCount,
  }) {
    return SubscriptionSource(
      url: url ?? this.url,
      title: title ?? this.title,
      lastFetchAtMs: lastFetchAtMs ?? this.lastFetchAtMs,
      bytesUsed: bytesUsed ?? this.bytesUsed,
      bytesQuota: bytesQuota ?? this.bytesQuota,
      expiresAtMs: expiresAtMs ?? this.expiresAtMs,
      refreshIntervalSec: refreshIntervalSec ?? this.refreshIntervalSec,
      nodeCount: nodeCount ?? this.nodeCount,
    );
  }

  Map<String, Object?> toJson() => pruneNulls(<String, Object?>{
        'url': url,
        'title': title,
        'lastFetchAtMs': lastFetchAtMs,
        'bytesUsed': bytesUsed,
        'bytesQuota': bytesQuota,
        'expiresAtMs': expiresAtMs,
        'refreshIntervalSec': refreshIntervalSec,
        'nodeCount': nodeCount,
      });

  static SubscriptionSource fromJson(Map<String, Object?> json) => SubscriptionSource(
        url: asString(json['url']),
        title: asString(json['title']),
        lastFetchAtMs: asInt(json['lastFetchAtMs']),
        bytesUsed: asInt(json['bytesUsed']),
        bytesQuota: asInt(json['bytesQuota']),
        expiresAtMs: asInt(json['expiresAtMs']),
        refreshIntervalSec: asInt(json['refreshIntervalSec']),
        nodeCount: asInt(json['nodeCount']),
      );
}
