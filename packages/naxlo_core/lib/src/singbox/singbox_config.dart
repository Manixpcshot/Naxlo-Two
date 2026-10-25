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
import '../xray/xray_config.dart';

/// Emits sing-box JSON configs (schema v1.11-era).
///
/// sing-box is the engine we recommend when the user wants a real TUN
/// interface, and its config is stricter than Xray's: unknown keys are fatal,
/// `dns` needs explicit `route` rules, and an outbound that cannot reach its
/// resolver loops forever. That is why this builder keeps `final: "proxy"` as
/// the last resort and always emits a `dns-out` inbound route first.
class SingBoxConfigBuilder {
  const SingBoxConfigBuilder(this.profile, this.node, this.settings);

  final Profile profile;
  final ServerNode node;
  final RuntimeSettings settings;

  GeneratedConfig build() {
    final warnings = <String>[];
    final outbounds = <Map<String, Object?>>[
      _proxyOutbound(warnings),
      <String, Object?>{'type': 'direct', 'tag': 'direct'},
      <String, Object?>{'type': 'block', 'tag': 'block'},
      <String, Object?>{'type': 'dns', 'tag': 'dns-out'},
    ];

    final config = <String, Object?>{
      'log': <String, Object?>{
        'level': settings.singBoxLogLevel,
        'timestamp': true,
      },
      'dns': _dns(warnings),
      'inbounds': _inbounds(warnings),
      'outbounds': outbounds,
      'route': _routing(warnings),
    };

    return GeneratedConfig(
      engine: EngineKind.singBox,
      config: pruneNulls(config),
      warnings: warnings,
      outboundTag: 'proxy',
    );
  }

  List<Map<String, Object?>> _inbounds(List<String> warnings) {
    final out = <Map<String, Object?>>[];
    if (settings.enableSocksInbound || settings.enableHttpInbound) {
      // `mixed` serves SOCKS5 and HTTP on one port, which is friendlier than two
      // inbounds when the user hand-configures an app.
      out.add(<String, Object?>{
        'type': 'mixed',
        'tag': 'mixed-in',
        'listen': settings.listenAddress,
        'listen_port': settings.socksPort,
        'sniff': profile.dns.sniffing,
      });
      if (settings.enableHttpInbound && settings.httpPort != settings.socksPort) {
        warnings.add('sing-box serves HTTP and SOCKS on the mixed port '
            '(${settings.socksPort}); the separate HTTP port was ignored.');
      }
    }
    if (profile.routing.preset == RoutingPreset.proxyAll) {
      warnings.add('Preset "proxy all" keeps LAN traffic inside the tunnel; expect printer and '
          'Chromecast-style devices to break.');
    }
    if (settings.usesTun) {
      out.add(<String, Object?>{
        'type': 'tun',
        'tag': 'tun-in',
        'interface_name': 'naxlo${settings.tunIndex}',
        'address': <String>['172.19.0.2/30', 'fd00::2/126'],
        'auto_route': true,
        'strict_route': false,
        'stack': settings.tunStack,
        'sniff': profile.dns.sniffing,
        'mtu': settings.mtu > 0 ? settings.mtu : 9000,
      });
      if (settings.tunStack == 'system' && !settings.isPrivileged) {
        warnings.add('TUN inbound needs administrator/root privileges; the engine will exit with '
            '"operation not permitted" otherwise.');
      }
    }
    if (out.isEmpty) {
      warnings.add('No inbound enabled: the engine will run but nothing can use it.');
    }
    return out;
  }

