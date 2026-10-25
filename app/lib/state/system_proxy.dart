import 'dart:io';

import 'package:naxlo_core/naxlo_core.dart';

/// One command the platform needs to point at our local inbound.
class ProxyCommand {
  const ProxyCommand({required this.executable, required this.args, this.requiresAdmin = false, this.note = ''});

  final String executable;
  final List<String> args;
  final bool requiresAdmin;
  final String note;

  String get display => '$executable ${args.join(' ')}';

  @override
  String toString() => display;
}

/// Turns the desired state into the commands each OS actually understands.
///
/// Split out from execution so it is unit-testable on any machine — a wrong
/// `netsh` argument is not a crash, it is a user whose traffic silently leaks,
/// which is the worst possible failure mode for this kind of app.
class SystemProxyPlan {
  const SystemProxyPlan();

  /// [service] is the macOS network service name ("Wi-Fi"), [bypass] the
  /// no-proxy list. Both are ignored on the platforms that don't have them.
  List<ProxyCommand> enable({
    required PlatformIdentifier platform,
    required String host,
    required int port,
    List<String> bypass = const <String>['localhost', '127.0.0.1'],
    String service = 'Wi-Fi',
    bool proxyHttps = true,
    bool proxyPac = false,
  }) {
    final bypassList = bypass.join(',');
    switch (platform) {
      case PlatformIdentifier.windows:
        // Two registries of "the proxy": winhttp (services, no-UI processes) and
        // WinINET (browsers, most apps). Setting only one is the usual cause of
        // "it works in Chrome and nowhere else".
        return <ProxyCommand>[
          ProxyCommand(
            executable: 'reg',
            args: <String>[
              'add',
              r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
              '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '1', '/f',
            ],
            note: 'WinINET: browsers and most user apps',
          ),
          ProxyCommand(
            executable: 'reg',
            args: <String>[
              'add',
              r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
              '/v', 'ProxyServer', '/t', 'REG_SZ', '/d', '$host:$port', '/f',
            ],
          ),
          ProxyCommand(
            executable: 'reg',
            args: <String>[
              'add',
              r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
              '/v', 'ProxyOverride', '/t', 'REG_SZ', '/d', bypassList, '/f',
            ],
          ),
          ProxyCommand(
            executable: 'netsh',
            args: <String>['winhttp', 'set', 'proxy', '($host=$port)', '<-loopback'],
            requiresAdmin: true,
            note: 'winhttp needs elevation; skipped silently without it',
          ),
        ];
      case PlatformIdentifier.macos:
        final commands = <ProxyCommand>[
          ProxyCommand(
            executable: 'networksetup',
            args: <String>['-setwebproxy', service, host, '$port'],
          ),
        ];
        if (proxyHttps) {
          commands.add(ProxyCommand(
            executable: 'networksetup',
            args: <String>['-setsecurewebproxy', service, host, '$port'],
          ));
        }
        commands.add(ProxyCommand(
          executable: 'networksetup',
          args: <String>['-setproxybypassdomains', service, ...bypass],
        ));
        if (proxyPac) {
          commands.add(const ProxyCommand(
            executable: 'networksetup',
            args: <String>['-setautoproxystate', 'off'],
            note: 'a stale PAC overrides manual proxy settings',
          ));
        }
        return commands;
      case PlatformIdentifier.linux:
        // GNOME/KDE via gsettings; other desktops get the env-var note in the UI
        // because there is no cross-desktop API worth shelling out to.
        return <ProxyCommand>[
          const ProxyCommand(
            executable: 'gsettings',
            args: <String>['set', 'org.gnome.system.proxy', 'mode', "'manual'"],
          ),
          ProxyCommand(
            executable: 'gsettings',
            args: <String>['set', 'org.gnome.system.proxy.socks', 'host', "'$host'"],
          ),
          ProxyCommand(
            executable: 'gsettings',
            args: <String>['set', 'org.gnome.system.proxy.socks', 'port', '$port'],
          ),
          const ProxyCommand(
            executable: 'gsettings',
            args: <String>['set', 'org.gnome.system.proxy', 'ignore-hosts',
                "['localhost', '127.0.0.1/8', '::1']"],
          ),
        ];
      case PlatformIdentifier.android:
      case PlatformIdentifier.ios:
        // No system-proxy API for sideloaded apps on either; the VPN profile path
        // is what a mobile build would need, which is out of scope here.
        return <ProxyCommand>[];
    }
  }

