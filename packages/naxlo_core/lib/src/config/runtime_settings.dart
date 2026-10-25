import '../json/json_utils.dart';

/// How the client hooks the operating system into the tunnel.
///
/// * [systemProxy] — set the OS proxy to our local inbound. Zero privileges
///   needed, per-app reversible, and the only mode that works on all three
///   desktops without root. It does not capture apps that ignore the proxy
///   settings (most UDP/QUIC, some games) — that is what [tun] is for.
/// * [tun] — a virtual NIC via sing-box. Needs admin/root; captures everything.
/// * [manual] — the engine runs, the user points their browser at it. Nothing
///   is touched outside the app, which is the safest default on shared machines.
enum ProxyMode {
  manual('manual', 'Leave system alone'),
  systemProxy('systemProxy', 'System proxy (127.0.0.1)'),
  tun('tun', 'TUN interface (requires privileges)');

  const ProxyMode(this.wireName, this.label);
  final String wireName;
  final String label;

  static ProxyMode fromName(String? raw) {
    final s = asString(raw).trim();
    for (final e in ProxyMode.values) {
      if (e.wireName == s) return e;
    }
    return ProxyMode.systemProxy;
  }

  bool get touchesSystem => this != ProxyMode.manual;
  bool get needsPrivileges => this == ProxyMode.tun;
}

/// App-wide settings that are not part of any single profile: ports, engine
/// plumbing, updater, logging. Persisted next to the profile bundle.
class RuntimeSettings {
  const RuntimeSettings({
    this.proxyMode = ProxyMode.systemProxy,
    this.listenAddress = '127.0.0.1',
    this.socksPort = 20151,
    this.httpPort = 20152,
    this.enableSocksInbound = true,
    this.enableHttpInbound = true,
    this.autoConnectOnLaunch = false,
    this.autoRestartEngine = true,
    this.maxRestarts = 5,
    this.killSwitch = true,
    this.systemProxyBypass = const <String>['localhost', '127.0.0.1', '::1', '192.168.0.0/16', '10.0.0.0/8'],
    this.proxyAllProtocols = true,
    this.tcpFastOpen = true,
    this.mtu = 0,
    this.sniffQuic = true,
    this.allowInsecureGlobal = false,
    this.accessLogPath = '',
    this.errorLogPath = '',
    this.logDir = '',
    this.xrayBinaryPath = '',
    this.singBoxBinaryPath = '',
    this.xrayLogLevel = 'warning',
    this.singBoxLogLevel = 'info',
    this.tunStack = 'system',
    this.tunIndex = 0,
    this.isPrivileged = false,
    this.keepRankingHistoryDays = 7,
    this.probeWhileConnected = true,
    this.checkForUpdates = true,
    this.manifestUrl = '',
    this.updateChannel = 'stable',
    this.allowPrereleaseUpdates = false,
    this.themeMode = 'system',
    this.locale = '',
    this.showLatencyMs = true,
    this.developerVerboseConfig = false,
  });

  final ProxyMode proxyMode;
  final String listenAddress;
  final int socksPort;
  final int httpPort;
  final bool enableSocksInbound;
  final bool enableHttpInbound;

  final bool autoConnectOnLaunch;
  final bool autoRestartEngine;

  /// Restarts within a minute before we give up and surface the error — an
  /// endless restart loop on a broken server is worse than an error banner.
  final int maxRestarts;

  /// Disconnect the system proxy when the engine dies instead of leaking traffic.
  final bool killSwitch;
  final List<String> systemProxyBypass;

  /// Also set HTTP(S)_PROXY env-ish settings / PAC-less "all protocols".
  final bool proxyAllProtocols;
  final bool tcpFastOpen;

  /// 0 = engine default.
  final int mtu;
  final bool sniffQuic;

  /// Global override so an imported node with `allowInsecure` does not silently
  /// disable cert validation unless the user opted in.
  final bool allowInsecureGlobal;

  final String accessLogPath;
  final String errorLogPath;
  final String logDir;
  final String xrayBinaryPath;
  final String singBoxBinaryPath;
  final String xrayLogLevel;
  final String singBoxLogLevel;

  /// `system` is the most compatible; `gvisor` avoids the TUN device on some
  /// kernels at the cost of UDP throughput.
  final String tunStack;

