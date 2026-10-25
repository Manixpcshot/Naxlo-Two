import 'dart:convert';

import '../config/runtime_settings.dart';
import '../geo/geo.dart';
import '../json/json_utils.dart';
import '../models/dns_config.dart';
import '../models/engine_kind.dart';
import '../models/profile.dart';
import '../models/proxy_protocol.dart';
import '../models/routing.dart';
import '../models/security.dart';
import '../models/server_node.dart';
import '../models/transport.dart';

/// Output of a config builder: the JSON to hand the engine, plus the notes the
/// UI should surface (a silently dropped `flow` is a confusing bug to debug).
class GeneratedConfig {
  const GeneratedConfig({
    required this.engine,
    required this.config,
    required this.warnings,
    required this.outboundTag,
    this.accessLogPath = '',
  });

  final EngineKind engine;
  final Map<String, Object?> config;
  final List<String> warnings;
  final String outboundTag;
  final String accessLogPath;

  String get json => const JsonEncoder.withIndent('  ').convert(config);

  /// One-line, compact form for `xray run -config` files written to disk.
  String get compactJson => encodeCompactJson(config);

  Map<String, Object?> toJson() => <String, Object?>{
        'engine': engine.cliName,
        'warnings': List<String>.from(warnings),
        'outboundTag': outboundTag,
        'config': config,
      };
}

/// Emits Xray-core JSON configs.
///
/// Shape notes, because getting these wrong is the #1 cause of "connected but
/// no traffic":
/// * A VLESS user needs `encryption: "none"`; omitting it makes xray reject the
///   outbound.
/// * `flow` is only legal with `security: tls|reality` **and** the `tcp`
///   network — that check is [ServerNode.flowIsUsable].
/// * `sniffing.routeOnly: true` is required, otherwise sniffed destinations
///   break routing for direct connections.
class XrayConfigBuilder {
  const XrayConfigBuilder(this.profile, this.node, this.settings);

  final Profile profile;
  final ServerNode node;
  final RuntimeSettings settings;

  GeneratedConfig build() {
    final warnings = <String>[];
    final inbound = _inbounds(warnings);
    final outbounds = <Map<String, Object?>>[
      _proxyOutbound(warnings),
      ..._extraOutbounds(),
    ];

    final config = <String, Object?>{
      'log': _log(),
      'inbounds': inbound,
      'outbounds': outbounds,
      'routing': _routing(warnings),
      // DNS is per-profile, not per-app: two profiles can legitimately want
      // different resolvers (one routed, one system). `systemOnly` means "do not
      // write a dns block at all", which lets the engine inherit the OS.
      if (profile.dns.strategy != DnsStrategy.systemOnly) 'dns': _dns(),
    };
    // No `policy` block on purpose. Xray's policy settings govern handshake
    // limits and link-level logging, neither of which is a per-profile choice
    // here, and `levels: 0` (don't log user/IP pairs) is already the default.
    // An earlier draft gated it on a "session resumption" toggle that Xray has no
    // knob for; a settings field that does nothing is worse than no field.
    return GeneratedConfig(
      engine: EngineKind.xray,
      config: pruneNulls(config),
      warnings: warnings,
      outboundTag: 'proxy',
      accessLogPath: settings.accessLogPath,
    );
  }

  // ── inbounds ─────────────────────────────────────────────────────────────

  List<Map<String, Object?>> _inbounds(List<String> warnings) {
    final out = <Map<String, Object?>>[];
    final sniffing = <String, Object?>{
      'enabled': profile.dns.sniffing,
      'destOverride': <String>[
        'http',
        'tls',
        if (settings.sniffQuic) 'quic',
      ],
      'metadataOnly': false,
      'routeOnly': true,
    };
    if (profile.dns.sniffing && profile.dns.leakProtect) {
      // Route port-53 traffic to the in-config DNS so apps can't bypass it.
      warnings.add('DNS is enforced through the tunnel (leak protection on).');
    }
    if (settings.enableSocksInbound) {
      out.add(<String, Object?>{
        'tag': 'socks',
        'listen': settings.listenAddress,
        'port': settings.socksPort,
        'protocol': 'socks',
        'settings': <String, Object?>{'auth': 'noauth', 'udp': true, 'ip': '127.0.0.1'},
        'sniffing': sniffing,
      });
    }
    if (settings.enableHttpInbound) {
      out.add(<String, Object?>{
        'tag': 'http',
        'listen': settings.listenAddress,
        'port': settings.httpPort,
        'protocol': 'http',
        'settings': <String, Object?>{},
        'sniffing': sniffing,
      });
    }
    if (out.isEmpty) {
      warnings.add('No inbound enabled: the engine will run but nothing can use it.');
    }
    return out;
  }

