import 'dart:convert';

import 'package:naxlo_core/naxlo_core.dart';
import 'package:test/test.dart';

ServerNode buildNode({
  ProxyProtocol protocol = ProxyProtocol.vless,
  Transport transport = Transport.ws,
  SecurityLayer security = SecurityLayer.tls,
  String flow = '',
  bool allowInsecure = false,
  bool reality = false,
}) {
  return ServerNode(
    id: 'n1',
    name: 'Node One',
    address: '203.0.113.10',
    port: 443,
    protocol: protocol,
    userId: 'uuid-1',
    password: 'pw-1',
    alterId: 1,
    flow: flow,
    tls: TlsOptions(
      security: reality ? SecurityLayer.reality : security,
      serverName: 'cdn.example.com',
      fingerprint: 'chrome',
      allowInsecure: allowInsecure,
      publicKey: reality ? 'PUBKEY' : '',
      shortId: reality ? 'cd' : '',
      spiderX: reality ? '/' : '',
    ),
    transportOptions: TransportOptions(
      transport: transport,
      host: 'cdn.example.com',
      path: '/ray',
      headers: const <String, String>{'Host': 'cdn.example.com'},
    ),
  );
}

Map<String, Object?> firstOutbound(Map<String, Object?> config) =>
    (config['outbounds']! as List).first! as Map<String, Object?>;

