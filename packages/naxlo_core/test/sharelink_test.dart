import 'dart:convert';

import 'package:naxlo_core/naxlo_core.dart';
import 'package:test/test.dart';

void main() {
  group('VLESS', () {
    test('parses Reality, flow and TCP', () {
      const link = 'vless://11111111-2222-3333-4444-555555555555@185.1.2.3:443'
          '?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome'
          '&pbk=abcPUBLICkey&sid=6ba85179&spx=%2F&flow=xtls-rprx-vision&type=tcp#Tehran-1';
      final n = ShareLinkParser.tryParse(link)!;
      expect(n.protocol, ProxyProtocol.vless);
      expect(n.userId, '11111111-2222-3333-4444-555555555555');
      expect(n.address, '185.1.2.3');
      expect(n.port, 443);
      expect(n.name, 'Tehran-1');
      expect(n.tls.security, SecurityLayer.reality);
      expect(n.tls.publicKey, 'abcPUBLICkey');
      expect(n.tls.shortId, '6ba85179');
      expect(n.tls.spiderX, '/');
      expect(n.tls.serverName, 'www.microsoft.com');
      expect(n.flow, 'xtls-rprx-vision');
      expect(n.flowIsUsable, isTrue, reason: 'Reality + TCP');
      expect(n.isPlaintext, isFalse);
    });

    test('drops an unusable flow with a warning at config time', () {
      const link = 'vless://u@h:443?security=tls&flow=xtls-rprx-vision&type=ws#ws-node';
      final n = ShareLinkParser.tryParse(link)!;
      expect(n.flowIsUsable, isFalse, reason: 'Vision over WebSocket is invalid');
      final profile = Profile(id: 'p', name: 'p', servers: <ServerNode>[n]);
      final cfg = XrayConfigBuilder(
        profile,
        n,
        const RuntimeSettings(),
      ).build();
      expect(cfg.warnings.any((w) => w.contains('flow')), isTrue);
      final outbound = (cfg.config['outbounds'] as List).first as Map<String, Object?>;
      final settings = outbound['settings']! as Map<String, Object?>;
      final vnext = settings['vnext']! as List;
      final user = (vnext.first! as Map<String, Object?>)['users']! as List;
      expect((user.first! as Map<String, Object?>).containsKey('flow'), isFalse);
    });

    test('parses WebSocket with Host and decoded path', () {
      const link = 'vless://u@1.2.3.4:8443?security=tls&sni=a.com&type=ws&host=cdn.example.com'
          '&path=%2F%3Fed%3D2560&alpn=h3,http/1.1#edge';
      final n = ShareLinkParser.tryParse(link)!;
      expect(n.transportOptions.transport, Transport.ws);
      expect(n.transportOptions.host, 'cdn.example.com');
      expect(n.transportOptions.path, '/?ed=2560');
      expect(n.transportOptions.headers['Host'], 'cdn.example.com');
      expect(n.tls.alpn, <String>['h3', 'http/1.1']);
    });

    test('round-trips through the writer', () {
      const link = 'vless://uuid-1@203.0.113.9:2053?encryption=none&security=reality'
          '&sni=kernel.org&fp=firefox&pbk=KEY&sid=ab&spx=%2F&type=tcp#Finland';
      final parsed = ShareLinkParser.tryParse(link)!;
      final written = ShareLinkWriter.forNode(parsed);
      final again = ShareLinkParser.tryParse(written)!;
      expect(again.address, parsed.address);
      expect(again.port, parsed.port);
      expect(again.userId, parsed.userId);
      expect(again.flow, parsed.flow);
      expect(again.tls.publicKey, parsed.tls.publicKey);
      expect(again.name, 'Finland');
      expect(again.fingerprint, parsed.fingerprint);
    });

    test('handles bracketed IPv6 with a port', () {
      const link = 'vless://u@[2001:db8::1]:443?security=tls#v6';
      final n = ShareLinkParser.tryParse(link)!;
      expect(n.address, '2001:db8::1');
      expect(n.port, 443);
      expect(n.netAddr.toString(), '[2001:db8::1]:443');
    });
  });

  group('VMess', () {
    test('parses the base64 JSON form', () {
      final payload = base64.encode(utf8.encode(json.encode(<String, Object?>{
        'v': '2',
        'ps': 'Berlin 1',
        'add': '162.55.1.1',
        'port': '443',
        'id': 'bbbbbbbb-cccc-dddd-eeee-ffffffffffff',
        'aid': 0,
        'scy': 'auto',
        'net': 'ws',
        'host': 'a.example',
        'path': '/ws',
        'tls': 'tls',
      })));
      final n = ShareLinkParser.tryParse('vmess://$payload')!;
      expect(n.protocol, ProxyProtocol.vmess);
      expect(n.name, 'Berlin 1');
      expect(n.port, 443);
      expect(n.alterId, 0);
      expect(n.cipher, VmessCipher.auto);
      expect(n.transportOptions.transport, Transport.ws);
      expect(n.tls.security, SecurityLayer.tls);
      expect(n.transportOptions.headers['Host'], 'a.example');
    });

    test('accepts URL-safe base64 without padding', () {
      final jsonish = '{"v":"2","ps":"x?y","add":"1.1.1.1","port":8080,"id":"u","aid":64,"net":"tcp"}';
      final body = base64Url.encode(utf8.encode(jsonish)).replaceAll('=', '');
      final n = ShareLinkParser.tryParse('vmess://$body')!;
      expect(n.name, 'x?y');
      expect(n.port, 8080);
      expect(n.alterId, 64);
    });

    test('rejects garbage rather than half-importing it', () {
      expect(ShareLinkParser.tryParse('vmess://not-base64!!'), isNull);
      expect(ShareLinkParser.tryParse('vless://@:0'), isNull);
      expect(ShareLinkParser.tryParse('https://example.com'), isNull);
    });
  });

  group('Trojan / SS / SOCKS / HTTP', () {
    test('Trojan keeps an @ inside the password', () {
      const link = 'trojan://p@ss:w0rd@198.51.100.7:443?sni=t.example&type=ws&path=%2Ft#T';
      final n = ShareLinkParser.tryParse(link)!;
      expect(n.password, 'p@ss:w0rd');
      expect(n.address, '198.51.100.7');
      expect(n.port, 443);
      expect(n.transportOptions.path, '/t');
      expect(n.tls.security, SecurityLayer.tls, reason: 'sni implies tls');
    });

    test('SS SIP002 decodes cipher and password', () {
      final creds = base64Url.encode(utf8.encode('aes-256-gcm:s3cr3t!')).replaceAll('=', '');
      final n = ShareLinkParser.tryParse('ss://$creds@192.0.2.5:8443#Sweden')!;
      expect(n.protocol, ProxyProtocol.shadowsocks);
      expect(n.userId, 'aes-256-gcm');
      expect(n.password, 's3cr3t!');
      expect(n.address, '192.0.2.5');
      expect(n.name, 'Sweden');
      expect(isKnownShadowsocksCipher(n.userId), isTrue);
    });

    test('SS legacy form and the 2022 ciphers', () {
      final legacy = base64.encode(utf8.encode('chacha20-ietf-poly1305:pw@203.0.113.9:443'));
      final n = ShareLinkParser.tryParse('ss://$legacy#legacy')!;
      expect(n.address, '203.0.113.9');
      expect(n.port, 443);
      expect(n.password, 'pw');
      expect(n.userId, 'chacha20-ietf-poly1305');

      final creds = base64Url.encode(utf8.encode('2022-blake3-aes-128-gcm:Y8f')).replaceAll('=', '');
      final modern = ShareLinkParser.tryParse('ss://$creds@h:1');
      expect(modern, isNotNull);
      expect(modern!.userId, '2022-blake3-aes-128-gcm');
      expect(isKnownShadowsocksCipher(modern.userId), isTrue);
    });

    test('SS plugin turns into a WebSocket transport', () {
      final creds = base64Url.encode(utf8.encode('aes-128-gcm:pw')).replaceAll('=', '');
      final n = ShareLinkParser.tryParse(
        'ss://$creds@1.2.3.4:8388?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dcdn%23node',
      )!;
      expect(n.transportOptions.transport, Transport.ws);
      expect(n.transportOptions.host, 'cdn');
    });

    test('SOCKS with credentials', () {
      final n = ShareLinkParser.tryParse('socks5://bob:pw123@127.0.0.1:1080#local')!;
      expect(n.protocol, ProxyProtocol.socks);
      expect(n.userId, 'bob');
      expect(n.password, 'pw123');
      expect(n.port, 1080);
      expect(ShareLinkWriter.forNode(n), startsWith('socks://bob:pw123@127.0.0.1:1080'));
    });

    test('HTTP proxy', () {
      final n = ShareLinkParser.tryParse('http://u:p@example.org:3128')!;
      expect(n.protocol, ProxyProtocol.http);
      expect(n.address, 'example.org');
      expect(n.port, 3128);
    });
  });

  group('bulk import', () {
    test('counts successes and reports per-line failures', () {
      final blob = <String>[
        'vless://u@1.1.1.1:443#one',
        '',
        '# a comment',
        'trojan://pw@2.2.2.2:443#two',
        'totally-not-a-link',
      ].join('\n');
      final result = ShareLinkParser.parseMany(blob);
      expect(result.count, 2);
      expect(result.errors.length, 1);
      expect(result.errors.first, contains('line 5'));
    });

    test('deduplicates identical endpoints from a provider', () {
      final a = ShareLinkParser.tryParse('vless://u@1.1.1.1:443#TL1')!;
      final b = ShareLinkParser.tryParse('vless://u@1.1.1.1:443#TL2')!;
      expect(a.fingerprint, b.fingerprint, reason: 'same endpoint, different remark');
      final deduped = SubscriptionParser.dedupeNodes(<ServerNode>[a, b]);
      expect(deduped.length, 1);
      expect(deduped.first.name, 'TL1');
    });
  });
}
