import 'package:flutter_test/flutter_test.dart';
import 'package:naxlo_two/state/system_proxy.dart';

/// The system-proxy plan is pure and platform-specific, which makes it exactly
/// the kind of code that is invisible until a user's browser stops working.
/// These assert shape (right tool, right keys, restore path), not registry
/// semantics.
void main() {
  const plan = SystemProxyPlan();

  group('enable', () {
    test('windows sets WinINET ProxyEnable + ProxyServer and winhttp', () {
      final cmds = plan.enable(
        platform: PlatformIdentifier.windows,
        host: '127.0.0.1',
        port: 10808,
      );
      final reg = cmds.where((ProxyCommand c) => c.executable == 'reg').toList();
      expect(reg, hasLength(2), reason: 'ProxyEnable and ProxyServer');
      expect(reg.first.args, containsAll(<String>['/v', 'ProxyEnable']));
      expect(reg[1].args, containsAll(<String>['/v', 'ProxyServer']));
      expect(reg[1].args.join(' '), contains('127.0.0.1:10808'));
      expect(cmds.any((ProxyCommand c) => c.executable == 'netsh' && c.args.contains('winhttp')), isTrue);
      expect(
        cmds.firstWhere((ProxyCommand c) => c.executable == 'netsh').requiresAdmin,
        isTrue,
        reason: 'winhttp reset needs elevation, the UI must say so',
      );
    });

    test('windows bypass list reaches ProxyOverride', () {
      final cmds = plan.enable(
        platform: PlatformIdentifier.windows,
        host: '127.0.0.1',
        port: 1080,
        bypass: const <String>['localhost', '10.0.0.0/8'],
      );
      final override = cmds.firstWhere(
        (ProxyCommand c) => c.args.contains('ProxyOverride'),
      );
      expect(override.args.join(' '), contains('localhost;10.0.0.0/8'));
    });

    test('macos targets both http and https on the named service', () {
      final cmds = plan.enable(
        platform: PlatformIdentifier.macos,
        host: '127.0.0.1',
        port: 1080,
        service: 'USB LAN',
      );
      final args = cmds.map((ProxyCommand c) => c.args.join(' ')).join('\n');
      expect(args, contains('-setwebproxy USB LAN'));
      expect(args, contains('-setsecurewebproxy USB LAN'));
      expect(cmds.every((ProxyCommand c) => c.executable == 'networksetup'), isTrue);
      expect(args, contains('1080'));
    });

    test('macos can be told not to touch https', () {
      final cmds = plan.enable(
        platform: PlatformIdentifier.macos,
        host: '127.0.0.1',
        port: 1080,
        proxyHttps: false,
      );
      expect(cmds.any((ProxyCommand c) => c.args.contains('-setsecurewebproxy')), isFalse);
    });

    test('gnome uses gsettings with the listen address we actually bound', () {
      final cmds = plan.enable(
        platform: PlatformIdentifier.linux,
        host: '127.0.0.53',
        port: 11080,
      );
      expect(cmds.every((ProxyCommand c) => c.executable == 'gsettings'), isTrue);
      final joined = cmds.map((ProxyCommand c) => c.args.join(' ')).join('\n');
      expect(joined, contains('org.gnome.system.proxy mode'));
      expect(joined, contains("'127.0.0.53'"));
      expect(joined, contains('11080'));
    });

    test('mobile platforms get no commands instead of a half-truth', () {
      for (final p in <PlatformIdentifier>[PlatformIdentifier.android, PlatformIdentifier.ios]) {
        expect(plan.enable(platform: p, host: '127.0.0.1', port: 1080), isEmpty, reason: '$p');
      }
    });
  });

  group('disable', () {
    test('windows turns the flag off and resets winhttp', () {
      final cmds = plan.disable(platform: PlatformIdentifier.windows);
      final reg = cmds.firstWhere((ProxyCommand c) => c.executable == 'reg');
      expect(reg.args.join(' '), contains('ProxyEnable'));
      // The value follows `/d`; `/f` is the last argument (that is how reg.exe
      // wants it), so asserting on `args.last` tested the force flag, not the off.
      final at = reg.args.indexOf('/d');
      expect(at, greaterThanOrEqualTo(0), reason: 'reg add must pass the value after /d');
      expect(reg.args[at + 1], '0', reason: 'must be the "off" value, not "1"');
      expect(cmds.any((ProxyCommand c) => c.args.contains('reset')), isTrue);
    });

    test('macos switches both states off for the given service', () {
      final cmds = plan.disable(platform: PlatformIdentifier.macos, service: 'Wi-Fi');
      final joined = cmds.map((ProxyCommand c) => c.args.join(' ')).join('\n');
      expect(joined, contains('-setwebproxystate Wi-Fi off'));
      expect(joined, contains('-setsecurewebproxystate Wi-Fi off'));
    });

    test('gnome sets mode none', () {
      final cmds = plan.disable(platform: PlatformIdentifier.linux);
      expect(cmds.single.args.join(' '), contains("mode 'none'"));
    });

    test('mobile stays a no-op so restore cannot fail on a phone', () {
      expect(plan.disable(platform: PlatformIdentifier.android), isEmpty);
      expect(plan.disable(platform: PlatformIdentifier.ios), isEmpty);
    });
  });

  test('display strings are copy-pasteable for bug reports', () {
    final cmd = plan.enable(platform: PlatformIdentifier.linux, host: '127.0.0.1', port: 1080).first;
    expect(cmd.display, startsWith('gsettings set'));
    expect(cmd.toString(), cmd.display);
  });
}
