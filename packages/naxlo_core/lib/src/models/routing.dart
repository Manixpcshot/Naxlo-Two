import '../geo/geo.dart';
import '../json/json_utils.dart';

/// What happens when a rule matches.
enum RoutingAction {
  proxy('proxy'),
  direct('direct'),
  block('block');

  const RoutingAction(this.wireName);
  final String wireName;

  static RoutingAction fromName(String? raw) {
    final s = asString(raw).trim().toLowerCase();
    for (final e in RoutingAction.values) {
      if (e.wireName == s) return e;
    }
    return RoutingAction.proxy;
  }
}

/// Matcher kinds, named the way Xray names them so an imported config
/// round-trips without surprises.
enum RuleType {
  domain('domain'),
  domainSuffix('domainSuffix'),
  domainKeyword('domainKeyword'),
  domainRegex('domainRegex'),
  fullDomain('fullDomain'),
  cidr('cidr'),
  port('port'),
  protocol('protocol');

  const RuleType(this.wireName);
  final String wireName;

  static RuleType fromName(String? raw) {
    final s = asString(raw).trim();
    for (final e in RuleType.values) {
      if (e.wireName == s) return e;
    }
    return RuleType.domainSuffix;
  }

  bool get isDomainish =>
      this == RuleType.domain ||
      this == RuleType.domainSuffix ||
      this == RuleType.domainKeyword ||
      this == RuleType.domainRegex ||
      this == RuleType.fullDomain;
}

/// One routing rule. `values` holds domains, `host:`-prefixed items or CIDRs,
/// exactly as a user would paste them from a v2ray routing snippet.
class RoutingRule {
  const RoutingRule({
    required this.action,
    required this.type,
    required this.values,
    this.inboundTag = '',
    this.enabled = true,
  });

  final RoutingAction action;
  final RuleType type;
  final List<String> values;
  final String inboundTag;
  final bool enabled;

  int get valueCount => values.length;

  RoutingRule copyWith({RoutingAction? action, RuleType? type, List<String>? values, bool? enabled}) {
    return RoutingRule(
      action: action ?? this.action,
      type: type ?? this.type,
      values: values ?? this.values,
      inboundTag: inboundTag,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'action': action.wireName,
        'type': type.wireName,
        'values': List<String>.from(values),
        if (inboundTag.isNotEmpty) 'inboundTag': inboundTag,
        'enabled': enabled,
      };

  static RoutingRule fromJson(Map<String, Object?> json) => RoutingRule(
        action: RoutingAction.fromName(asString(json['action'])),
        type: RuleType.fromName(asString(json['type'])),
        values: asStringList(json['values']),
        inboundTag: asString(json['inboundTag']),
        enabled: asBool(json['enabled'], fallback: true),
      );

  /// Convenience for the UI: a short label such as `suffix · 12 domains`.
  String get summary {
    final n = values.length;
    final noun = n == 1 ? 'entry' : 'entries';
    return '${type.wireName} · $n $noun';
  }
}

/// Presets cover 90% of real usage without the user writing rules.
enum RoutingPreset {
  proxyAll('proxyAll', 'Everything through the proxy'),
  bypassLan('bypassLan', 'Proxy all, bypass LAN & private ranges'),
  directFirst('directFirst', 'Direct unless the domain is listed'),
  blockAds('blockAds', 'Bypass LAN, block ad & tracker domains');

  const RoutingPreset(this.wireName, this.label);
  final String wireName;
  final String label;

  static RoutingPreset fromName(String? raw) {
    final s = asString(raw).trim();
    for (final e in RoutingPreset.values) {
      if (e.wireName == s) return e;
    }
    return RoutingPreset.bypassLan;
  }
}

/// Per-profile routing policy: a preset plus user rules, evaluated in order.
class RoutingConfig {
  const RoutingConfig({
    this.preset = RoutingPreset.bypassLan,
    this.rules = const <RoutingRule>[],
    this.domainStrategy = 'AsIs',
    this.bypassLan = true,
    this.blockPrivateIp = true,
    this.blockQuic = true,
    this.blockAdsDomains = false,
    this.sniffOverrideTls = true,
  });

  const RoutingConfig.defaults()
      : preset = RoutingPreset.bypassLan,
        rules = const <RoutingRule>[],
        domainStrategy = 'AsIs',
        bypassLan = true,
        blockPrivateIp = true,
        blockQuic = true,
        blockAdsDomains = false,
        sniffOverrideTls = true;

  final RoutingPreset preset;
  final List<RoutingRule> rules;

  /// Xray `routing.domainStrategy`: `AsIs` | `IPIfNonMatch` | `IPOnDemand`.
  final String domainStrategy;
  final bool bypassLan;
  final bool blockPrivateIp;
  final bool blockQuic;
  final bool blockAdsDomains;

  /// Sniff TLS SNI and route on it (defeats IP-based blocking of CDNs).
  final bool sniffOverrideTls;

