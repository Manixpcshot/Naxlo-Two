import 'package:naxlo_core/naxlo_core.dart';
import 'package:test/test.dart';

void main() {
  group('CIDR matching', () {
    test('ipv4 containment', () {
      expect(ipv4InCidr('10.1.2.3', '10.0.0.0/8'), isTrue);
      expect(ipv4InCidr('11.1.2.3', '10.0.0.0/8'), isFalse);
      expect(ipv4InCidr('192.168.7.9', '192.168.0.0/16'), isTrue);
      expect(ipv4InCidr('100.64.1.1', '100.64.0.0/10'), isTrue, reason: 'CGNAT');
      expect(ipv4InCidr('100.128.0.1', '100.64.0.0/10'), isFalse);
      expect(ipv4InCidr('1.2.3.4', '0.0.0.0/0'), isTrue);
      expect(ipv4InCidr('not-an-ip', '10.0.0.0/8'), isFalse);
    });

    test('ipv6 prefix containment', () {
      expect(ipv6MatchesPrefix('fe80::1', 'fe80::/10'), isTrue);
      expect(ipv6MatchesPrefix('2001:db8::1', 'fe80::/10'), isFalse);
      expect(ipv6MatchesPrefix('fd12::5', 'fc00::/7'), isTrue);
      expect(ipv6MatchesPrefix('::1', '::1/128'), isTrue);
      expect(ipv6MatchesPrefix('::2', '::1/128'), isFalse);
    });

    test('private address detection mixes both families', () {
      expect(isPrivateAddress('127.0.0.1'), isTrue);
      expect(isPrivateAddress('172.16.5.5'), isTrue);
      expect(isPrivateAddress('172.32.5.5'), isFalse);
      expect(isPrivateAddress('8.8.8.8'), isFalse);
      expect(isPrivateAddress('::1'), isTrue);
      expect(isPrivateAddress('2606:4700:4700::1111'), isFalse);
    });

    test('cidr lists skip the wrong address family instead of mis-matching', () {
      expect(cidrMatchesAny(<String>['10.0.0.0/8'], '10.0.0.1'), isTrue);
      expect(cidrMatchesAny(<String>['fe80::/10'], '10.0.0.1'), isFalse);
      expect(cidrMatchesAny(<String>['1.2.3.4'], '1.2.3.4'), isTrue, reason: 'bare address');
    });
  });

  group('RoutingConfig decisions', () {
    const routing = RoutingConfig(preset: RoutingPreset.bypassLan, bypassLan: true, blockPrivateIp: true);

    test('lan names and private ips go direct', () {
      expect(routing.matchHost('printer.local'), RoutingAction.direct);
      expect(routing.matchHost('example.com'), RoutingAction.proxy);
      expect(routing.matchIp('192.168.1.10'), RoutingAction.direct);
      expect(routing.matchIp('93.184.216.34'), RoutingAction.proxy);
    });

    test('user rules beat the preset', () {
      final r = routing.copyWith(rules: const <RoutingRule>[
        RoutingRule(action: RoutingAction.block, type: RuleType.domainSuffix, values: <String>['ads.example']),
      ]);
      expect(r.matchHost('x.ads.example'), RoutingAction.block);
      expect(r.matchHost('ads.notexample'), RoutingAction.proxy);
    });

    test('directFirst inverts the default', () {
      const r = RoutingConfig(preset: RoutingPreset.directFirst);
      expect(r.matchHost('anything.com'), RoutingAction.direct);
    });

    test('ads preset blocks trackers when enabled', () {
      const r = RoutingConfig(preset: RoutingPreset.blockAds, blockAdsDomains: true);
      expect(r.matchHost('doubleclick.net'), RoutingAction.block);
    });

    test('keyword and regex matchers work', () {
      final r = const RoutingConfig(rules: <RoutingRule>[
        RoutingRule(action: RoutingAction.direct, type: RuleType.domainKeyword, values: <String>['internal']),
        RoutingRule(action: RoutingAction.block, type: RuleType.domainRegex, values: <String>[r'^tmp[0-9]+\.example$']),
      ]);
      expect(r.matchHost('my-internal.corp'), RoutingAction.direct);
      expect(r.matchHost('tmp123.example'), RoutingAction.block);
    });
  });

  group('NetAddr', () {
    test('parses the shapes the engines accept', () {
      expect(NetAddr.tryParse('1.2.3.4:443')!.port, 443);
      expect(NetAddr.tryParse('[::1]:80').toString(), '[::1]:80');
      expect(NetAddr.tryParse('example.com')!.port, 0);
      expect(NetAddr.tryParse('example.com.', defaultPort: 443).toString(), 'example.com:443');
      expect(NetAddr.tryParse('1.2.3.4:99999'), isNull);
      expect(NetAddr.tryParse(''), isNull);
    });
  });

  group('json helpers', () {
    test('pruneNulls drops empties but keeps false and zero', () {
      final pruned = pruneNulls(<String, Object?>{'a': null, 'b': '', 'c': <String>[], 'd': false, 'e': 0, 'f': <String, Object?>{}});
      expect(pruned.keys.toList(), <String>['d', 'e']);
    });

    test('asX coercion survives config typos', () {
      expect(asInt('70'), 70);
      expect(asInt(70.9), 70);
      expect(asInt(null, fallback: 5), 5);
      expect(asBool('yes'), isTrue);
      expect(asBool(0), isFalse);
      expect(asDouble('1.5'), 1.5);
      expect(asString(3), '3');
    });
  });
}
