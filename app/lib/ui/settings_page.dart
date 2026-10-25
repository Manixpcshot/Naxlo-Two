import 'package:flutter/material.dart';
import 'package:naxlo_core/naxlo_core.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../theme/palette.dart';
import '../version_info.dart';
import 'widgets.dart';

/// Settings, ordered the way a user actually needs it: what is running now,
/// then the knobs that change today's behaviour, then the ranking tuning, then
/// the boring diagnostics at the bottom.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final l10n = NaxloLocalizations.of(context);
    final s = app.settings;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('nav.settings'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: <Widget>[
          Section(
            title: l10n.t('group.profile'),
            child: Panel(
              child: Column(
                children: <Widget>[
                  _SegmentedRow<EngineKind>(
                    label: l10n.t('label.engine'),
                    value: app.profile?.engine ?? EngineKind.xray,
                    values: EngineKind.values,
                    labelOf: (e) => e.label,
                    onChanged: (e) async {
                      final p = app.profile;
                      if (p == null) return;
                      await app.replaceProfile(p.copyWith(engine: e));
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.t('label.autoSelect')),
                    value: app.profile?.autoSelect ?? true,
                    onChanged: app.setAutoSelect,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.t('label.killSwitch')),
                    subtitle: Text(l10n.t('hint.killSwitch'), style: Theme.of(context).textTheme.bodySmall),
                    value: s.killSwitch,
                    onChanged: (v) => app.updateSettings(s.copyWith(killSwitch: v)),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('probe while connected'),
                    value: s.probeWhileConnected,
                    onChanged: (v) => app.updateSettings(s.copyWith(probeWhileConnected: v)),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('connect on launch'),
                    value: s.autoConnectOnLaunch,
                    onChanged: (v) => app.updateSettings(s.copyWith(autoConnectOnLaunch: v)),
                  ),
                ],
              ),
            ),
          ),
          Section(
            title: l10n.t('label.proxyMode'),
            subtitle: switch (s.proxyMode) {
              ProxyMode.manual => l10n.t('hint.proxyMode.manual'),
              ProxyMode.systemProxy => l10n.t('hint.proxyMode.system'),
              ProxyMode.tun => l10n.t('hint.proxyMode.tun'),
            },
            child: Panel(
              child: Column(
                children: <Widget>[
                  _SegmentedRow<ProxyMode>(
                    label: '',
                    value: s.proxyMode,
                    values: ProxyMode.values,
                    labelOf: (m) => m.label,
                    onChanged: (m) => app.updateSettings(s.copyWith(proxyMode: m)),
                  ),
                  const SizedBox(height: 8),
                  _PortField(
                    label: l10n.t('label.portSocks'),
                    value: s.socksPort,
                    enabled: s.enableSocksInbound,
                    onChanged: (v) => app.updateSettings(s.copyWith(socksPort: v)),
                  ),
                  _PortField(
                    label: l10n.t('label.portHttp'),
                    value: s.httpPort,
                    enabled: s.enableHttpInbound,
                    onChanged: (v) => app.updateSettings(s.copyWith(httpPort: v)),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('SOCKS inbound'),
                    value: s.enableSocksInbound,
                    onChanged: (v) => app.updateSettings(s.copyWith(enableSocksInbound: v)),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('HTTP inbound'),
                    value: s.enableHttpInbound,
                    onChanged: (v) => app.updateSettings(s.copyWith(enableHttpInbound: v)),
                  ),
                ],
              ),
            ),
          ),
          _RankingSection(app: app, l10n: l10n),
          Section(
            title: l10n.t('group.diagnostics'),
            child: Panel(
              child: Column(
                children: <Widget>[
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.system_update_alt_rounded),
                    title: Text(l10n.t('label.checkUpdates')),
                    subtitle: Text(
                      app.updater.lastError ??
                          (app.updater.lastCheckAt == null
                              ? l10n.t('action.checkUpdates')
                              : 'last check ${_ago(app.updater.lastCheckAt!)}'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () async {
                      await app.checkForUpdates();
                      if (!context.mounted) return;
                      final d = app.updateAvailable;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(d == null ? 'up to date (${kAppVersion})' : '${d.available}: ${d.reason}')),
                      );
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.t('label.checkUpdates')),
                    value: s.checkForUpdates,
                    onChanged: (v) => app.updateSettings(s.copyWith(checkForUpdates: v)),
                  ),
                  _DropdownRow<String>(
                    label: l10n.t('label.language'),
                    value: s.locale.isEmpty ? 'system' : s.locale,
                    values: const <String>['system', 'en', 'fa', 'ru', 'ar'],
                    labelOf: (v) => switch (v) {
                      'system' => 'system',
                      'en' => 'English',
                      'fa' => 'فارسی',
                      'ru' => 'Русский',
                      _ => 'العربية',
                    },
                    onChanged: (v) => app.updateSettings(s.copyWith(locale: v == 'system' ? '' : v)),
                  ),
                  _DropdownRow<String>(
                    label: l10n.t('label.theme'),
                    value: s.themeMode,
                    values: const <String>['system', 'light', 'dark', 'black'],
                    labelOf: (v) => v,
                    onChanged: (v) => app.updateSettings(s.copyWith(themeMode: v)),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('verbose generated config in logs'),
                    value: s.developerVerboseConfig,
                    onChanged: (v) => app.updateSettings(s.copyWith(developerVerboseConfig: v)),
                  ),
                ],
              ),
            ),
          ),
          Section(
            title: l10n.t('about.title'),
            child: Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  KvRow(key_: 'version', value: kAppVersion),
                  KvRow(key_: 'core', value: kNaxloVersion == kAppVersion ? 'bundled' : kNaxloVersion),
                  KvRow(key_: 'engine', value: app.engine.pid == null ? 'stopped' : 'pid ${app.engine.pid}'),
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(l10n.t('about.privacy'), style: Theme.of(context).textTheme.bodySmall),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(l10n.t('about.license'), style: Theme.of(context).textTheme.bodySmall),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      l10n.t('about.disclaimer'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Palette.amber),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    return '${d.inHours}h ago';
  }
}

