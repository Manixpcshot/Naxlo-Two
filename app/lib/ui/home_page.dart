import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:naxlo_core/naxlo_core.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../theme/palette.dart';
import 'servers_page.dart';
import 'widgets.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final l10n = NaxloLocalizations.of(context);
    final profile = app.profile;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.t('nav.connect')),
        actions: <Widget>[
          IconButton(
            tooltip: l10n.t('action.probeAll'),
            onPressed: profile == null ? null : () => app.probeAll(),
            icon: const Icon(Icons.speed_rounded),
          ),
          IconButton(
            tooltip: l10n.t('action.checkUpdates'),
            onPressed: () => app.checkForUpdates(),
            icon: const Icon(Icons.system_update_alt_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: <Widget>[
          if (app.updateAvailable != null) const _UpdateBanner(),
          _StatusHero(status: app.status, detail: app.statusDetail),
          const SizedBox(height: 16),
          if (profile == null)
            Panel(
              child: EmptyState(
                title: l10n.t('empty.noProfiles'),
                icon: Icons.link_rounded,
                action: FilledButton.icon(
                  onPressed: () => _showImportDialog(context, app),
                  icon: const Icon(Icons.paste_rounded, size: 18),
                  label: Text(l10n.t('action.importLinks')),
                ),
              ),
            )
          else ...<Widget>[
            _ActiveNodeCard(app: app, l10n: l10n),
            const SizedBox(height: 16),
            _TrafficCard(app: app, l10n: l10n),
            const SizedBox(height: 16),
            _CandidatesPreview(app: app, l10n: l10n),
            const SizedBox(height: 16),
            _EngineCard(app: app, l10n: l10n),
          ],
        ],
      ),
      floatingActionButton: profile == null
          ? null
          : _ConnectButton(app: app, l10n: l10n),
    );
  }
}

Future<void> _showImportDialog(BuildContext context, AppState app) async {
  final l10n = NaxloLocalizations.of(context);
  final controller = TextEditingController();
  final imported = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text(l10n.t('action.importLinks')),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(l10n.t('hint.importLinks'), style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: 8,
              minLines: 4,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'vless://…'),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l10n.t('action.cancel'))),
        FilledButton(
          onPressed: () {
            if (controller.text.trim().isEmpty) return;
            Navigator.pop(context, true);
          },
          child: Text(l10n.t('action.save')),
        ),
      ],
    ),
  );
  if (imported != true || !context.mounted) return;
  final report = await app.importLinks(controller.text);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(report.summary)));
}

class _StatusHero extends StatelessWidget {
  const _StatusHero({required this.status, required this.detail});

