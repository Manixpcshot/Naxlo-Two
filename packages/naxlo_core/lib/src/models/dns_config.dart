import '../json/json_utils.dart';

/// DNS policy for the tunnel. `remoteOnly` (the default) is the least
/// surprising: the engine resolves remote names over the tunnel, which is what
/// prevents the DNS leaks that naive setups produce.
enum DnsStrategy {
  tunnelOnly('tunnel', 'All names through the tunnel'),
  localThenTunnel('localThenTunnel', 'Local first, fallback to tunnel'),
  tunnelFirst('tunnelFirst', 'Tunnel first, fallback to system'),
  systemOnly('system', 'Never touch DNS (system resolver)');

  const DnsStrategy(this.wireName, this.label);
  final String wireName;
  final String label;

  static DnsStrategy fromName(String? raw) {
    final s = asString(raw).trim();
    for (final e in DnsStrategy.values) {
      if (e.wireName == s) return e;
    }
    return DnsStrategy.tunnelOnly;
  }
}

class DnsServer {
  const DnsServer(this.address, {this.port = 53, this.domains = const <String>[], this.skipFallback = false});

  /// `1.1.1.1`, `https://dns.cloudflare.com/dns-query`, `https://…#serverName=…`
  final String address;
  final int port;

  /// Domain matcher list that routes names to this server (Xray `domains`).
  final List<String> domains;

  /// Xray: don't use fallback servers when this one answered.
  final bool skipFallback;

  bool get isHttps => address.startsWith('https://') || address.startsWith('quic://');

  Map<String, Object?> toJson() => pruneNulls(<String, Object?>{
        'address': address,
        if (port != 53) 'port': port,
        if (domains.isNotEmpty) 'domains': List<String>.from(domains),
        if (skipFallback) 'skipFallback': true,
      });

  static DnsServer fromJson(Map<String, Object?> json) => DnsServer(
        asString(json['address']),
        port: asInt(json['port'], fallback: 53),
        domains: asStringList(json['domains']),
        skipFallback: asBool(json['skipFallback']),
      );
}

/// How the client resolves names — translated by each config builder.
class DnsConfig {
  const DnsConfig({
    this.strategy = DnsStrategy.tunnelOnly,
    this.servers = const <DnsServer>[
      DnsServer('1.1.1.1'),
      DnsServer('https://dns.cloudflare.com/dns-query'),
    ],
    this.directServers = const <DnsServer>[DnsServer('system')],
    this.disableFallbackIfCanUseLocalDns = false,
    this.strategyDomain = '',
    this.tunMtu = 1500,
    this.sniffing = true,
    this.leakProtect = true,
  });

  const DnsConfig.defaults()
      : strategy = DnsStrategy.tunnelOnly,
        servers = <DnsServer>[DnsServer('1.1.1.1'), DnsServer('https://dns.cloudflare.com/dns-query')],
        directServers = <DnsServer>[DnsServer('system')],
        disableFallbackIfCanUseLocalDns = false,
        strategyDomain = '',
        tunMtu = 1500,
        sniffing = true,
        leakProtect = true;

  final DnsStrategy strategy;

  /// Remote (tunnelled) resolvers.
  final List<DnsServer> servers;

  /// Resolvers used for direct/bypassed names.
  final List<DnsServer> directServers;

  /// When true, prefer the OS resolver if it works, else use [servers].
  final bool disableFallbackIfCanUseLocalDns;

  /// Optional comma-separated domain list routed to [directServers].
  final String strategyDomain;
  final int tunMtu;

  /// SNI/HTTP sniffing to make routing decisions on real hostnames.
  final bool sniffing;

  /// Force UDP/53 into the tunnel instead of letting apps pick LAN routers.
  final bool leakProtect;

  DnsConfig copyWith({
    DnsStrategy? strategy,
    List<DnsServer>? servers,
    List<DnsServer>? directServers,
    bool? sniffing,
    bool? leakProtect,
    int? tunMtu,
  }) {
    return DnsConfig(
      strategy: strategy ?? this.strategy,
      servers: servers ?? this.servers,
      directServers: directServers ?? this.directServers,
      disableFallbackIfCanUseLocalDns: disableFallbackIfCanUseLocalDns,
      strategyDomain: strategyDomain,
      tunMtu: tunMtu ?? this.tunMtu,
      sniffing: sniffing ?? this.sniffing,
      leakProtect: leakProtect ?? this.leakProtect,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'strategy': strategy.wireName,
        'servers': <Object?>[for (final s in servers) s.toJson()],
        'directServers': <Object?>[for (final s in directServers) s.toJson()],
        'sniffing': sniffing,
        'leakProtect': leakProtect,
        'tunMtu': tunMtu,
      };

  static DnsConfig fromJson(Map<String, Object?> json) {
    if (json.isEmpty) return const DnsConfig.defaults();
    return DnsConfig(
      strategy: DnsStrategy.fromName(asString(json['strategy'])),
      servers: <DnsServer>[
        for (final raw in asList(json['servers'])) DnsServer.fromJson(asMap(raw)),
      ].isEmpty
          ? const <DnsServer>[DnsServer('1.1.1.1')]
          : <DnsServer>[
              for (final raw in asList(json['servers'])) DnsServer.fromJson(asMap(raw)),
            ],
      directServers: <DnsServer>[
        for (final raw in asList(json['directServers'])) DnsServer.fromJson(asMap(raw)),
      ],
      disableFallbackIfCanUseLocalDns: asBool(json['disableFallbackIfCanUseLocalDns']),
      strategyDomain: asString(json['strategyDomain']),
      tunMtu: asInt(json['tunMtu'], fallback: 1500),
      sniffing: asBool(json['sniffing'], fallback: true),
      leakProtect: asBool(json['leakProtect'], fallback: true),
    );
  }
}
