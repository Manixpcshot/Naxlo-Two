import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:naxlo_core/naxlo_core.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../theme/palette.dart';
import 'widgets.dart';

/// The ranked list. This screen is the product: a table of nodes ordered by the
/// adaptive score, where every row can be opened to see *why* it sits there.
class ServersPage extends StatefulWidget {
  const ServersPage({super.key});

  @override
  State<ServersPage> createState() => _ServersPageState();
}

class _ServersPageState extends State<ServersPage> {
  final TextEditingController _search = TextEditingController();
  bool _showUnreachable = true;
  String _labelFilter = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final l10n = NaxloLocalizations.of(context);
    final profile = app.profile;

    if (profile == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.t('nav.servers'))),
        body: EmptyState(title: l10n.t('empty.noProfiles'), icon: Icons.leaderboard_rounded),
      );
    }

    final byId = <String, ServerNode>{for (final s in profile.servers) s.id: s};
    var rows = <RankedServer>[
      for (final r in app.ranked)
        if (byId.containsKey(r.serverId)) r,
    ];
    final q = _search.text.trim().toLowerCase();
    if (q.isNotEmpty) {
      rows = <RankedServer>[
        for (final r in rows)
          if (byId[r.serverId]!.displayName.toLowerCase().contains(q) ||
              byId[r.serverId]!.address.toLowerCase().contains(q))
            r,
      ];
    }
    if (_labelFilter.isNotEmpty) {
      rows = <RankedServer>[
        for (final r in rows)
          if (byId[r.serverId]!.labels.contains(_labelFilter)) r,
      ];
    }
    if (!_showUnreachable) {
      rows = <RankedServer>[for (final r in rows) if (r.isEligible) r];
    }

    final labels = <String>{for (final s in profile.servers) ...s.labels}.toList()..sort();

    return Scaffold(
      appBar: AppBar(
        title: Text('${l10n.t('nav.servers')} · ${profile.servers.length}'),
        actions: <Widget>[
          IconButton(
            tooltip: l10n.t('action.probeAll'),
            onPressed: app.probeAll,
            icon: const Icon(Icons.speed_rounded),
          ),
          IconButton(
            tooltip: l10n.t('action.addProfile'),
            onPressed: () => _showAddNodeSheet(context, app, profile),
            icon: const Icon(Icons.add_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search_rounded, size: 18),
                      hintText: l10n.t('nav.servers'),
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close_rounded, size: 16),
                              onPressed: () {
                                _search.clear();
                                setState(() {});
                              },
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                PopupMenuButton<String>(
                  tooltip: l10n.t('label.preset'),
                  onSelected: (v) => setState(() => _labelFilter = v == _labelFilter ? '' : v),
                  itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                    const PopupMenuItem<String>(value: '', child: Text('—')),
                    for (final l in labels) PopupMenuItem<String>(value: l, child: Text(l)),
                  ],
                  icon: Icon(_labelFilter.isEmpty ? Icons.sell_outlined : Icons.sell),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: <Widget>[
                FilterChip(
                  selected: _showUnreachable,
                  onSelected: (v) => setState(() => _showUnreachable = v),
                  label: Text(l10n.t('label.showUnreachable')),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  selected: profile.autoSelect,
                  onSelected: app.setAutoSelect,
                  label: Text(l10n.t('label.autoSelect')),
                ),
                const Spacer(),
                Text(
                  l10n.t(app.ranking.mode == RankingMode.advanced ? 'label.rankModeAdvanced' : 'label.rankModeSimple'),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: rows.isEmpty
                ? EmptyState(title: l10n.t('empty.noNodes'), icon: Icons.link_off_rounded)
                : RefreshIndicator(
                    onRefresh: app.probeAll,
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                      itemCount: rows.length,
                      itemBuilder: (BuildContext context, int i) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: RankedTile(
                          ranked: rows[i],
                          node: byId[rows[i].serverId]!,
                          metrics: app.metricsOf(rows[i].serverId),
                          isPinned: profile.selectedServerId == rows[i].serverId,
                          onTap: () => showRankingSheet(context, rows[i], app),
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class RankedTile extends StatelessWidget {
  const RankedTile({
    required this.ranked,
    required this.node,
    required this.metrics,
    required this.isPinned,
    required this.onTap,
    super.key,
  });

  final RankedServer ranked;
  final ServerNode node;
  final ServerMetrics? metrics;
  final bool isPinned;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dim = !ranked.isEligible;
    return Opacity(
      opacity: dim ? 0.55 : 1,
      child: Panel(
        onTap: onTap,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                RankBadge(rank: ranked.rank, isCurrent: ranked.isCurrent),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              node.displayName,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                          if (isPinned)
                            const Padding(
                              padding: EdgeInsetsDirectional.only(start: 6),
                              child: Icon(Icons.push_pin_rounded, size: 13, color: Palette.amber),
                            ),
                        ],
                      ),
                      Text(
                        '${node.endpoint} · ${node.protocol.label} · ${node.transportOptions.transport.label}',
                        style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (metrics != null) HealthIcon(state: metrics!.health),
                LatencyChip(latencyMs: ranked.latencyMs, jitterMs: ranked.jitterMs, dense: true),
              ],
            ),
            const SizedBox(height: 8),
            ScoreBar(score: ranked.score, color: ranked.isCurrent ? Palette.mint : null),
            if (ranked.consecutiveFailures > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${ranked.consecutiveFailures}× ${metrics?.lastError ?? 'unreachable'}',
                  style: theme.textTheme.labelSmall?.copyWith(color: Palette.rose),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The "why" sheet: components, raw evidence, and the actions a user reaches
/// for after reading it (pin, disable, measure, bias, copy link).
Future<void> showRankingSheet(BuildContext context, RankedServer r, AppState app) async {
  final l10n = NaxloLocalizations.of(context);
  final profile = app.profile;
  final node = profile?.byId(r.serverId);
  final metrics = app.metricsOf(r.serverId);
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext sheetContext) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              node?.displayName ?? r.serverId,
              style: Theme.of(sheetContext).textTheme.titleLarge,
            ),
            const SizedBox(height: 2),
            Text(
              node?.endpoint ?? '',
              style: Theme.of(sheetContext).textTheme.bodySmall?.copyWith(color: Theme.of(sheetContext).hintColor),
            ),
            const SizedBox(height: 14),
            ScoreBar(score: r.score, height: 8),
            const SizedBox(height: 14),
            Text(l10n.t('label.whyRanked'), style: Theme.of(sheetContext).textTheme.titleSmall),
            const SizedBox(height: 6),
            for (final reason in r.reasons)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text('· ', style: TextStyle(fontWeight: FontWeight.w700)),
                    Expanded(child: Text(reason, style: Theme.of(sheetContext).textTheme.bodySmall)),
                  ],
                ),
              ),
            if (r.components.isNotEmpty) ...<Widget>[
              const SizedBox(height: 14),
              Text(l10n.t('label.weights'), style: Theme.of(sheetContext).textTheme.titleSmall),
              const SizedBox(height: 6),
              for (final e in r.components.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Row(
                    children: <Widget>[
                      SizedBox(width: 110, child: Text(e.key, style: Theme.of(sheetContext).textTheme.bodySmall)),
                      Expanded(child: ScoreBar(score: e.value.clamp(0.0, 1.0), showValue: true)),
                    ],
                  ),
                ),
            ],
            if (metrics != null) ...<Widget>[
              const SizedBox(height: 14),
              Text(l10n.t('group.diagnostics'), style: Theme.of(sheetContext).textTheme.titleSmall),
              const SizedBox(height: 6),
              KvRow(key_: l10n.t('label.latency'), value: '${r.latencyMs} ${l10n.t('unit.ms')}'),
              KvRow(key_: l10n.t('label.jitter'), value: '${r.jitterMs} ${l10n.t('unit.ms')}'),
              KvRow(key_: l10n.t('label.reliability'), value: '${(metrics.reliability * 100).toStringAsFixed(1)}%'),
              KvRow(
                key_: 'samples',
                value: '${metrics.totalSamples}',
                hint: '${metrics.okWeight.toStringAsFixed(1)} ok / ${metrics.failWeight.toStringAsFixed(1)} fail (decayed)',
              ),
              KvRow(key_: 'age', value: '${(r.ageMs / 1000).toStringAsFixed(0)} ${l10n.t('unit.sec')}'),
              if (metrics.throughputKbps > 0)
                KvRow(key_: l10n.t('label.throughput'), value: '${metrics.throughputKbps.toStringAsFixed(0)} kbit/s'),
              if (metrics.lastError.isNotEmpty) KvRow(key_: 'last error', value: metrics.lastError),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.tonalIcon(
                  onPressed: () async {
                    await app.selectServer(r.serverId);
                    if (sheetContext.mounted) Navigator.pop(sheetContext);
                  },
                  icon: const Icon(Icons.push_pin_rounded, size: 16),
                  label: Text(l10n.t('label.selectedServer')),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    await app.unpin();
                    if (sheetContext.mounted) Navigator.pop(sheetContext);
                  },
                  icon: const Icon(Icons.link_rounded, size: 16),
                  label: Text(l10n.t('status.autoSelected')),
                ),
                OutlinedButton.icon(
                  onPressed: () {
                    app.probeOne(r.serverId);
                  },
                  icon: const Icon(Icons.speed_rounded, size: 16),
                  label: Text(l10n.t('action.probeAll')),
                ),
                if (node != null)
                  OutlinedButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: ShareLinkWriter.forNode(node)));
                      if (sheetContext.mounted) {
                        ScaffoldMessenger.of(sheetContext).showSnackBar(
                          SnackBar(content: Text(l10n.t('action.copyLink'))),
                        );
                      }
                    },
                    icon: const Icon(Icons.copy_rounded, size: 16),
                    label: Text(l10n.t('action.export')),
                  ),
                if (node != null)
                  OutlinedButton.icon(
                    onPressed: () => app.setServerEnabled(node.id, !node.enabled),
                    icon: Icon(node.enabled ? Icons.hide_image_rounded : Icons.visibility_rounded, size: 16),
                    label: Text(node.enabled ? 'disable' : 'enable'),
                  ),
              ],
            ),
            if (node != null) ...<Widget>[
              const SizedBox(height: 10),
              Text('${l10n.t('label.weights')} · ${l10n.t('hint.margin')}',
                  style: Theme.of(sheetContext).textTheme.labelSmall),
              Slider(
                value: node.weight.toDouble(),
                min: -100,
                max: 100,
                divisions: 20,
                label: '${node.weight}',
                onChanged: (v) => app.setServerWeight(node.id, v.round()),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

Future<void> _showAddNodeSheet(BuildContext context, AppState app, Profile profile) async {
  final l10n = NaxloLocalizations.of(context);
  final address = TextEditingController();
  final port = TextEditingController(text: '443');
  final secret = TextEditingController();
  final name = TextEditingController();
  var protocol = ProxyProtocol.vless;

  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext context) => Padding(
      padding: EdgeInsets.only(left: 20, right: 20, top: 4, bottom: MediaQuery.of(context).viewInsets.bottom + 20),
      child: StatefulBuilder(
        builder: (BuildContext context, StateSetter setSheetState) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(l10n.t('group.nodes'), style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            DropdownButtonFormField<ProxyProtocol>(
              value: protocol,
              decoration: InputDecoration(labelText: l10n.t('label.engine')),
              items: <DropdownMenuItem<ProxyProtocol>>[
                for (final p in ProxyProtocol.values)
                  DropdownMenuItem<ProxyProtocol>(value: p, child: Text(p.label)),
              ],
              onChanged: (v) => setSheetState(() => protocol = v ?? protocol),
            ),
            const SizedBox(height: 10),
            TextField(controller: name, decoration: const InputDecoration(labelText: 'name')),
            const SizedBox(height: 10),
            TextField(controller: address, decoration: const InputDecoration(labelText: 'address')),
            const SizedBox(height: 10),
            TextField(controller: port, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'port')),
            const SizedBox(height: 10),
            TextField(
              controller: secret,
              obscureText: true,
              decoration: InputDecoration(labelText: protocol.usesUuid ? 'uuid' : 'password'),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                if (address.text.trim().isEmpty) return;
                Navigator.pop(context, true);
              },
              child: Text(l10n.t('action.save')),
            ),
          ],
        ),
      ),
    ),
  );

  if (saved != true || !context.mounted) return;
  final node = ServerNode(
    id: 'n${DateTime.now().millisecondsSinceEpoch}',
    name: name.text.trim(),
    address: address.text.trim(),
    port: int.tryParse(port.text.trim()) ?? 443,
    protocol: protocol,
    userId: protocol.usesUuid ? secret.text.trim() : '',
    password: protocol.usesUuid ? '' : secret.text.trim(),
    tls: const TlsOptions(security: SecurityLayer.tls),
    transportOptions: const TransportOptions(transport: Transport.tcp, path: '/', host: ''),
  );
  await app.addServer(profile, node);
  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(node.displayName)));
}