  // ── outbound ─────────────────────────────────────────────────────────────

  Map<String, Object?> _proxyOutbound(List<String> warnings) {
    final n = node;
    final settings = <String, Object?>{};
    switch (n.protocol) {
      case ProxyProtocol.vless:
        settings['vnext'] = <Object?>[
          <String, Object?>{
            'address': n.address,
            'port': n.port,
            'users': <Object?>[
              pruneNulls(<String, Object?>{
                'id': n.userId,
                'encryption': 'none',
                'level': 0,
                // Vision is meaningless (and rejected) without TCP + TLS.
                if (n.flowIsUsable) 'flow': n.flow,
              }),
            ],
          },
        ];
        if (n.flow.isNotEmpty && !n.flowIsUsable) {
          warnings.add('flow "${n.flow}" ignored: it requires VLESS over TCP with TLS or Reality.');
        }
      case ProxyProtocol.vmess:
        settings['vnext'] = <Object?>[
          <String, Object?>{
            'address': n.address,
            'port': n.port,
            'users': <Object?>[
              pruneNulls(<String, Object?>{
                'id': n.userId,
                'alterId': n.alterId,
                'security': n.cipher.wireName,
                'level': 0,
              }),
            ],
          },
        ];
      case ProxyProtocol.trojan:
        settings['servers'] = <Object?>[
          <String, Object?>{
            'address': n.address,
            'port': n.port,
            'password': n.password,
            'level': 0,
          },
        ];
      case ProxyProtocol.shadowsocks:
        settings['servers'] = <Object?>[
          <String, Object?>{
            'address': n.address,
            'port': n.port,
            'method': n.userId.isEmpty ? 'aes-256-gcm' : n.userId,
            'password': n.password,
            'level': 0,
            'ota': false,
            'udp': true,
          },
        ];
        if (!isKnownShadowsocksCipher(n.userId) && n.userId.isNotEmpty) {
          warnings.add('Unknown Shadowsocks cipher "${n.userId}"; the engine may reject it.');
        }
      case ProxyProtocol.socks:
        settings['servers'] = <Object?>[
          pruneNulls(<String, Object?>{
            'address': n.address,
            'port': n.port,
            'users': n.userId.isEmpty
                ? null
                : <Object?>[
                    <String, Object?>{'user': n.userId, 'pass': n.password},
                  ],
            'level': 0,
          }),
        ];
        settings['network'] = 'tcp,udp';
      case ProxyProtocol.http:
        settings['servers'] = <Object?>[
          pruneNulls(<String, Object?>{
            'address': n.address,
            'port': n.port,
            'users': n.userId.isEmpty
                ? null
                : <Object?>[
                    <String, Object?>{'user': n.userId, 'pass': n.password},
                  ],
          }),
        ];
    }

    final outbound = <String, Object?>{
      'tag': 'proxy',
      'protocol': n.protocol.wireName,
      'settings': settings,
      'streamSettings': _streamSettings(warnings),
    };
    if (n.mux.enabled) outbound['mux'] = n.mux.toJson();
    if (settings['vnext'] != null && n.protocol == ProxyProtocol.vmess && n.alterId > 64) {
      warnings.add('alterId ${n.alterId} is unusual; most servers use 0-16.');
    }
    return pruneNulls(outbound);
  }

