import '../json/json_utils.dart';
import 'dns_config.dart';
import 'engine_kind.dart';
import 'routing.dart';
import 'server_node.dart';

/// A named collection of nodes with its own routing/DNS/engine choices — the
/// thing a user thinks of as "a config". Mirrors Happ's profile concept.
class Profile {
  Profile({
    required this.id,
    required this.name,
    this.servers = const <ServerNode>[],
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