  /// Which `naxloN` interface name to claim, so two profiles can coexist.
  final int tunIndex;

  /// Whether the app detected admin/root at startup. Drives the TUN warning.
  final bool isPrivileged;

  /// Ranker history older than this is pruned at launch (privacy + disk).
  final int keepRankingHistoryDays;

  /// Keep measuring the active node while connected; off saves battery on
  /// laptops running on DC power.
  final bool probeWhileConnected;

  final bool checkForUpdates;

  /// Empty → kDefaultManifestUrl.
  final String manifestUrl;
  final String updateChannel;
  final bool allowPrereleaseUpdates;

  /// `system` | `light` | `dark` | `black` (OLED).
  final String themeMode;

  /// Empty = follow the OS. `en`, `fa`, `ru`.
  final String locale;
  final bool showLatencyMs;
  final bool developerVerboseConfig;

  bool get usesTun => proxyMode == ProxyMode.tun;
  int get apiStatsPort => 0; // reserved; stats come from access-log parsing

  RuntimeSettings copyWith({
    ProxyMode? proxyMode,
    int? socksPort,
    int? httpPort,
    bool? enableSocksInbound,
    bool? enableHttpInbound,
    bool? autoConnectOnLaunch,
    bool? autoRestartEngine,
    bool? killSwitch,
    String? accessLogPath,
    String? errorLogPath,
    String? logDir,
    String? xrayBinaryPath,
    String? singBoxLogLevel,
    String? tunStack,
    int? tunIndex,
    bool? isPrivileged,
    String? singBoxBinaryPath,
    String? themeMode,
    String? locale,
    bool? probeWhileConnected,
    bool? checkForUpdates,
    String? manifestUrl,
    String? updateChannel,
    bool? developerVerboseConfig,
  }) {
    return RuntimeSettings(
      proxyMode: proxyMode ?? this.proxyMode,
      listenAddress: listenAddress,
      socksPort: socksPort ?? this.socksPort,
      httpPort: httpPort ?? this.httpPort,
      enableSocksInbound: enableSocksInbound ?? this.enableSocksInbound,
      enableHttpInbound: enableHttpInbound ?? this.enableHttpInbound,
      autoConnectOnLaunch: autoConnectOnLaunch ?? this.autoConnectOnLaunch,
      autoRestartEngine: autoRestartEngine ?? this.autoRestartEngine,
      maxRestarts: maxRestarts,
      killSwitch: killSwitch ?? this.killSwitch,
      systemProxyBypass: systemProxyBypass,
      proxyAllProtocols: proxyAllProtocols,
      tcpFastOpen: tcpFastOpen,
      mtu: mtu,
      sniffQuic: sniffQuic,
      allowInsecureGlobal: allowInsecureGlobal,
      accessLogPath: accessLogPath ?? this.accessLogPath,
      errorLogPath: errorLogPath ?? this.errorLogPath,
      logDir: logDir ?? this.logDir,
      xrayBinaryPath: xrayBinaryPath ?? this.xrayBinaryPath,
      singBoxLogLevel: singBoxLogLevel ?? this.singBoxLogLevel,
      tunStack: tunStack ?? this.tunStack,
      tunIndex: tunIndex ?? this.tunIndex,
      isPrivileged: isPrivileged ?? this.isPrivileged,
      singBoxBinaryPath: singBoxBinaryPath ?? this.singBoxBinaryPath,
      xrayLogLevel: xrayLogLevel,
      keepRankingHistoryDays: keepRankingHistoryDays,
      probeWhileConnected: probeWhileConnected ?? this.probeWhileConnected,
      checkForUpdates: checkForUpdates ?? this.checkForUpdates,
      manifestUrl: manifestUrl ?? this.manifestUrl,
      updateChannel: updateChannel ?? this.updateChannel,
      allowPrereleaseUpdates: allowPrereleaseUpdates,
      themeMode: themeMode ?? this.themeMode,
      locale: locale ?? this.locale,
      showLatencyMs: showLatencyMs,
      developerVerboseConfig: developerVerboseConfig ?? this.developerVerboseConfig,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'proxyMode': proxyMode.wireName,
        'listenAddress': listenAddress,
        'socksPort': socksPort,
        'httpPort': httpPort,
        'enableSocksInbound': enableSocksInbound,
        'enableHttpInbound': enableHttpInbound,
        'autoConnectOnLaunch': autoConnectOnLaunch,
        'autoRestartEngine': autoRestartEngine,
        'maxRestarts': maxRestarts,
        'killSwitch': killSwitch,
        'systemProxyBypass': List<String>.from(systemProxyBypass),
        'tcpFastOpen': tcpFastOpen,
        'mtu': mtu,
        'sniffQuic': sniffQuic,
        'allowInsecureGlobal': allowInsecureGlobal,
        'logDir': logDir,
        'xrayBinaryPath': xrayBinaryPath,
        'singBoxBinaryPath': singBoxBinaryPath,
        'xrayLogLevel': xrayLogLevel,
        'singBoxLogLevel': singBoxLogLevel,
        'tunStack': tunStack,
        'tunIndex': tunIndex,
        'keepRankingHistoryDays': keepRankingHistoryDays,
        'probeWhileConnected': probeWhileConnected,
        'checkForUpdates': checkForUpdates,
        'manifestUrl': manifestUrl,
        'updateChannel': updateChannel,
        'themeMode': themeMode,
        'locale': locale,
        'developerVerboseConfig': developerVerboseConfig,
      };

  static RuntimeSettings fromJson(Map<String, Object?> json) {
    const d = RuntimeSettings();
    if (json.isEmpty) return d;
    return RuntimeSettings(
      proxyMode: ProxyMode.fromName(asString(json['proxyMode'])),
      listenAddress: asString(json['listenAddress'], fallback: d.listenAddress),
      socksPort: asInt(json['socksPort'], fallback: d.socksPort),
      httpPort: asInt(json['httpPort'], fallback: d.httpPort),
      enableSocksInbound: asBool(json['enableSocksInbound'], fallback: true),
      enableHttpInbound: asBool(json['enableHttpInbound'], fallback: true),
      autoConnectOnLaunch: asBool(json['autoConnectOnLaunch']),
      autoRestartEngine: asBool(json['autoRestartEngine'], fallback: true),
      maxRestarts: asInt(json['maxRestarts'], fallback: d.maxRestarts),
      killSwitch: asBool(json['killSwitch'], fallback: true),
      systemProxyBypass: asStringList(json['systemProxyBypass']).isEmpty
          ? d.systemProxyBypass
          : asStringList(json['systemProxyBypass']),
      proxyAllProtocols: asBool(json['proxyAllProtocols'], fallback: true),
      tcpFastOpen: asBool(json['tcpFastOpen'], fallback: true),
      mtu: asInt(json['mtu']),
      sniffQuic: asBool(json['sniffQuic'], fallback: true),
      allowInsecureGlobal: asBool(json['allowInsecureGlobal']),
      logDir: asString(json['logDir']),
      xrayBinaryPath: asString(json['xrayBinaryPath']),
      singBoxBinaryPath: asString(json['singBoxBinaryPath']),
      xrayLogLevel: asString(json['xrayLogLevel'], fallback: d.xrayLogLevel),
      singBoxLogLevel: asString(json['singBoxLogLevel'], fallback: d.singBoxLogLevel),
      tunStack: asString(json['tunStack'], fallback: d.tunStack),
      tunIndex: asInt(json['tunIndex']),
      isPrivileged: asBool(json['isPrivileged']),
      keepRankingHistoryDays: asInt(json['keepRankingHistoryDays'], fallback: d.keepRankingHistoryDays),
      probeWhileConnected: asBool(json['probeWhileConnected'], fallback: true),
      checkForUpdates: asBool(json['checkForUpdates'], fallback: true),
      manifestUrl: asString(json['manifestUrl']),
      updateChannel: asString(json['updateChannel'], fallback: d.updateChannel),
      allowPrereleaseUpdates: asBool(json['allowPrereleaseUpdates']),
      themeMode: asString(json['themeMode'], fallback: d.themeMode),
      locale: asString(json['locale']),
      showLatencyMs: asBool(json['showLatencyMs'], fallback: true),
      developerVerboseConfig: asBool(json['developerVerboseConfig']),
    );
  }

  static const RuntimeSettings defaults = RuntimeSettings();
}