  Map<String, Object?> _streamSettings(List<String> warnings) {
    final t = node.transportOptions;
    final tls = node.tls;
    final out = <String, Object?>{'network': t.transport.wireName};

    if (tls.security == SecurityLayer.reality) {
      out['security'] = 'reality';
      out['realitySettings'] = pruneNulls(<String, Object?>{
        'show': '',
        'fingerprint': tls.fingerprint.isEmpty ? 'chrome' : tls.fingerprint,
        'serverName': tls.serverName,
        'publicKey': tls.publicKey,
        'shortId': tls.shortId,
        'spiderX': tls.spiderX.isEmpty ? '/' : tls.spiderX,
      });
      if (tls.publicKey.isEmpty) {
        warnings.add('Reality selected without a public key (pbk) — the handshake will fail.');
      }
      if (tls.allowInsecure) {
        warnings.add('allowInsecure has no effect on Reality and was ignored.');
      }
    } else if (tls.security == SecurityLayer.tls) {
      out['security'] = 'tls';
      out['tlsSettings'] = pruneNulls(<String, Object?>{
        'acceptInvalidCert': false,
        'allowInsecure': tls.allowInsecure,
        'fingerprint': tls.fingerprint.isEmpty ? null : tls.fingerprint,
        'alpn': tls.alpn.isEmpty ? <String>['h2', 'http/1.1'] : tls.alpn,
        'serverName': tls.serverName,
        'certificates': <Object?>[],
        // Xray's ECH field name has moved between releases; an unknown key is
        // ignored by its JSON unmarshaller, so emitting it is a no-op at worst
        // and forward-compatible at best. The UI warns that ECH is unverified.
        if (tls.echQuery.isNotEmpty) 'echQuery': tls.echQuery,
      });
      if (tls.allowInsecure) {
        warnings.add('allowInsecure=1 disables certificate validation — MITM-able. Only for '
            'a self-signed lab server you control.');
      }
    } else {
      out['security'] = 'none';
      if (tls.serverName.isNotEmpty) {
        warnings.add('sni set without TLS; ignored by the engine.');
      }
    }

    switch (t.transport) {
      case Transport.tcp:
        out['tcpSettings'] = pruneNulls(<String, Object?>{
          'header': <String, Object?>{'type': 'none', 'request': <String, Object?>{}},
        });
      case Transport.ws:
        out['wsSettings'] = pruneNulls(<String, Object?>{
          'path': t.path.isEmpty ? '/' : t.path,
          'host': t.host,
          if (t.headers.isNotEmpty) 'headers': Map<String, String>.from(t.headers),
        });
      case Transport.grpc:
        out['grpcSettings'] = pruneNulls(<String, Object?>{
          'serviceName': t.path.isEmpty ? 'rpc' : t.path.replaceFirst('/', ''),
          'multiMode': false,
          'idle_timeout': 60,
          'health_check_timeout': 20,
          if (t.maxUploadSize > 0) 'initial_window_size': t.maxUploadSize,
          if (t.maxConnectionReuse > 0) 'max_connection_age': t.maxConnectionReuse,
        });
      case Transport.httpUpgrade:
        out['httpupgradeSettings'] = pruneNulls(<String, Object?>{
          'path': t.path,
          'host': t.host,
          if (t.headers.isNotEmpty) 'headers': Map<String, String>.from(t.headers),
        });
      case Transport.xhttp:
        out['xhttpSettings'] = pruneNulls(<String, Object?>{
          'path': t.path,
          'host': t.host,
          'mode': t.xhttpMode,
          if (t.xhttpExtra.isNotEmpty) 'extra': Map<String, Object?>.from(t.xhttpExtra),
        });
    }

    out['sockopt'] = pruneNulls(<String, Object?>{
      'tcpFastOpen': settings.tcpFastOpen,
      'tcpKeepAliveIdle': 30,
      'mark': 255,
      'domainStrategy': 'UseIP',
      if (settings.mtu > 0) 'tcpMtu': settings.mtu,
    });
    return out;
  }

  List<Map<String, Object?>> _extraOutbounds() {
    return <Map<String, Object?>>[
      <String, Object?>{
        'tag': 'direct',
        'protocol': 'freedom',
        // `redirect` is a *string* in Xray's FreedomConfig (":0" or "host:port"), so
        // an empty object placeholder made every single generated config die at
        // startup with `cannot unmarshal object into Go struct field
        // FreedomConfig.redirect of type string`. Omitting it is the same behaviour
        // as the default `":0"` (connect as resolved); the engine only accepts the
        // key with a value, and "valid until Xray parses it" is not a contract.
        'settings': <String, Object?>{'domainStrategy': 'AsIs'},
      },
      <String, Object?>{
        'tag': 'block',
        'protocol': 'blackhole',
        'settings': <String, Object?>{'response': <String, Object?>{'type': 'none'}},
      },
      <String, Object?>{
        'tag': 'dns-out',
        'protocol': 'dokodemo-door',
        'settings': <String, Object?>{
          'address': '127.0.0.1',
          'network': 'tcp,udp',
          'port': 53,
        },
      },
    ];
  }

  // ── routing / dns / log ──────────────────────────────────────────────────