  final TunnelStatus status;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final l10n = NaxloLocalizations.of(context);
    final theme = Theme.of(context);
    final (Color color, IconData icon, String label) = switch (status) {
      TunnelStatus.connected => (Palette.mint, Icons.shield_rounded, l10n.t('status.connected')),
      TunnelStatus.connecting => (Palette.cyan, Icons.sync_rounded, l10n.t('status.connecting')),
      TunnelStatus.failed => (Palette.rose, Icons.shield_outlined, l10n.t('status.error')),
      TunnelStatus.disconnected => (Palette.mutedInk, Icons.shield_outlined, l10n.t('status.disconnected')),
    };

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          colors: <Color>[color.withOpacity(0.20), color.withOpacity(0.05)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, color: color, size: 34),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(label, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                if (detail.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      detail,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ActiveNodeCard extends StatelessWidget {
  const _ActiveNodeCard({required this.app, required this.l10n});

  final AppState app;
  final NaxloLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final profile = app.profile!;
    final id = app.activeServerId;
    final node = id.isEmpty ? null : profile.byId(id);
    final rank = app.rankOf(id);
    if (node == null) {
      return Panel(
        child: Row(
          children: <Widget>[
            const Icon(Icons.help_outline_rounded, color: Palette.mutedInk),
            const SizedBox(width: 10),
            Expanded(child: Text(l10n.t('label.noData'), style: Theme.of(context).textTheme.bodyMedium)),
            TextButton(onPressed: () => app.probeAll(), child: Text(l10n.t('action.probeAll'))),
          ],
        ),
      );
    }

    final metrics = app.metricsOf(node.id);
    final pinned = profile.selectedServerId == node.id;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              RankBadge(rank: rank?.rank ?? 0, isCurrent: true),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(node.displayName, style: Theme.of(context).textTheme.titleMedium),
                    Text(
                      '${node.endpoint} · ${node.protocol.label} · ${node.transportOptions.transport.label}'
                      '${node.tls.security.wireName == 'none' ? '' : ' · ${node.tls.security.wireName}'}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
                    ),
                  ],
                ),
              ),
              if (metrics != null) HealthIcon(state: metrics.health),
              IconButton(
                tooltip: l10n.t('label.whyRanked'),
                onPressed: rank == null ? null : () => showRankingSheet(context, rank, app),
                icon: const Icon(Icons.info_outline_rounded, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ScoreBar(score: rank?.score ?? 0),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              LatencyChip(latencyMs: rank?.latencyMs ?? -1, jitterMs: rank?.jitterMs),
              // The *measurement*, not the ranking bound. `rank.reliability` is the
              // conservative lower bound we score on, which for a node with one good
              // probe reads "50%" under a green bar; the pill next to it already says
              // how much to trust the number, so the pair is rate + confidence.
              _MetricPill(
                label: l10n.t('label.reliability'),
                value: rank == null || !app.metricsOf(rank.serverId).hasSamples
                    ? '—'
                    : '${(app.metricsOf(rank.serverId).observedRate * 100).round()}%',
              ),
              _MetricPill(label: l10n.t('label.confidence'), value: rank == null ? '—' : '${(rank.confidence * 100).round()}%'),
              if (pinned)
                _MetricPill(label: '', value: l10n.t('status.pinned'), accent: Palette.amber, icon: Icons.push_pin_rounded),
              if (!pinned && profile.autoSelect)
                _MetricPill(label: '', value: l10n.t('status.autoSelected'), icon: Icons.auto_awesome_rounded),
            ],
          ),
          if (app.selectionReason.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                app.selectionReason,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
              ),
            ),
        ],
      ),
    );
  }
}

class _MetricPill extends StatelessWidget {
  const _MetricPill({required this.label, required this.value, this.accent, this.icon});

  final String label;
  final String value;
  final Color? accent;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = accent ?? theme.colorScheme.onSurface;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[Icon(icon, size: 13, color: color), const SizedBox(width: 5)],
          if (label.isNotEmpty)
            Text('$label ', style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
          Text(value, style: theme.textTheme.labelMedium?.copyWith(color: color, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _TrafficCard extends StatelessWidget {
  const _TrafficCard({required this.app, required this.l10n});

  final AppState app;
  final NaxloLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Panel(
      child: Row(
        children: <Widget>[
          Expanded(
            child: KvColumn(rows: <Widget>[
              KvRow(key_: '↑', value: _bytes(app.uplinkBytes)),
              KvRow(key_: '↓', value: _bytes(app.downlinkBytes)),
              KvRow(key_: l10n.t('label.throughput'), value: '${app.throughputKbps.toStringAsFixed(0)} kbit/s'),
              KvRow(
                key_: '≈',
                value: app.isConnected ? 'estimated from engine log' : 'idle',
                hint: '',
              ),
            ]),
          ),
          const SizedBox(width: 12),
          Sparkline(
            points: app.engine.traffic.totalBytes,
            active: app.isConnected,
            color: theme.colorScheme.secondary,
          ),
        ],
      ),
    );
  }

  static String _bytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KiB';
    if (b < 1024 * 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(1)} MiB';
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB';
  }
}

/// Minimal sparkline: a painted polyline, no chart package.
class Sparkline extends StatelessWidget {
  const Sparkline({required this.points, required this.active, required this.color, super.key});

  final int points;
  final bool active;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 108,
      height: 44,
      child: CustomPaint(
        painter: _SparkPainter(active: active, color: color, level: points),
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter({required this.active, required this.color, required this.level});

  final bool active;
  final Color color;
  final int level;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = active ? color : Palette.mutedInk.withOpacity(0.5)
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final height = size.height;
    final norm = active ? (level % 100) / 100.0 : 0.0;
    final dy = height - (height * 0.15 + norm * height * 0.7);
    final path = Path()
      ..moveTo(0, height * 0.8)
      ..lineTo(size.width * 0.3, height * 0.55)
      ..lineTo(size.width * 0.62, dy)
      ..lineTo(size.width, height * 0.45);
    canvas.drawPath(path, line);
  }

  @override
  bool shouldRepaint(_SparkPainter old) => old.level != level || old.active != active;
}

class KvColumn extends StatelessWidget {
  const KvColumn({required this.rows, super.key});

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
}

class _CandidatesPreview extends StatelessWidget {
  const _CandidatesPreview({required this.app, required this.l10n});

  final AppState app;
  final NaxloLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final ranked = app.ranked.where((r) => r.isEligible).take(4).toList();
    if (ranked.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Section(
      title: l10n.t('nav.servers'),
      subtitle: l10n.t(app.ranking.mode == RankingMode.advanced
          ? 'label.rankModeAdvanced'
          : 'label.rankModeSimple'),
      trailing: TextButton(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const _ServersOverlay()),
        ),
        child: const Text('all'),
      ),
      child: Panel(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          children: <Widget>[
            for (final r in ranked)
              ListTile(
                dense: true,
                leading: RankBadge(rank: r.rank, isCurrent: r.isCurrent),
                title: Text(
                  app.profile?.byId(r.serverId)?.displayName ?? r.serverId,
                  style: theme.textTheme.bodyMedium,
                ),
                subtitle: Text(r.summary, style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
                trailing: SizedBox(width: 96, child: ScoreBar(score: r.score, showValue: true)),
                onTap: () => showRankingSheet(context, r, app),
              ),
          ],
        ),
      ),
    );
  }
}