  Map<String, Object?> _proxyOutbound(List<String> warnings) {
    final n = node;
    final out = <String, Object?>{
      'tag': 'proxy',
      'server': n.address,
      'server_port': n.port,
    };
    switch (n.protocol) {
      case ProxyProtocol.vless:
        out['type'] = 'vless';
        out['uuid'] = n.userId;
        if (n.flowIsUsable) {
          out['flow'] = n.flow;
        } else if (n.flow.isNotEmpty) {
          warnings.add('flow "${n.flow}" ignored: sing-box accepts it only on TCP with TLS/Reality.');
        }
      case ProxyProtocol.vmess:
        out['type'] = 'vmess';
        out['uuid'] = n.userId;
        out['alter_id'] = n.alterId;
        out['security'] = n.cipher.wireName == 'auto' ? 'auto' : n.cipher.wireName;
      case ProxyProtocol.trojan:
        out['type'] = 'trojan';
        out['password'] = n.password;
      case ProxyProtocol.shadowsocks:
        out['type'] = 'shadowsocks';
        out['method'] = n.userId.isEmpty ? 'aes-256-gcm' : n.userId;
        out['password'] = n.password;
        if (!isKnownShadowsocksCipher(n.userId) && n.userId.isNotEmpty) {
          warnings.add('Unknown Shadowsocks cipher "${n.userId}"; sing-box supports the AEAD and '
              '2022-blake3 families only.');
        }
      case ProxyProtocol.socks:
        out['type'] = 'socks';
        out['version'] = '5';
        if (n.userId.isNotEmpty) {
          out['username'] = n.userId;
          out['password'] = n.password;
        }
      case ProxyProtocol.http:
        out['type'] = 'http';
        if (n.userId.isNotEmpty) {
          out['username'] = n.userId;
          out['password'] = n.password;
        }
    }

    final tls = _tls(n, warnings);
    if (tls != null) out['tls'] = tls;
    final transport = _transport(n);
    if (transport != null) out['transport'] = transport;
    if (n.mux.enabled) {
      // sing-box moved multiplexing under the `multiplex` object; concurrency in
      // Xray terms has no direct equivalent, so we map it to max_connections.
      out['multiplex'] = <String, Object?>{
        'enabled': true,
        'protocol': 'h2mux',
        'max_connections': n.mux.concurrency.clamp(1, 64),
        'padding': false,
      };
    }
    if (n.protocol == ProxyProtocol.socks && n.hasTls) {
      warnings.add('SOCKS+TLS is supported by sing-box only for the `tls` security layer; Reality '
          'on SOCKS was dropped.');
      if (n.tls.security == SecurityLayer.reality) out.remove('tls');
    }
    return pruneNulls(out);
  }

  Map<String, Object?>? _tls(ServerNode n, List<String> warnings) {
    final t = n.tls;
    if (t.security == SecurityLayer.none) return null;
    final reality = t.security == SecurityLayer.reality;
    if (reality && !n.protocol.supportsReality) {
      warnings.add('Reality is a VLESS/Trojan feature; falling back to plain TLS for '
          '${n.protocol.label}.');
    }
    final out = <String, Object?>{
      'enabled': true,
      if (t.serverName.isNotEmpty) 'server_name': t.serverName,
      if (t.alpn.isNotEmpty) 'alpn': List<String>.from(t.alpn),
      'insecure': settings.allowInsecureGlobal && t.allowInsecure,
      if (t.fingerprint.isNotEmpty || reality)
        'utls': <String, Object?>{
          'enabled': true,
          'fingerprint': t.fingerprint.isEmpty ? 'chrome' : t.fingerprint,
        },
      if (reality && n.protocol.supportsReality)
        'reality': <String, Object?>{
          'enabled': true,
          'public_key': t.publicKey,
          if (t.shortId.isNotEmpty) 'short_id': t.shortId,
        },
      if (t.echQuery.isNotEmpty) 'ech_config': t.echQuery,
    };
    if (reality && t.publicKey.isEmpty) {
      warnings.add('Reality selected without a public key (pbk) — the handshake will fail.');
    }
    if (out['insecure'] == true) {
      warnings.add('Certificate verification is OFF (allowInsecure). Anyone on the path can read '
          'and modify your traffic.');
    }
    return pruneNulls(out);
  }