  List<ProxyCommand> disable({
    required PlatformIdentifier platform,
    String service = 'Wi-Fi',
  }) {
    switch (platform) {
      case PlatformIdentifier.windows:
        return <ProxyCommand>[
          ProxyCommand(
            executable: 'reg',
            args: <String>[
              'add',
              r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
              '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '0', '/f',
            ],
          ),
          const ProxyCommand(
            executable: 'netsh',
            args: <String>['winhttp', 'reset', 'proxy'],
            requiresAdmin: true,
          ),
        ];
      case PlatformIdentifier.macos:
        return <ProxyCommand>[
          ProxyCommand(executable: 'networksetup', args: <String>['-setwebproxystate', service, 'off']),
          ProxyCommand(executable: 'networksetup', args: <String>['-setsecurewebproxystate', service, 'off']),
        ];
      case PlatformIdentifier.linux:
        return const <ProxyCommand>[
          ProxyCommand(
            executable: 'gsettings',
            args: <String>['set', 'org.gnome.system.proxy', 'mode', "'none'"],
          ),
        ];
      case PlatformIdentifier.android:
      case PlatformIdentifier.ios:
        return const <ProxyCommand>[];
    }
  }
}

/// Applies [SystemProxyPlan] and remembers whether *we* were the ones who set it.
///
/// The ownership marker matters: if a corporate policy or another tool already
/// pointed the system at a different proxy, "restore on exit" must restore that,
/// not blindly clear it. We snapshot the previous value and write it back.
class SystemProxyController {
  SystemProxyController({this.service = 'Wi-Fi'});

  final String service;
  final SystemProxyPlan _plan = const SystemProxyPlan();

  bool _managedByUs = false;
  String _previousServer = '';
  bool _wasEnabled = false;

  bool get isManagedByUs => _managedByUs;
  String get previousServer => _previousServer;

  PlatformIdentifier get _platform {
    if (Platform.isWindows) return PlatformIdentifier.windows;
    if (Platform.isMacOS) return PlatformIdentifier.macos;
    if (Platform.isLinux) return PlatformIdentifier.linux;
    if (Platform.isAndroid) return PlatformIdentifier.android;
    return PlatformIdentifier.ios;
  }

  /// Best-effort read of the current WinINET proxy so [restore] can put it back.
  Future<void> snapshot() async {
    if (_platform != PlatformIdentifier.windows) return;
    try {
      final r = await Process.run('reg', <String>[
        'query',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
      ]);
      final out = '${r.stdout}';
      _previousServer = _grab(out, 'ProxyServer') ?? '';
      _wasEnabled = (_grab(out, 'ProxyEnable') ?? '0x0') != '0x0';
    } on ProcessException {
      _previousServer = '';
      _wasEnabled = false;
    }
  }

  static String? _grab(String regOutput, String value) {
    final m = RegExp('$value\\s+REG_[A-Z_]+\\s+(.+)').firstMatch(regOutput);
    return m?.group(1)?.trim();
  }

  Future<List<String>> apply(RuntimeSettings settings, {required bool enable}) async {
    final commands = enable
        ? _plan.enable(
            platform: _platform,
            host: settings.listenAddress,
            port: settings.enableHttpInbound ? settings.httpPort : settings.socksPort,
            bypass: settings.systemProxyBypass,
            service: service,
          )
        : _plan.disable(platform: _platform, service: service);

    final failures = <String>[];
    for (final c in commands) {
      try {
        final r = await Process.run(c.executable, c.args);
        if (r.exitCode != 0) {
          final msg = ('${r.stderr}').trim();
          failures.add('${c.executable} exited ${r.exitCode}${msg.isEmpty ? '' : ': $msg'}');
        }
      } on ProcessException catch (e) {
        failures.add('${c.executable}: ${e.message}');
      }
    }
    if (enable && failures.isEmpty) {
      _managedByUs = true;
    } else if (!enable) {
      _managedByUs = false;
    }
    return failures;
  }

  /// Put back whatever was there before us. Called on disconnect, on quit, and
  /// from the kill-switch path when the engine dies.
  Future<void> restore() async {
    if (!_managedByUs) return;
    if (_platform == PlatformIdentifier.windows && _wasEnabled && _previousServer.isNotEmpty) {
      await Process.run('reg', <String>[
        'add',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
        '/v', 'ProxyServer', '/t', 'REG_SZ', '/d', _previousServer, '/f',
      ]);
    } else {
      await apply(const RuntimeSettings(), enable: false);
    }
    _managedByUs = false;
  }
}

enum PlatformIdentifier { windows, macos, linux, android, ios }