class _ServersOverlay extends StatelessWidget {
  const _ServersOverlay();

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(),
        body: const ServersPage(),
      );
}

class _EngineCard extends StatelessWidget {
  const _EngineCard({required this.app, required this.l10n});

  final AppState app;
  final NaxloLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = app.profile;
    final engine = profile?.engine ?? EngineKind.xray;
    return Section(
      title: l10n.t('group.diagnostics'),
      child: Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            KvRow(key_: l10n.t('label.engine'), value: engine.label),
            KvRow(key_: 'PID', value: app.engine.pid?.toString() ?? '—'),
            KvRow(key_: l10n.t('label.portSocks'), value: '${app.settings.socksPort}'),
            KvRow(key_: l10n.t('label.proxyMode'), value: app.settings.proxyMode.label),
            KvRow(key_: 'config', value: app.engine.activeConfigPath ?? '—'),
            if (app.engine.lastFailure != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  app.engine.lastFailure!,
                  style: theme.textTheme.bodySmall?.copyWith(color: Palette.rose),
                ),
              ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: app.logs.dump()));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('logs copied')));
                },
                icon: const Icon(Icons.copy_rounded, size: 16),
                label: const Text('copy logs'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectButton extends StatelessWidget {
  const _ConnectButton({required this.app, required this.l10n});

  final AppState app;
  final NaxloLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    if (app.isBusy) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.4)),
      );
    }
    final connected = app.isConnected;
    return FloatingActionButton.extended(
      onPressed: () => connected ? app.disconnect() : app.connect(),
      icon: Icon(connected ? Icons.link_off_rounded : Icons.link_rounded),
      label: Text(connected ? l10n.t('action.disconnect') : l10n.t('action.connect')),
    );
  }
}

class _UpdateBanner extends StatelessWidget {
  const _UpdateBanner();

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final decision = app.updateAvailable;
    if (decision == null) return const SizedBox.shrink();
    final l10n = NaxloLocalizations.of(context);
    final blocking = decision.isBlocking;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Panel(
        child: Row(
          children: <Widget>[
            Icon(
              blocking ? Icons.priority_high_rounded : Icons.system_update_alt_rounded,
              color: blocking ? Palette.rose : Palette.cyan,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    blocking ? l10n.t('label.updateForced') : '${l10n.t('label.updateAvailable')} ${decision.available}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  if (decision.details.isNotEmpty)
                    Text(decision.details, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: decision.downloadUrl));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('download URL copied — open it in your browser')),
                );
              },
              child: const Text('get'),
            ),
          ],
        ),
      ),
    );
  }
}