  Map<String, Object?>? _transport(ServerNode n) {
    final t = n.transportOptions;
    switch (t.transport) {
      case Transport.tcp:
        return null;
      case Transport.ws:
        return pruneNulls(<String, Object?>{
          'type': 'ws',
          if (t.path.isNotEmpty) 'path': t.path,
          if (t.headers.isNotEmpty || t.host.isNotEmpty)
            'headers': <String, Object?>{
              for (final e in t.headers.entries) e.key: e.value,
              if (t.host.isNotEmpty) 'Host': t.host,
            },
          if (t.maxUploadSize > 0) 'max_early_data': t.maxUploadSize,
        });
      case Transport.grpc:
        return pruneNulls(<String, Object?>{
          'type': 'grpc',
          'service_name': t.path.isEmpty ? 'rpc' : t.path.replaceFirst('/', ''),
          if (t.healthCheck) 'health_check': <String, Object?>{'enabled': true},
        });
      case Transport.httpUpgrade:
        return pruneNulls(<String, Object?>{
          'type': 'httpupgrade',
          if (t.path.isNotEmpty) 'path': t.path,
          if (t.host.isNotEmpty) 'host': t.host,
        });
      case Transport.xhttp:
        return pruneNulls(<String, Object?>{
          'type': 'xhttp',
          if (t.path.isNotEmpty) 'path': t.path,
          if (t.host.isNotEmpty) 'host': t.host,
          'mode': t.xhttpMode == 'auto' ? 'auto' : t.xhttpMode,
          if (t.xhttpExtra.isNotEmpty) 'extra': Map<String, Object?>.from(t.xhttpExtra),
        });
    }
  }

  Map<String, Object?> _dns(List<String> warnings) {
    final d = profile.dns;
    // sing-box has no `dns.servers[].type: "system"`. An empty `servers` list is how
    // you ask it to use the OS resolver; inventing a tag and pointing `final` at it
    // made `sing-box check` reject every generated config ("unknown transport type:
    // system"), which is the difference between a config and a broken tunnel.
    if (d.strategy == DnsStrategy.systemOnly) {
      return <String, Object?>{'servers': <Object?>[], 'disable_cache': false};
    }
    final servers = <Map<String, Object?>?>[];
    for (final s in d.servers) {
      servers.add(_dnsServer(s, 'remote', 'proxy', warnings));
    }
    for (final s in d.directServers) {
      servers.add(_dnsServer(s, 'local', 'direct', warnings));
    }
    final real = servers.whereType<Map<String, Object?>>().toList(growable: false);
    final tags = <String>{for (final e in real) e['tag'] as String};
    final rules = <Map<String, Object?>>[
      // A rule naming a server tag that no longer exists is a hard decode error, so
      // the routing rules follow the servers instead of assuming both groups are there.
      if (tags.contains('local'))
        <String, Object?>{
          'action': 'route',
          'server_tag': 'local',
          'protocol': <String>['dns'],
          'outbound': <String>[],
        },
    ];
    if (d.strategy == DnsStrategy.localThenTunnel && d.strategyDomain.isNotEmpty) {
      rules.insert(0, <String, Object?>{
        'action': 'route',
        'server_tag': 'local',
        'domain_suffix': <String>[for (final x in d.strategyDomain.split(',')) x.trim()].where((e) => e.isNotEmpty).toList(),
      });
    }
    if (d.leakProtect) {
      warnings.add('DNS is routed through the tunnel; local resolution is used only for bypassed names.');
    }
    final preferred = d.strategy == DnsStrategy.localThenTunnel ? 'local' : 'remote';
    return <String, Object?>{
      'servers': real,
      'rules': rules,
      if (tags.contains(preferred)) 'final': preferred,
      'mode': d.strategy == DnsStrategy.tunnelOnly ? 'black_hole' : 'rule',
      'disable_cache': false,
    };
  }