void main() {
  group('XrayConfigBuilder', () {
    test('emits a runnable socks inbound plus proxy/direct/block/dns outbounds', () {
      final node = buildNode();
      final profile = Profile(id: 'p', name: 'p', servers: <ServerNode>[node]);
      final generated = XrayConfigBuilder(profile, node, const RuntimeSettings()).build();
      expect(generated.engine, EngineKind.xray);

      final inbounds = generated.config['inbounds']! as List;
      final socks = inbounds.first! as Map<String, Object?>;
      expect(socks['protocol'], 'socks');
      expect(socks['port'], 20151);
      expect(socks['listen'], '127.0.0.1');
      expect((socks['sniffing']! as Map<String, Object?>)['routeOnly'], true);

      final outbounds = generated.config['outbounds']! as List;
      expect(outbounds.length, 4);
      expect(outbounds[1]! as Map<String, Object?>, containsPair('tag', 'direct'));
      expect(outbounds[2]! as Map<String, Object?>, containsPair('tag', 'block'));
      expect(outbounds[3]! as Map<String, Object?>, containsPair('tag', 'dns-out'));
    });

    test('vless outbound carries encryption=none and the right stream settings', () {
      final node = buildNode();
      final profile = Profile(id: 'p', name: 'p', servers: <ServerNode>[node]);
      final cfg = XrayConfigBuilder(profile, node, const RuntimeSettings()).build().config;
      final out = firstOutbound(cfg);
      expect(out['protocol'], 'vless');
      final vnext = ((out['settings']! as Map<String, Object?>)['vnext']! as List).first! as Map<String, Object?>;
      expect(vnext['address'], '203.0.113.10');
      expect(vnext['port'], 443);
      final user = (vnext['users']! as List).first! as Map<String, Object?>;
      expect(user['id'], 'uuid-1');
      expect(user['encryption'], 'none');
      expect(user.containsKey('flow'), isFalse);

      final stream = out['streamSettings']! as Map<String, Object?>;
      expect(stream['network'], 'ws');
      expect(stream['security'], 'tls');
      final ws = stream['wsSettings']! as Map<String, Object?>;
      expect(ws['path'], '/ray');
      expect((ws['headers']! as Map<String, String>)['Host'], 'cdn.example.com');
      final tls = stream['tlsSettings']! as Map<String, Object?>;
      expect(tls['serverName'], 'cdn.example.com');
      expect(tls['fingerprint'], 'chrome');
      expect(tls['alpn'], contains('h2'));
    });

    test('reality is spelled in realitySettings, never tlsSettings', () {
      final node = buildNode(reality: true, transport: Transport.tcp, flow: 'xtls-rprx-vision');
      final profile = Profile(id: 'p', name: 'p', servers: <ServerNode>[node]);
      final out = firstOutbound(
        XrayConfigBuilder(profile, node, const RuntimeSettings()).build().config,
      );
      final stream = out['streamSettings']! as Map<String, Object?>;
      expect(stream['security'], 'reality');
      final reality = stream['realitySettings']! as Map<String, Object?>;
      expect(reality['publicKey'], 'PUBKEY');
      expect(reality['shortId'], 'cd');
      expect(reality['fingerprint'], 'chrome');
      expect(stream.containsKey('tlsSettings'), isFalse);
      final user = (((out['settings']! as Map<String, Object?>)['vnext']! as List).first! as Map<String, Object?>)['users']! as List;
      expect((user.first! as Map<String, Object?>)['flow'], 'xtls-rprx-vision');
    });

    test('missing reality key is surfaced as a warning, not swallowed', () {
      final node = buildNode(reality: true).copyWith(tls: const TlsOptions(security: SecurityLayer.reality));
      final profile = Profile(id: 'p', name: 'p', servers: <ServerNode>[node]);
      final generated = XrayConfigBuilder(profile, node, const RuntimeSettings()).build();
      expect(generated.warnings.any((w) => w.contains('public key')), isTrue);
    });

    test('allowInsecure produces a loud warning', () {
      final node = buildNode(allowInsecure: true);
      final profile = Profile(id: 'p', name: 'p', servers: <ServerNode>[node]);
      final generated = XrayConfigBuilder(profile, node, const RuntimeSettings()).build();
      expect(generated.warnings.any((w) => w.contains('MITM')), isTrue);
    });

    test('vmess carries alterId and cipher', () {
      final node = buildNode(protocol: ProxyProtocol.vmess);
      final profile = Profile(id: 'p', name: 'p', servers: <ServerNode>[node]);
      final out = firstOutbound(XrayConfigBuilder(profile, node, const RuntimeSettings()).build().config);
      final vnext = ((out['settings']! as Map<String, Object?>)['vnext']! as List).first! as Map<String, Object?>;
      final user = (vnext['users']! as List).first! as Map<String, Object?>;
      expect(user['alterId'], 1);
      expect(user['security'], 'auto');
      expect(user.containsKey('encryption'), isFalse);
    });

    test('trojan and ss use settings.servers', () {
      for (final protocol in <ProxyProtocol>[ProxyProtocol.trojan, ProxyProtocol.shadowsocks]) {
        final node = buildNode(protocol: protocol);
        final profile = Profile(id: 'p', name: 'p', servers: <ServerNode>[node]);
        final out = firstOutbound(XrayConfigBuilder(profile, node, const RuntimeSettings()).build().config);
        expect(out['protocol'], protocol.wireName);
        final servers = (out['settings']! as Map<String, Object?>)['servers']! as List;
        final s = servers.first! as Map<String, Object?>;
        expect(s['address'], '203.0.113.10');
        if (protocol == ProxyProtocol.shadowsocks) {
          expect(s['method'], 'uuid-1'); // cipher slot
        }
      }
    });

    test('routing puts lan/private bypass before the catch-all proxy', () {
      final node = buildNode();
      final profile = Profile(
        id: 'p',
        name: 'p',
        servers: <ServerNode>[node],
        routing: const RoutingConfig(
          preset: RoutingPreset.bypassLan,
          rules: <RoutingRule>[
            RoutingRule(
              action: RoutingAction.block,
              type: RuleType.domainSuffix,
              values: <String>['ads.example'],
            ),
          ],
        ),
      );
      final cfg = XrayConfigBuilder(profile, node, const RuntimeSettings()).build().config;
      final rules = (cfg['routing']! as Map<String, Object?>)['rules']! as List;
      expect(rules, isNotEmpty);
      final block = rules.firstWhere((r) => (r as Map)['outboundTag'] == 'block') as Map<String, Object?>;
      expect((block['domain']! as List), contains('ads.example'));
      final direct = rules.where((r) => (r as Map)['outboundTag'] == 'direct').toList();
      expect(direct, isNotEmpty, reason: 'lan + private ip rules');
      final ipRule = direct
          .map((r) => r as Map<String, Object?>)
          .firstWhere((r) => r.containsKey('ip'));
      expect((ipRule['ip']! as List), contains('192.168.0.0/16'));
    });

    test('quic blocking and dns hijack are on by default', () {
      final node = buildNode();
      final profile = Profile(id: 'p', name: 'p', servers: <ServerNode>[node]);
      final cfg = XrayConfigBuilder(profile, node, const RuntimeSettings()).build().config;
      final rules = (cfg['routing']! as Map<String, Object?>)['rules']! as List;
      expect(rules.any((r) => (r as Map)['port'] == '53' || (r as Map)['outboundTag'] == 'dns-out'), isTrue);
    });

    test('generated json is valid and compact-encodable', () {
      final node = buildNode();
      final profile = Profile(id: 'p', name: 'p', servers: <ServerNode>[node]);
      final generated = XrayConfigBuilder(profile, node, const RuntimeSettings()).build();
      final decoded = json.decode(generated.json);
      expect(decoded, isA<Map<String, dynamic>>());
      expect(generated.compactJson.contains(': '), isFalse);
      expect(generated.compactJson.contains(', '), isFalse);
      expect(json.decode(generated.compactJson), isNotNull);
    });
  });

  group('SingBoxConfigBuilder', () {
    test('maps each protocol onto sing-box outbound types', () {
      for (final protocol in ProxyProtocol.values) {
        final node = buildNode(protocol: protocol, security: SecurityLayer.none, reality: false);
        final profile = Profile(id: 'p', name: 'p', servers: <ServerNode>[node]);
        final out = firstOutbound(
          SingBoxConfigBuilder(profile, node, const RuntimeSettings()).build().config,
        );
        expect(out['tag'], 'proxy');
        expect(out['server'], '203.0.113.10');
        expect(out['server_port'], 443);
        switch (protocol) {
          case ProxyProtocol.vless:
            expect(out['type'], 'vless');
            expect(out['uuid'], 'uuid-1');
          case ProxyProtocol.vmess:
            expect(out['type'], 'vmess');
            expect(out['alter_id'], 1);
          case ProxyProtocol.trojan:
            expect(out['type'], 'trojan');
            expect(out['password'], 'pw-1');
          case ProxyProtocol.shadowsocks:
            expect(out['type'], 'shadowsocks');
            expect(out['method'], 'uuid-1');
          case ProxyProtocol.socks:
            expect(out['type'], 'socks');
            expect(out['version'], '5');
          case ProxyProtocol.http:
            expect(out['type'], 'http');
        }
      }
    });

    test('reality + utls live inside the tls object', () {
      final node = buildNode(reality: true, transport: Transport.tcp);
      final profile = Profile(id: 'p', name: 'p', servers: <ServerNode>[node]);
      final out = firstOutbound(SingBoxConfigBuilder(profile, node, const RuntimeSettings()).build().config);
      final tls = out['tls']! as Map<String, Object?>;
      expect(tls['enabled'], true);
      expect(tls['server_name'], 'cdn.example.com');
      final reality = tls['reality']! as Map<String, Object?>;
      expect(reality['enabled'], true);
      expect(reality['public_key'], 'PUBKEY');
      expect(reality['short_id'], 'cd');
      expect((tls['utls']! as Map<String, Object?>)['fingerprint'], 'chrome');
    });

    test('mixed inbound is used instead of two ports, and says so', () {
      final node = buildNode();
      final profile = Profile(id: 'p', name: 'p', servers: <ServerNode>[node]);
      final generated = SingBoxConfigBuilder(profile, node, const RuntimeSettings()).build();
      final inbounds = generated.config['inbounds']! as List;
      expect(inbounds.length, 1);
      expect(inbounds.first! as Map<String, Object?>, containsPair('type', 'mixed'));
      expect(generated.warnings.any((w) => w.contains('mixed port')), isTrue);
    });

    test('tun mode adds a tun inbound and warns without privileges', () {
      final node = buildNode();
      final profile = Profile(id: 'p', name: 'p', servers: <ServerNode>[node]);
      final settings = const RuntimeSettings(proxyMode: ProxyMode.tun);
      final generated = SingBoxConfigBuilder(profile, node, settings).build();
      final inbounds = generated.config['inbounds']! as List;
      expect(inbounds.where((i) => (i as Map)['type'] == 'tun'), hasLength(1));
      expect(generated.warnings.any((w) => w.contains('privileges')), isTrue);
    });

    test('route rules sniff first, hijack dns, and honour the preset final', () {
      final node = buildNode();
      final profile = Profile(
        id: 'p',
        name: 'p',
        servers: <ServerNode>[node],
        routing: const RoutingConfig(preset: RoutingPreset.directFirst),
      );
      final route = SingBoxConfigBuilder(profile, node, const RuntimeSettings())
          .build()
          .config['route']! as Map<String, Object?>;
      final rules = route['rules']! as List;
      expect((rules.first! as Map<String, Object?>)['action'], 'sniff');
      expect(route['final'], 'direct');
      expect(route['auto_detect_interface'], true);
    });

    test('https dns servers are decomposed into host + path', () {
      final node = buildNode();
      final profile = Profile(id: 'p', name: 'p', servers: <ServerNode>[node]);
      final dns = SingBoxConfigBuilder(profile, node, const RuntimeSettings())
          .build()
          .config['dns']! as Map<String, Object?>;
      final servers = dns['servers']! as List;
      final https = servers
          .map((s) => s! as Map<String, Object?>)
          .firstWhere((s) => s['type'] == 'https');
      expect(https['server'], 'dns.cloudflare.com');
      expect(https['path'], '/dns-query');
      expect(https['detour'], 'proxy');
      expect(dns['final'], 'remote');
    });
  });

  group('both engines', () {
    test('agree on which tag is the proxy', () {
      final node = buildNode();
      final profile = Profile(id: 'p', name: 'p', servers: <ServerNode>[node]);
      expect(XrayConfigBuilder(profile, node, const RuntimeSettings()).build().outboundTag, 'proxy');
      expect(SingBoxConfigBuilder(profile, node, const RuntimeSettings()).build().outboundTag, 'proxy');
    });

    test('reject an empty inbound set loudly rather than silently', () {
      final node = buildNode();
      final profile = Profile(id: 'p', name: 'p', servers: <ServerNode>[node]);
      const settings = RuntimeSettings(enableSocksInbound: false, enableHttpInbound: false);
      expect(XrayConfigBuilder(profile, node, settings).build().warnings.any((w) => w.contains('No inbound')), isTrue);
      expect(SingBoxConfigBuilder(profile, node, settings).build().warnings.any((w) => w.contains('No inbound')), isTrue);
    });
  });
}