class _RankingSection extends StatelessWidget {
  const _RankingSection({required this.app, required this.l10n});

  final AppState app;
  final NaxloLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final cfg = app.ranking;
    final w = cfg.weights;
    final total = w.sum;
    return Section(
      title: l10n.t('label.rankMode'),
      subtitle: l10n.t('hint.rankMode'),
      child: Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SegmentedButton<RankingMode>(
              segments: <ButtonSegment<RankingMode>>[
                for (final m in RankingMode.values)
                  ButtonSegment<RankingMode>(value: m, label: Text(l10n.t(m == RankingMode.advanced ? 'label.rankModeAdvanced' : 'label.rankModeSimple'))),
              ],
              selected: <RankingMode>{cfg.mode},
              showSelectedIcon: false,
              onSelectionChanged: (sel) => app.updateRanking(cfg.copyWith(mode: sel.first)),
            ),
            const SizedBox(height: 14),
            Row(
              children: <Widget>[
                Text(l10n.t('label.preset'), style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(width: 8),
                for (final name in const <String>['balanced', 'speed', 'stability'])
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 6),
                    child: ActionChip(
                      label: Text(name),
                      onPressed: () => app.applyWeightsPreset(name),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(l10n.t('label.weights'), style: Theme.of(context).textTheme.titleSmall),
            Text(l10n.t('hint.weights'), style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            WeightSlider(
              label: l10n.t('label.latency'),
              value: w.latency,
              totalWeight: total,
              onChanged: (v) => app.updateRanking(cfg.copyWith(weights: w.copyWith(latency: v))),
            ),
            WeightSlider(
              label: l10n.t('label.jitter'),
              value: w.jitter,
              totalWeight: total,
              onChanged: (v) => app.updateRanking(cfg.copyWith(weights: w.copyWith(jitter: v))),
            ),
            WeightSlider(
              label: l10n.t('label.reliability'),
              value: w.reliability,
              totalWeight: total,
              onChanged: (v) => app.updateRanking(cfg.copyWith(weights: w.copyWith(reliability: v))),
            ),
            WeightSlider(
              label: l10n.t('label.throughput'),
              value: w.throughput,
              totalWeight: total,
              onChanged: (v) => app.updateRanking(cfg.copyWith(weights: w.copyWith(throughput: v))),
            ),
            WeightSlider(
              label: 'freshness',
              value: w.freshness,
              totalWeight: total,
              onChanged: (v) => app.updateRanking(cfg.copyWith(weights: w.copyWith(freshness: v))),
            ),
            WeightSlider(
              label: 'stability',
              value: w.stability,
              totalWeight: total,
              onChanged: (v) => app.updateRanking(cfg.copyWith(weights: w.copyWith(stability: v))),
            ),
            WeightSlider(
              label: 'stickiness',
              value: w.stickiness,
              totalWeight: total,
              onChanged: (v) => app.updateRanking(cfg.copyWith(weights: w.copyWith(stickiness: v))),
            ),
            const Divider(height: 24),
            _NumberRow(
              label: l10n.t('label.halfLife'),
              value: cfg.halfLifeMs / 1000.0,
              unit: l10n.t('unit.sec'),
              min: 5,
              max: 900,
              onChanged: (v) => app.updateRanking(cfg.copyWith(halfLifeMs: (v * 1000).round())),
            ),
            _NumberRow(
              label: l10n.t('label.switchMargin'),
              value: cfg.switchMargin * 100,
              unit: '%',
              min: 0,
              max: 30,
              onChanged: (v) => app.updateRanking(cfg.copyWith(switchMargin: v / 100.0)),
            ),
            _NumberRow(
              label: l10n.t('label.dwell'),
              value: cfg.dwellMs / 1000.0,
              unit: l10n.t('unit.sec'),
              min: 0,
              max: 300,
              onChanged: (v) => app.updateRanking(cfg.copyWith(dwellMs: (v * 1000).round())),
            ),
            _NumberRow(
              label: l10n.t('label.cooldown'),
              value: cfg.cooldownMs / 60000.0,
              unit: l10n.t('unit.min'),
              min: 0,
              max: 30,
              onChanged: (v) => app.updateRanking(cfg.copyWith(cooldownMs: (v * 60000).round())),
            ),
            _NumberRow(
              label: l10n.t('label.exploration'),
              value: cfg.exploration,
              unit: '',
              min: 0,
              max: 1,
              onChanged: (v) => app.updateRanking(cfg.copyWith(exploration: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('spread load across near-tied nodes'),
              value: cfg.loadSpread,
              onChanged: (v) => app.updateRanking(cfg.copyWith(loadSpread: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('exclude unreachable nodes'),
              value: cfg.penalizeDown,
              onChanged: (v) => app.updateRanking(cfg.copyWith(penalizeDown: v)),
            ),
          ],
        ),
      ),
    );
  }
}

class _NumberRow extends StatelessWidget {
  const _NumberRow({
    required this.label,
    required this.value,
    required this.unit,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final double value;
  final String unit;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: <Widget>[
          SizedBox(width: 110, child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 74,
            child: Text(
              '${value.toStringAsFixed(value < 10 && unit.isEmpty ? 2 : 0)} $unit'.trim(),
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _SegmentedRow<T> extends StatelessWidget {
  const _SegmentedRow({
    required this.label,
    required this.value,
    required this.values,
    required this.labelOf,
    required this.onChanged,
  });

  final String label;
  final T value;
  final List<T> values;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (label.isNotEmpty) ...<Widget>[
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 6),
        ],
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: SegmentedButton<T>(
            segments: <ButtonSegment<T>>[
              for (final v in values) ButtonSegment<T>(value: v, label: Text(labelOf(v))),
            ],
            selected: <T>{value},
            showSelectedIcon: false,
            onSelectionChanged: (sel) => onChanged(sel.first),
          ),
        ),
      ],
    );
  }
}

class _DropdownRow<T> extends StatelessWidget {
  const _DropdownRow({
    required this.label,
    required this.value,
    required this.values,
    required this.labelOf,
    required this.onChanged,
  });

  final String label;
  final T value;
  final List<T> values;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      trailing: DropdownButton<T>(
        value: value,
        underline: const SizedBox.shrink(),
        items: <DropdownMenuItem<T>>[
          for (final v in values) DropdownMenuItem<T>(value: v, child: Text(labelOf(v))),
        ],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }
}

class _PortField extends StatefulWidget {
  const _PortField({required this.label, required this.value, required this.enabled, required this.onChanged});

  final String label;
  final int value;
  final bool enabled;
  final ValueChanged<int> onChanged;

  @override
  State<_PortField> createState() => _PortFieldState();
}

class _PortFieldState extends State<_PortField> {
  late final TextEditingController _controller = TextEditingController(text: '${widget.value}');

  @override
  void didUpdateWidget(_PortField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) _controller.text = '${widget.value}';
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          SizedBox(width: 130, child: Text(widget.label, style: Theme.of(context).textTheme.bodyMedium)),
          Expanded(
            child: TextField(
              controller: _controller,
              enabled: widget.enabled,
              keyboardType: TextInputType.number,
              onSubmitted: (v) {
                final parsed = int.tryParse(v.trim());
                if (parsed != null && parsed > 0 && parsed < 65536) widget.onChanged(parsed);
              },
              decoration: const InputDecoration(isDense: true),
            ),
          ),
        ],
      ),
    );
  }
}
