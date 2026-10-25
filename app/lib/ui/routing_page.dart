import 'package:flutter/material.dart';
import 'package:naxlo_core/naxlo_core.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../theme/palette.dart';
import 'widgets.dart';

/// Routing + DNS. The engine enforces these rules; this screen only previews
/// the decision ([RoutingConfig.matchHost]) so a mistake is visible before a
/// connection is attempted.
class RoutingPage extends StatelessWidget {
  const RoutingPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final l10n = NaxloLocalizations.of(context);
    final profile = app.profile;
    if (profile == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.t('nav.routing'))),
        body: EmptyState(title: l10n.t('empty.noProfiles'), icon: Icons.alt_route_rounded),
      );
    }
    final r = profile.routing;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.t('nav.routing')),
        actions: <Widget>[
          IconButton(
            onPressed: () => _addRule(context, app, profile),
            icon: const Icon(Icons.add_rounded),
            tooltip: 'rule',
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: <Widget>[
          Section(
            title: l10n.t('label.preset'),
            child: Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      for (final p in RoutingPreset.values)
                        ChoiceChip(
                          label: Text(p.label),
                          selected: r.preset == p,
                          onSelected: (_) => app.replaceProfile(profile.copyWith(routing: r.copyWith(preset: p))),
                        ),
                    ],
                  ),
                  if (r.preset == RoutingPreset.proxyAll)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        'LAN and localhost will also be tunnelled; printers and Chromecast-style devices usually break.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Palette.amber),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Section(
            title: 'switches',
            child: Panel(
              child: Column(
                children: <Widget>[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('bypass LAN'),
                    subtitle: const Text('local names and private ranges go direct'),
                    value: r.bypassLan,
                    onChanged: (v) => app.replaceProfile(profile.copyWith(routing: r.copyWith(bypassLan: v))),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('block private IPs over the tunnel'),
                    value: r.blockPrivateIp,
                    onChanged: (v) => app.replaceProfile(profile.copyWith(routing: r.copyWith(blockPrivateIp: v))),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('block QUIC (forces TCP/443)'),
                    subtitle: const Text('otherwise Chrome bypasses HTTP proxies for many sites'),
                    value: r.blockQuic,
                    onChanged: (v) => app.replaceProfile(profile.copyWith(routing: r.copyWith(blockQuic: v))),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('block ad & tracker domains'),
                    value: r.blockAdsDomains,
                    onChanged: (v) => app.replaceProfile(profile.copyWith(routing: r.copyWith(blockAdsDomains: v))),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('sniff TLS SNI'),
                    value: r.sniffOverrideTls,
                    onChanged: (v) => app.replaceProfile(profile.copyWith(routing: r.copyWith(sniffOverrideTls: v))),
                  ),
                ],
              ),
            ),
          ),
          Section(
            title: '${l10n.t('group.nodes')} · rules',
            subtitle: 'evaluated top-down, before the preset default',
            child: Panel(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
              child: r.rules.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text('no custom rules', style: Theme.of(context).textTheme.bodySmall),
                    )
                  : Column(
                      children: <Widget>[
                        for (var i = 0; i < r.rules.length; i++)
                          ListTile(
                            dense: true,
                            leading: Icon(
                              switch (r.rules[i].action) {
                                RoutingAction.proxy => Icons.cloud_done_rounded,
                                RoutingAction.direct => Icons.lan_rounded,
                                RoutingAction.block => Icons.block_rounded,
                              },
                              size: 18,
                              color: switch (r.rules[i].action) {
                                RoutingAction.proxy => Palette.cyan,
                                RoutingAction.direct => Palette.mint,
                                RoutingAction.block => Palette.rose,
                              },
                            ),
                            title: Text('${r.rules[i].type.wireName} → ${r.rules[i].action.wireName}',
                                style: Theme.of(context).textTheme.bodyMedium),
                            subtitle: Text(r.rules[i].values.join(', '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelSmall),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline_rounded, size: 18),
                              onPressed: () => app.replaceProfile(profile.copyWith(
                                routing: r.copyWith(
                                  rules: <RoutingRule>[
                                    for (var j = 0; j < r.rules.length; j++)
                                      if (j != i) r.rules[j],
                                    ],
                                ),
                              )),
                            ),
                          ),
                      ],
                    ),
            ),
          ),
          _PreviewCard(app: app, l10n: l10n, routing: r),
          _DnsSection(app: app, l10n: l10n, profile: profile),
        ],
      ),
    );
  }

  Future<void> _addRule(BuildContext context, AppState app, Profile profile) async {
    final values = TextEditingController();
    var type = RuleType.domainSuffix;
    var action = RoutingAction.direct;
    final ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) => AlertDialog(
          title: const Text('new rule'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                DropdownButtonFormField<RuleType>(
                  value: type,
                  items: <DropdownMenuItem<RuleType>>[
                    for (final t in RuleType.values) DropdownMenuItem<RuleType>(value: t, child: Text(t.wireName)),
                  ],
                  onChanged: (v) => setState(() => type = v ?? type),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<RoutingAction>(
                  value: action,
                  items: <DropdownMenuItem<RoutingAction>>[
                    for (final a in RoutingAction.values)
                      DropdownMenuItem<RoutingAction>(value: a, child: Text(a.wireName)),
                  ],
                  onChanged: (v) => setState(() => action = v ?? action),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: values,
                  maxLines: 3,
                  decoration: const InputDecoration(hintText: 'example.com, 10.0.0.0/8 …'),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(context, values.text.trim().isNotEmpty),
              child: const Text('add'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    await app.replaceProfile(profile.copyWith(
      routing: profile.routing.copyWith(
        rules: <RoutingRule>[
          ...profile.routing.rules,
          RoutingRule(
            action: action,
            type: type,
            values: values.text.split(RegExp(r'[,;\n ]+')).where((s) => s.isNotEmpty).toList(),
          ),
        ],
      ),
    ));
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.app, required this.l10n, required this.routing});

  final AppState app;
  final NaxloLocalizations l10n;
  final RoutingConfig routing;

  @override
  Widget build(BuildContext context) {
    const probeHosts = <String>['example.com', 'printer.local', '192.168.1.50', 'doubleclick.net'];
    return Section(
      title: 'preview',
      subtitle: 'the same decision the engine will make',
      child: Panel(
        child: Column(
          children: <Widget>[
            for (final h in probeHosts)
              KvRow(
                key_: h,
                value: switch (h.contains(':') || _isIp(h) ? routing.matchIp(h) : routing.matchHost(h)) {
                  RoutingAction.proxy => 'proxy',
                  RoutingAction.direct => 'direct',
                  RoutingAction.block => 'block',
                },
              ),
          ],
        ),
      ),
    );
  }

  static bool _isIp(String s) => RegExp(r'^\d{1,3}(\.\d{1,3}){3}$|:').hasMatch(s);
}

class _DnsSection extends StatelessWidget {
  const _DnsSection({required this.app, required this.l10n, required this.profile});

  final AppState app;
  final NaxloLocalizations l10n;
  final Profile profile;

  @override
  Widget build(BuildContext context) {
    final dns = profile.dns;
    return Section(
      title: 'DNS',
      child: Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SegmentedButton<DnsStrategy>(
              segments: <ButtonSegment<DnsStrategy>>[
                for (final s in DnsStrategy.values)
                  ButtonSegment<DnsStrategy>(value: s, label: Text(s.wireName), tooltip: s.label),
              ],
              selected: <DnsStrategy>{dns.strategy},
              showSelectedIcon: false,
              onSelectionChanged: (sel) => app.replaceProfile(profile.copyWith(dns: dns.copyWith(strategy: sel.first))),
            ),
            const SizedBox(height: 12),
            for (final s in dns.servers)
              KvRow(key_: 'remote', value: s.address.isEmpty ? '(empty)' : s.address),
            for (final s in dns.directServers)
              KvRow(key_: 'direct', value: s.address),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('leak-protect DNS (force :53 into the tunnel)'),
              value: dns.leakProtect,
              onChanged: (v) => app.replaceProfile(profile.copyWith(dns: dns.copyWith(leakProtect: v))),
            ),
          ],
        ),
      ),
    );
  }
}