  /// `null` means "no server to emit for this entry"; the caller filters them out.
  Map<String, Object?>? _dnsServer(DnsServer s, String tag, String detour, List<String> warnings) {
    if (s.address == 'system' || s.address.startsWith('localhost')) {
      warnings.add('sing-box has no system-resolver DNS server entry; the group "$tag" was '
          'dropped and the OS resolver is used when no servers remain.');
      return null;
    }
    if (s.address.startsWith('https://')) {
      return pruneNulls(<String, Object?>{
        'tag': tag,
        'type': 'https',
        'server': s.address.replaceFirst('https://', '').split('/').first,
        'path': '/${s.address.replaceFirst('https://', '').split('/').skip(1).join('/')}',
        'detour': detour,
      });
    }
    if (s.address.startsWith('quic://')) {
      return pruneNulls(<String, Object?>{
        'tag': tag,
        'type': 'quic',
        'server': s.address.replaceFirst('quic://', '').split('/').first,
        'detour': detour,
      });
    }
    return pruneNulls(<String, Object?>{
      'tag': tag,
      'type': 'udp',
      'server': s.address,
      'server_port': s.port == 0 ? 53 : s.port,
      'detour': detour,
    });
  }

  Map<String, Object?> _routing(List<String> warnings) {
    final r = profile.routing;
    final rules = <Map<String, Object?>>[
      <String, Object?>{
        'action': 'sniff',
        'sniffers': <String>[
          'http',
          'tls',
          if (settings.sniffQuic) 'quic',
        ],
      },
      <String, Object?>{'action': 'hijack-dns', 'protocol': <String>['dns']},
    ];

    for (final rule in r.rules.where((x) => x.enabled)) {
      final mapped = _rule(rule, warnings);
      if (mapped != null) rules.add(mapped);
    }
    if (r.blockAdsDomains) {
      rules.add(<String, Object?>{
        'action': 'route',
        'outbound': 'block',
        'domain_suffix': List<String>.from(kAdDomains),
      });
    }
    if (r.bypassLan) {
      rules.add(<String, Object?>{
        'action': 'route',
        'outbound': 'direct',
        'domain_suffix': List<String>.from(kLanDomainSuffixes),
        'protocol': <String>[],
      });
    }
    if (r.blockPrivateIp) {
      rules.add(<String, Object?>{
        'action': 'route',
        'outbound': 'direct',
        'ip_cidr': <String>[...kPrivateIpv4Cidrs, ...kPrivateIpv6Cidrs],
      });
    }
    if (r.blockQuic) {
      rules.add(<String, Object?>{
        'action': 'route',
        'outbound': 'block',
        'protocol': <String>['quic'],
      });
    }
    final finalTag = r.preset == RoutingPreset.directFirst ? 'direct' : 'proxy';
    return <String, Object?>{
      'rules': rules,
      'final': finalTag,
      'auto_detect_interface': true,
      'override_android_vpn': false,
    };
  }

  Map<String, Object?>? _rule(RoutingRule rule, List<String> warnings) {
    final outbound = switch (rule.action) {
      RoutingAction.proxy => 'proxy',
      RoutingAction.direct => 'direct',
      RoutingAction.block => 'block',
    };
    final out = <String, Object?>{'action': 'route', 'outbound': outbound};
    final values = <String>[for (final v in rule.values) v.toLowerCase().trim()].where((v) => v.isNotEmpty).toList();
    if (values.isEmpty) {
      warnings.add('rule with no values dropped (${rule.type.wireName})');
      return null;
    }
    switch (rule.type) {
      case RuleType.domain:
      case RuleType.domainSuffix:
        out['domain_suffix'] = values;
      case RuleType.fullDomain:
        out['domain'] = values;
      case RuleType.domainKeyword:
        out['keyword'] = values;
      case RuleType.domainRegex:
        out['regex'] = List<String>.from(rule.values);
      case RuleType.cidr:
        out['ip_cidr'] = List<String>.from(rule.values);
      case RuleType.port:
        out['port'] = values;
      case RuleType.protocol:
        out['protocol'] = values;
    }
    return out;
  }
}
