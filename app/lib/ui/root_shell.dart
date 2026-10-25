import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'home_page.dart';
import 'logs_page.dart';
import 'profiles_page.dart';
import 'routing_page.dart';
import 'servers_page.dart';
import 'settings_page.dart';

/// Adaptive shell: a navigation rail on wide windows, a bottom bar on phones.
///
/// The breakpoint is width-based rather than platform-based because a desktop
/// window dragged to half a screen is a narrow layout, and a tablet in
/// landscape is not a phone.
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;

  static const List<_Destination> _destinations = <_Destination>[
    _Destination('nav.connect', Icons.vpn_key_rounded, Icons.vpn_key),
    _Destination('nav.servers', Icons.leaderboard_rounded, Icons.leaderboard),
    _Destination('nav.profiles', Icons.folder_copy_outlined, Icons.folder_copy),
    _Destination('nav.routing', Icons.alt_route_rounded, Icons.alt_route),
    _Destination('nav.settings', Icons.tune_rounded, Icons.tune),
    _Destination('nav.logs', Icons.receipt_long_rounded, Icons.receipt_long),
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = NaxloLocalizations.of(context);
    final app = context.watch<AppState>();
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 720;

    final pages = <Widget>[
      const HomePage(),
      const ServersPage(),
      const ProfilesPage(),
      const RoutingPage(),
      const SettingsPage(),
      const LogsPage(),
    ];

    final body = AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: KeyedSubtree(key: ValueKey<int>(_index), child: pages[_index]),
    );

    if (!wide) {
      return Scaffold(
        body: Column(
          children: <Widget>[
            Expanded(child: body),
            _BottomBar(
              index: _index,
              destinations: _destinations,
              l10n: l10n,
              onSelected: (i) => setState(() => _index = i),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      body: Row(
        children: <Widget>[
          _SideNav(
            index: _index,
            destinations: _destinations,
            l10n: l10n,
            connected: app.isConnected,
            onSelected: (i) => setState(() => _index = i),
            compact: width < 980,
          ),
          const VerticalDivider(width: 1),
          Expanded(child: body),
        ],
      ),
    );
  }
}

class _Destination {
  const _Destination(this.labelKey, this.icon, this.selectedIcon);
  final String labelKey;
  final IconData icon;
  final IconData selectedIcon;
}

class _SideNav extends StatelessWidget {
  const _SideNav({
    required this.index,
    required this.destinations,
    required this.l10n,
    required this.onSelected,
    required this.connected,
    this.compact = false,
  });

  final int index;
  final List<_Destination> destinations;
  final NaxloLocalizations l10n;
  final ValueChanged<int> onSelected;
  final bool connected;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: compact ? 84 : 208,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 12, 16),
              child: Row(
                children: <Widget>[
                  _Logo(size: compact ? 24 : 30),
                  if (!compact) ...<Widget>[
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(l10n.t('app.name'), style: Theme.of(context).textTheme.titleMedium),
                          Text(
                            l10n.t('app.tagline'),
                            style: Theme.of(context).textTheme.labelSmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: destinations.length,
                itemBuilder: (BuildContext context, int i) {
                  final d = destinations[i];
                  final selected = i == index;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: ListTile(
                      selected: selected,
                      selectedTileColor: Theme.of(context).colorScheme.primary.withOpacity(0.14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      leading: Icon(selected ? d.selectedIcon : d.icon),
                      minLeadingWidth: 0,
                      horizontalPadding: compact ? 4 : 12,
                      title: compact
                          ? null
                          : Text(
                              l10n.t(d.labelKey),
                              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                            ),
                      trailing: (!compact && i == 0)
                          ? Icon(
                              connected ? Icons.circle : Icons.circle_outlined,
                              size: 10,
                              color: connected ? const Color(0xFF2FBF71) : null,
                            )
                          : null,
                      onTap: () => onSelected(i),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The app mark: two offset chevrons (a "two" that is also a routed packet).
class _Logo extends StatelessWidget {
  const _Logo({this.size = 30});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: <Color>[Color(0xFF7C4DFF), Color(0xFF22D3EE)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: Center(
        child: Icon(Icons.account_tree_rounded, size: size * 0.66, color: Colors.white),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.index,
    required this.destinations,
    required this.l10n,
    required this.onSelected,
  });

  final int index;
  final List<_Destination> destinations;
  final NaxloLocalizations l10n;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return NavigationBar(
      selectedIndex: index,
      onDestinationSelected: onSelected,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      destinations: <NavigationDestination>[
        for (final d in destinations)
          NavigationDestination(
            icon: Icon(d.icon),
            selectedIcon: Icon(d.selectedIcon),
            label: l10n.t(d.labelKey),
          ),
      ],
    );
  }
}
