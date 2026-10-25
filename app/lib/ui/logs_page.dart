import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../state/log_buffer.dart';
import '../theme/palette.dart';

/// Engine + ranker log tail.
///
/// This screen exists because "it doesn't connect" is unanswerable from a
/// spinner: the engine's own words ("tls: handshake failure", "udp port not
/// allowed", "invalid user") are what turn a support thread into a two-second
/// glance. Lines are colour-coded by the parser in [LogBuffer], not by a regex
/// here, so the Logs screen and any future file export agree.
class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  final ScrollController _scroll = ScrollController();
  bool _follow = true;
  bool _onlyWarnings = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _toBottom() {
    if (!_follow || !_scroll.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final l10n = NaxloLocalizations.of(context);
    final all = app.logs.lines;
    final lines = <LogLine>[
      for (final l in all)
        if (!_onlyWarnings || l.level == LogLevel.warn || l.level == LogLevel.error) l,
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.t('nav.logs')),
        actions: <Widget>[
          IconButton(
            tooltip: 'warnings only',
            onPressed: () => setState(() => _onlyWarnings = !_onlyWarnings),
            icon: Icon(_onlyWarnings ? Icons.filter_alt_rounded : Icons.filter_alt_outlined),
          ),
          IconButton(
            tooltip: 'follow',
            onPressed: () => setState(() => _follow = !_follow),
            icon: Icon(_follow ? Icons.vertical_align_bottom_rounded : Icons.pause_rounded),
          ),
          IconButton(
            tooltip: 'copy',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: app.logs.dump()));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('logs copied')));
              }
            },
            icon: const Icon(Icons.copy_rounded),
          ),
          IconButton(
            tooltip: 'clear',
            onPressed: () => setState(app.logs.clear),
            icon: const Icon(Icons.delete_sweep_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (app.rankingExplain.isNotEmpty)
            Material(
              color: Palette.ink3,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('ranker', style: Theme.of(context).textTheme.labelSmall),
                    for (final l in app.rankingExplain)
                      Text(l, style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5)),
                  ],
                ),
              ),
            ),
          Expanded(
            child: lines.isEmpty
                ? Center(child: Text(l10n.t('empty.noLogs'), style: Theme.of(context).textTheme.bodySmall))
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 20),
                    itemCount: lines.length,
                    itemBuilder: (BuildContext context, int i) {
                      _toBottom();
                      final l = lines[i];
                      final color = switch (l.level) {
                        LogLevel.error => Palette.rose,
                        LogLevel.warn => Palette.amber,
                        LogLevel.debug => Palette.mutedInk,
                        LogLevel.info => Theme.of(context).colorScheme.onSurface,
                      };
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1.5),
                        child: RichText(
                          text: TextSpan(
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, height: 1.35),
                            children: <InlineSpan>[
                              TextSpan(text: '${l.time} ', style: const TextStyle(color: Palette.mutedInk)),
                              TextSpan(text: '[${l.source}] ', style: TextStyle(color: color.withOpacity(0.8))),
                              TextSpan(text: l.text, style: TextStyle(color: color)),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
