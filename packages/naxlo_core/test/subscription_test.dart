import 'dart:convert';

import 'package:naxlo_core/naxlo_core.dart';
import 'package:test/test.dart';

void main() {
  group('SubscriptionParser', () {
    test('decodes a base64 link list and counts nodes', () {
      final body = <String>[
        'vless://u1@1.1.1.1:443#NL',
        'trojan://pw@2.2.2.2:8443#DE',
        'ss://${base64Url.encode(utf8.encode('aes-256-gcm:secret')).replaceAll('=', '')}@3.3.3.3:8388#SE',
      ].join('\n');
      final encoded = base64.encode(utf8.encode(body));
      final result = SubscriptionParser.decode(encoded);
      expect(result.count, 3);
      expect(result.nodes.first.name, 'NL');
      expect(result.nodes[1].protocol, ProxyProtocol.trojan);
      expect(result.nodes[2].userId, 'aes-256-gcm');
      expect(result.errors, isEmpty);
    });

    test('accepts a plain text link list too', () {
      final result = SubscriptionParser.decode('vmess://${base64.encode(utf8.encode('{"add":"1.2.3.4","port":"443","id":"x"}'))}\n');
      expect(result.count, 1);
      expect(result.nodes.first.address, '1.2.3.4');
    });

    test('reads quota and expiry headers', () {
      final result = SubscriptionParser.decode(
        'vless://u@1.1.1.1:443#a',
        headers: <String, String>{
          'subscription-userinfo': 'upload=1073741824; download=2147483648; total=10737418240; expire=1893456000',
          'profile-title': 'base64:TGVhcm5pbmcgUHJv',
          'profile-update-interval': '24',
        },
      );
      final info = result.updateInfo!;
      expect(info.usedBytes, 3221225472);
      expect(info.total, 10737418240);
      expect(info.ratio, closeTo(0.3, 0.0001));
      expect(info.hasExpiry, isTrue);
      expect(result.title, isNotEmpty);
    });

    test('survives a garbage body with a report, not an exception', () {
      final result = SubscriptionParser.decode('this is not a subscription');
      expect(result.isEmpty, isTrue);
      expect(result.errors, isNotEmpty);
    });

    test('flags a clash-only payload instead of importing nothing silently', () {
      const clash = '''
proxies:
  - name: a
    type: vless
    server: 1.1.1.1
''';
      final result = SubscriptionParser.decode(clash);
      expect(result.looksLikeClash, isTrue);
    });

    test('imports a single xray JSON config', () {
      final jsonish = json.encode(<String, Object?>{
        'outbounds': <Object?>[
          <String, Object?>{
            'tag': 'my-node',
            'protocol': 'vless',
            'settings': <String, Object?>{
              'vnext': <Object?>[
                <String, Object?>{'address': '9.9.9.9', 'port': 443, 'users': <Object?>[{'id': 'abc'}]},
              ],
            },
            'streamSettings': <String, Object?>{'network': 'ws', 'security': 'tls', 'wsSettings': <String, Object?>{'path': '/x'}},
          },
        ],
      });
      final result = SubscriptionParser.decode(jsonish);
      expect(result.count, 1);
      expect(result.nodes.first.address, '9.9.9.9');
      expect(result.nodes.first.name, 'my-node');
      expect(result.nodes.first.transportOptions.path, '/x');
    });
  });

  group('SubscriptionMerger', () {
    test('keeps ids and history for nodes the provider renamed', () {
      final existing = <ServerNode>[
        ServerNode(id: 'keep1', name: 'Old Name', address: '1.1.1.1', port: 443, protocol: ProxyProtocol.vless, userId: 'u', weight: 50),
        ServerNode(id: 'gone1', name: 'Vanished', address: '2.2.2.2', port: 443, protocol: ProxyProtocol.vless, userId: 'u'),
      ];
      final incoming = <ServerNode>[
        ServerNode(id: 'fresh', name: 'New Name', address: '1.1.1.1', port: 443, protocol: ProxyProtocol.vless, userId: 'u'),
      ];
      final report = SubscriptionMerger.merge(existing: existing, incoming: incoming);
      expect(report.servers, hasLength(1));
      expect(report.servers.first.id, 'keep1', reason: 'identity survives a rename');
      expect(report.servers.first.name, 'New Name');
      expect(report.servers.first.weight, 50, reason: 'user tuning survives');
      expect(report.removed, contains('Vanished'));
      expect(report.retainedHistoryIds, contains('keep1'));
      expect(report.summary, contains('1 nodes'));
    });

    test('a provider relisting the same node does not reset anything', () {
      final existing = <ServerNode>[
        ServerNode(id: 'a', name: 'A', address: '1.1.1.1', port: 443, protocol: ProxyProtocol.vless, userId: 'u'),
      ];
      final report = SubscriptionMerger.merge(existing: existing, incoming: existing);
      expect(report.added, isEmpty);
      expect(report.removed, isEmpty);
      expect(report.netChange, 0);
    });
  });

  group('SubscriptionSource', () {
    test('honours the provider refresh interval', () {
      const src = SubscriptionSource(url: 'https://x/y', lastFetchAtMs: 1000, refreshIntervalSec: 60);
      expect(src.isTooEarly(30000), isTrue);
      expect(src.isTooEarly(61000), isFalse);
      expect(const SubscriptionSource(url: 'u').isTooEarly(999999), isFalse);
    });

    test('json round trip', () {
      const src = SubscriptionSource(url: 'https://s', title: 't', bytesUsed: 10, bytesQuota: 100, expiresAtMs: 5, nodeCount: 3);
      final back = SubscriptionSource.fromJson(src.toJson());
      expect(back.url, src.url);
      expect(back.usageRatio, closeTo(0.1, 0.0001));
      expect(back.hasQuota, isTrue);
      expect(back.nodeCount, 3);
    });
  });
}