  Map<String, Object?> _routing(List<String> warnings) {
    final r = profile.routing;
    final rules = <Map<String, Object?>>[];

    if (profile.dns.leakProtect && profile.dns.strategy != DnsStrategy.systemOnly) {
      rules.add(<String, Object?>{
        'type': 'field',
        'network': 'udp',
        'port': '53',
        'outboundTag': 'dns-out',
      });
    }
    for (final rule in r.rules.where((x) => x.enabled)) {
      final mapped = _rule(rule, warnings);
      if (mapped != null) rules.add(mapped);
    }
    if (r.blockAdsDomains) {
      rules.add(<String, Object?>{
        'type': 'field',
        'domain': <String>[for (final d in kAdDomains) 'full:$d', ...kAdDomains.map((d) => 'domain:$d')],
        'outboundTag': 'block',
      });
    }
    if (r.bypassLan) {
      rules.add(<String, Object?>{
        'type': 'field',
        'domain': <String>[for (final d in kLanDomainSuffixes) 'full:$d', 'keyword:.'],
        'outboundTag': 'direct',
      });
    }
    if (r.blockPrivateIp) {
      rules.add(<String, Object?>{
        'type': 'field',
        'ip': <String>[...kPrivateIpv4Cidrs, ...kPrivateIpv6Cidrs],
        'outboundTag': 'direct',
      });
    }
    if (r.preset == RoutingPreset.proxyAll) {
      warnings.add('Preset "proxy all" sends LAN and localhost traffic through the tunnel too; '
          'some apps break. Consider the "bypass LAN" preset.');
    }

    // Xray has no `final` field on routing: a catch-all rule in last position is
    // the idiom. It has to be appended to the list, not bolted onto the map — a
    // bare map literal in an `if` inside a map literal is not a map entry.
    final finalTag = r.preset == RoutingPreset.directFirst ? 'direct' : 'proxy';
    if (finalTag != 'proxy') {
      rules.add(<String, Object?>{'type': 'field', 'network': 'tcp,udp', 'outboundTag': finalTag});
    }
    return <String, Object?>{
      'domainStrategy': r.domainStrategy,
      'rules': rules,
    };
  }

  Map<String, Object?>? _rule(RoutingRule rule, List<String> warnings) {
    final outbound = switch (rule.action) {
      RoutingAction.proxy => 'proxy',
      RoutingAction.direct => 'direct',
      RoutingAction.block => 'block',
    };
    final out = <String, Object?>{
      'type': 'field',
      if (rule.inboundTag.isNotEmpty) 'inboundTag': rule.inboundTag,
      'outboundTag': outbound,
    };
    switch (rule.type) {
      case RuleType.domain:
        out['domain'] = <String>[for (final v in rule.values) 'domain:${v.toLowerCase()}'];
      case RuleType.fullDomain:
        out['domain'] = <String>[for (final v in rule.values) 'full:${v.toLowerCase()}'];
      case RuleType.domainKeyword:
        out['domain'] = <String>[for (final v in rule.values) 'keyword:${v.toLowerCase()}'];
      case RuleType.domainRegex:
        out['domain'] = <String>[for (final v in rule.values) 'regexp:$v'];
      case RuleType.domainSuffix:
        // Xray's `domain:` prefix already means "suffix match", so a bare entry
        // is the correct spelling here.
        out['domain'] = <String>[for (final v in rule.values) v.toLowerCase()];
      case RuleType.cidr:
        out['ip'] = List<String>.from(rule.values);
      case RuleType.port:
        out['port'] = rule.values.join(',');
      case RuleType.protocol:
        out['network'] = rule.values.join(',');
    }
    if (out['domain'] == null && out['ip'] == null && out['port'] == null && out['network'] == null) {
      warnings.add('rule with no matchable values was dropped (${rule.type.wireName})');
      return null;
    }
    return out;
  }

  Map<String, Object?> _dns() {
    final d = profile.dns;
    final servers = <Object?>[];
    for (final s in d.servers) {
      if (s.isHttps || s.address == 'system' || s.address.startsWith('localhost')) {
        servers.add(s.address);
        continue;
      }
      servers.add(s.address);
    }
    if (servers.isEmpty) servers.add('1.1.1.1');
    return <String, Object?>{
      'tag': 'naxlo-dns',
      'servers': servers,
      if (d.strategy == DnsStrategy.localThenTunnel || d.strategy == DnsStrategy.tunnelFirst)
        'queryStrategy': 'UseIP',
    };
  }

  Map<String, Object?> _log() => pruneNulls(<String, Object?>{
        'loglevel': settings.xrayLogLevel,
        'access': settings.accessLogPath,
        'error': settings.errorLogPath,
      });
}