  List<RoutingRule> get effectiveRules {
    final out = <RoutingRule>[
      if (blockQuic)
        const RoutingRule(action: RoutingAction.block, type: RuleType.port, values: <String>['443/udp']),
      for (final r in rules)
        if (r.enabled) r,
    ];
    return out;
  }

  /// Domains/IP ranges that must go direct regardless of the preset.
  List<String> get bypassDomains {
    if (!bypassLan) return const <String>[];
    return const <String>[...kLanDomainSuffixes];
  }

  List<String> get bypassCidrs {
    if (!blockPrivateIp) return const <String>[];
    return const <String>[...kPrivateIpv4Cidrs, ...kPrivateIpv6Cidrs];
  }

  RoutingConfig copyWith({
    RoutingPreset? preset,
    List<RoutingRule>? rules,
    String? domainStrategy,
    bool? bypassLan,
    bool? blockPrivateIp,
    bool? blockQuic,
    bool? blockAdsDomains,
    bool? sniffOverrideTls,
  }) {
    return RoutingConfig(
      preset: preset ?? this.preset,
      rules: rules ?? this.rules,
      domainStrategy: domainStrategy ?? this.domainStrategy,
      bypassLan: bypassLan ?? this.bypassLan,
      blockPrivateIp: blockPrivateIp ?? this.blockPrivateIp,
      blockQuic: blockQuic ?? this.blockQuic,
      blockAdsDomains: blockAdsDomains ?? this.blockAdsDomains,
      sniffOverrideTls: sniffOverrideTls ?? this.sniffOverrideTls,
    );
  }

  /// Which outbound a hostname should use — the same decision the engine makes,
  /// re-implemented so the UI can say "youtube.com → proxy" before connecting.
  RoutingAction matchHost(String host) {
    final h = host.toLowerCase();
    if (blockQuic) {
      // handled by port rule at the engine level; nothing to say here
    }
    for (final rule in effectiveRules) {
      if (rule.type.isDomainish && _ruleMatchesDomain(rule, h)) return rule.action;
    }
    if (blockAdsDomains && kAdDomains.any((d) => h.endsWith(d))) return RoutingAction.block;
    if (bypassLan && kLanDomainSuffixes.any((d) => h.endsWith(d))) return RoutingAction.direct;
    switch (preset) {
      case RoutingPreset.directFirst:
        return RoutingAction.direct;
      case RoutingPreset.proxyAll:
      case RoutingPreset.bypassLan:
      case RoutingPreset.blockAds:
        return RoutingAction.proxy;
    }
  }

  /// Which outbound an IP should use.
  RoutingAction matchIp(String ip) {
    if (blockPrivateIp && isPrivateAddress(ip)) return RoutingAction.direct;
    for (final rule in effectiveRules) {
      if (rule.type == RuleType.cidr && cidrMatchesAny(rule.values, ip)) return rule.action;
    }
    switch (preset) {
      case RoutingPreset.directFirst:
        return RoutingAction.direct;
      case RoutingPreset.proxyAll:
      case RoutingPreset.bypassLan:
      case RoutingPreset.blockAds:
        return RoutingAction.proxy;
    }
  }

  static bool _ruleMatchesDomain(RoutingRule rule, String host) {
    for (final v in rule.values) {
      final item = v.toLowerCase();
      if (item.isEmpty) continue;
      switch (rule.type) {
        case RuleType.domain:
          if (host.endsWith(item)) return true;
        case RuleType.domainSuffix:
          if (host == item || host.endsWith('.$item')) return true;
        case RuleType.fullDomain:
          if (host == item) return true;
        case RuleType.domainKeyword:
          if (host.contains(item)) return true;
        case RuleType.domainRegex:
          if (RegExp(item).hasMatch(host)) return true;
        case RuleType.cidr:
        case RuleType.port:
        case RuleType.protocol:
          break;
      }
    }
    return false;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'preset': preset.wireName,
        'domainStrategy': domainStrategy,
        'bypassLan': bypassLan,
        'blockPrivateIp': blockPrivateIp,
        'blockQuic': blockQuic,
        'blockAdsDomains': blockAdsDomains,
        'sniffOverrideTls': sniffOverrideTls,
        'rules': <Object?>[for (final r in rules) r.toJson()],
      };

  static RoutingConfig fromJson(Map<String, Object?> json) {
    if (json.isEmpty) return const RoutingConfig.defaults();
    return RoutingConfig(
      preset: RoutingPreset.fromName(asString(json['preset'])),
      rules: <RoutingRule>[
        for (final raw in asList(json['rules'])) RoutingRule.fromJson(asMap(raw)),
      ],
      domainStrategy: asString(json['domainStrategy'], fallback: 'AsIs'),
      bypassLan: asBool(json['bypassLan'], fallback: true),
      blockPrivateIp: asBool(json['blockPrivateIp'], fallback: true),
      blockQuic: asBool(json['blockQuic'], fallback: true),
      blockAdsDomains: asBool(json['blockAdsDomains']),
      sniffOverrideTls: asBool(json['sniffOverrideTls'], fallback: true),
    );
  }
}
