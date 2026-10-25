import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:naxlo_core/naxlo_core.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../theme/palette.dart';
import 'widgets.dart';

/// Profile management: switch, import, refresh, export, delete.
///
/// Export writes the *whole* profile (nodes + routing + DNS) as JSON rather than
/// only share links, because share links cannot express routing rules — and a
/// backup that silently loses half the configuration is worse than none.
class ProfilesPage extends StatelessWidget {
  const ProfilesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final l10n = NaxloLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.t('nav.profiles')),
        actions: <Widget>[
          IconButton(
            tooltip: l10n.t('action.addProfile'),
            onPressed: () => app.addProfile(''),
            icon: const Icon(Icons.add_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: app.profiles.isEmpty
          ? EmptyState(
              title: l10n.t('empty.noProfiles'),
              icon: Icons.folder_copy_outlined,
              action: FilledButton(
                onPressed: () => app.addProfile(''),
                child: Text(l10n.t('action.addProfile')),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: <Widget>[
                for (final p in app.profiles) _ProfileCard(profile: p, app: app, l10n: l10n),
              ],
            ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.profile, required this.app, required this.l10n});

  final Profile profile;
  final AppState app;
  final NaxloLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final active = app.profile?.id == profile.id;
    final sub = profile.subscription;
    final healthy = profile.candidates.where((s) => app.metricsOf(s.id)?.health == HealthState.healthy).length;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Panel(
        onTap: active ? null : () => app.activateProfile(profile.id),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  active ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                  color: active ? app.themeMode == ThemeMode.dark ? Palette.cyan : null : Palette.mutedInk,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    profile.name,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                Text(profile.engine.cliName, style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: <Widget>[
                _Stat(label: 'nodes', value: '${profile.servers.length}'),
                _Stat(label: 'eligible', value: '${profile.candidates.length}'),
                _Stat(label: 'healthy', value: '$healthy'),
                if (sub != null) _Stat(label: 'updated', value: _ago(sub.lastFetchAtMs)),
              ],
            ),
            if (sub != null && sub.hasQuota) ...<Widget>[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: sub.usageRatio,
                  minHeight: 5,
                  backgroundColor: Palette.scoreTrack,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    sub.usageRatio > 0.9 ? Palette.rose : Palette.cyan,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${_bytes(sub.bytesUsed)} / ${_bytes(sub.bytesQuota)}'
                '${sub.hasExpiry ? ' · expires ${DateTime.fromMillisecondsSinceEpoch(sub.expiresAtMs).toIso8601String().substring(0, 10)}' : ''}',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).hintColor),
              ),
            ],
            if (sub != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  sub.url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Palette.mutedInk),
                ),
              ),
            const Divider(height: 22),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                _MiniButton(
                  label: l10n.t('action.importLinks'),
                  icon: Icons.paste_rounded,
                  onTap: () => _import(context),
                ),
                if (sub != null)
                  _MiniButton(
                    label: l10n.t('action.refreshSubscription'),
                    icon: Icons.refresh_rounded,
                    onTap: () async {
                      final report = await app.refreshSubscription(force: true);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(report.summary)));
                      }
                    },
                  ),
                if (sub == null)
                  _MiniButton(
                    label: 'attach subscription',
                    icon: Icons.link_rounded,
                    onTap: () => _attachSubscription(context),
                  ),
                _MiniButton(
                  label: l10n.t('action.export'),
                  icon: Icons.ios_share_rounded,
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: const _PrettyJson().encode(profile)));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('profile JSON copied')),
                      );
                    }
                  },
                ),
                _MiniButton(
                  label: l10n.t('action.delete'),
                  icon: Icons.delete_outline_rounded,
                  danger: true,
                  onTap: () async {
                    final yes = await showDialog<bool>(
                      context: context,
                      builder: (BuildContext context) => AlertDialog(
                        content: Text(l10n.t('confirm.deleteProfile')),
                        actions: <Widget>[
                          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l10n.t('action.cancel'))),
                          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l10n.t('action.delete'))),
                        ],
                      ),
                    );
                    if (yes == true) await app.deleteProfile(profile.id);
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _import(BuildContext context) async {
    final controller = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(l10n.t('action.importLinks')),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: controller,
            maxLines: 10,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'vless://… or a subscription URL'),
          ),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l10n.t('action.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l10n.t('action.save'))),
        ],
      ),
    );
    if (go != true) return;
    final text = controller.text.trim();
    if (text.isEmpty || !context.mounted) return;
    if (text.startsWith('http://') || text.startsWith('https://')) {
      await app.attachSubscription(text);
      final report = await app.refreshSubscription(force: true);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(report.summary)));
      }
      return;
    }
    final report = await app.importLinks(text, intoProfileId: profile.id);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(report.summary)));
    }
  }

  Future<void> _attachSubscription(BuildContext context) async {
    final controller = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('subscription URL'),
        content: SizedBox(width: 460, child: TextField(controller: controller, autofocus: true)),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l10n.t('action.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l10n.t('action.save'))),
        ],
      ),
    );
    if (go != true || controller.text.trim().isEmpty) return;
    await app.attachSubscription(controller.text.trim());
    if (!context.mounted) return;
    final report = await app.refreshSubscription(force: true);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(report.summary)));
    }
  }

  static String _ago(int ms) {
    if (ms <= 0) return 'never';
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (d.inMinutes < 1) return 'now';
    if (d.inHours < 24) return '${d.inHours}h';
    return '${d.inDays}d';
  }

  static String _bytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1048576) return '${(b / 1024).toStringAsFixed(0)} KiB';
    if (b < 1073741824) return '${(b / 1048576).toStringAsFixed(0)} MiB';
    return '${(b / 1073741824).toStringAsFixed(2)} GiB';
  }
}

/// Pretty-prints a profile for the clipboard.
class _PrettyJson {
  const _PrettyJson();

  String encode(Profile p) => const JsonEncoder.withIndent('  ').convert(p.toJson());
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Palette.scoreTrack,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text('$label $value', style: Theme.of(context).textTheme.labelSmall),
      );
}

class _MiniButton extends StatelessWidget {
  const _MiniButton({required this.label, required this.icon, required this.onTap, this.danger = false});

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? Palette.rose : Theme.of(context).colorScheme.onSurface;
    return ActionChip(
      avatar: Icon(icon, size: 15, color: color),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      onPressed: onTap,
    );
  }
}
