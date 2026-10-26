import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../theme/palette.dart';
import 'home_page.dart';
import 'logs_page.dart';
import 'motion.dart';
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

  /// Which way to push the outgoing page. Without it a jump from Logs back to
  /// Connect slides right, the same as every forward move, and the rail stops
  /// meaning "deeper" versus "up".
  int _direction = 1;

  static const List<_Destination> _destinations = <_Destination>[
    _Destination('nav.connect', Icons.vpn_key_rounded, Icons.vpn_key),
    _Destination('nav.servers', Icons.leaderboard_rounded, Icons.leaderboard),
    _Destination('nav.profiles', Icons.folder_copy_outlined, Icons.folder_copy),
    _Destination('nav.routing', Icons.alt_route_rounded, Icons.alt_route),
    _Destination('nav.settings', Icons.tune_rounded, Icons.tune),
    _Destination('nav.logs', Icons.receipt_long_rounded, Icons.receipt_long),
  ];

  void _select(int next) {
    if (next == _index) return;
    setState(() {
      _direction = next > _index ? 1 : -1;
      _index = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final NaxloLocalizations l10n = NaxloLocalizations.of(context);
    final AppState app = context.watch<AppState>();
    final double width = MediaQuery.sizeOf(context).width;
    final bool wide = width >= 720;

    final List<Widget> pages = <Widget>[
      const HomePage(),
      const ServersPage(),
      const ProfilesPage(),
      const RoutingPage(),
      const SettingsPage(),
      const LogsPage(),
    ];

    final Duration swap = Motion.time(context, const Duration(milliseconds: 260));
    final Widget body = AnimatedSwitcher(
      duration: swap,
      switchInCurve: Motion.enter,
      switchOutCurve: Motion.leave,
      transitionBuilder: (Widget child, Animation<double> animation) {
        if (swap == Duration.zero) return FadeTransition(opacity: animation, child: child);
        return FadeTransition(
          opacity: animation,
          // A 3% slide, not a full-width push: the pages share most of their
          // chrome, and sliding the whole surface makes a tab change look like a
          // navigation the user did not perform.
          child: SlideTransition(
            position: Tween<Offset>(begin: Offset(0.03 * _direction, 0), end: Offset.zero)
                .animate(CurvedAnimation(parent: animation, curve: Motion.enter)),
            child: child,
          ),
        );
      },
      child: KeyedSubtree(key: ValueKey<int>(_index), child: pages[_index]),
    );

    if (!wide) {
      return Scaffold(
        body: Column(
          children: <Widget>[
            Expanded(child: body),
            _BottomBar(index: _index, destinations: _destinations, l10n: l10n, onSelected: _select),
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
            onSelected: _select,
            compact: width < 980,
          ),
          const _Hairline(),
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

/// The rail's right edge. A gradient that fades out reads as depth; the
/// `VerticalDivider` it replaces read as a table.
class _Hairline extends StatelessWidget {
  const _Hairline();

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: 1,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Palette.violet.withOpacity(dark ? 0.34 : 0.18),
            Palette.hairline.withOpacity(0.35),
            Colors.transparent,
          ],
          stops: const <double>[0, 0.42, 1],
        ),
      ),
    );
  }
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
    final ThemeData theme = Theme.of(context);
    final bool dark = theme.brightness == Brightness.dark;
    return Container(
      width: compact ? 88 : 216,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            (dark ? Palette.ink2 : Palette.paperRaised).withOpacity(dark ? 0.9 : 0.6),
            dark ? Palette.ink0 : Palette.paper,
          ],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 12, 18),
              child: Row(
                children: <Widget>[
                  _Logo(size: compact ? 26 : 32, alive: connected),
                  if (!compact) ...<Widget>[
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(l10n.t('app.name'), style: theme.textTheme.titleMedium),
                          Text(
                            l10n.t('app.tagline'),
                            style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
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
                  final _Destination d = destinations[i];
                  final bool selected = i == index;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: FadeSlideIn(
                      delay: Motion.cascade(i, lead: const Duration(milliseconds: 60)),
                      offset: const Offset(-12, 0),
                      duration: Motion.quick,
                      child: ListTile(
                        // Tests and automation need a stable handle: the label is a
                        // translated string, and half the suite runs under fa-IR where
                        // "Servers" does not exist. Keys survive both.
                        key: ValueKey<String>('rail-${d.labelKey}'),
                        selected: selected,
                        selectedTileColor: theme.colorScheme.primary.withOpacity(0.13),
                        hoverColor: theme.colorScheme.primary.withOpacity(0.07),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
                        leading: _RailMark(
                          icon: selected ? d.selectedIcon : d.icon,
                          selected: selected,
                        ),
                        minLeadingWidth: 0,
                        contentPadding: EdgeInsets.symmetric(horizontal: compact ? 4 : 12),
                        title: compact
                            ? null
                            : Text(
                                l10n.t(d.labelKey),
                                style: TextStyle(
                                  fontSize: 13.5,
                                  height: 1.15,
                                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                                  letterSpacing: -0.1,
                                  color: selected ? null : theme.textTheme.bodyMedium?.color?.withOpacity(0.82),
                                ),
                              ),
                        trailing: i == 0
                            ? _LiveDot(connected: connected)
                            : AnimatedOpacity(
                                opacity: selected ? 1 : 0,
                                duration: Motion.time(context, Motion.quick),
                                child: Icon(
                                  Icons.chevron_right_rounded,
                                  size: 16,
                                  color: theme.colorScheme.primary.withOpacity(0.75),
                                ),
                              ),
                        onTap: () => onSelected(i),
                      ),
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

/// Rail icon: a plain glyph when idle, a lit chip when selected.
class _RailMark extends StatelessWidget {
  const _RailMark({required this.icon, required this.selected});

  final IconData icon;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return AnimatedContainer(
      duration: Motion.time(context, Motion.base),
      curve: Motion.enter,
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(11),
        gradient: selected ? Palette.accentGradient : null,
        boxShadow: <BoxShadow>[
          if (selected)
            BoxShadow(
              color: theme.colorScheme.primary.withOpacity(0.45),
              blurRadius: 16,
              spreadRadius: -4,
            ),
        ],
      ),
      child: AnimatedSwitcher(
        duration: Motion.time(context, Motion.quick),
        transitionBuilder: (Widget child, Animation<double> animation) => ScaleTransition(
          scale: Tween<double>(begin: 0.82, end: 1).animate(
            CurvedAnimation(parent: animation, curve: Motion.press),
          ),
          child: FadeTransition(opacity: animation, child: child),
        ),
        // The icon id is the key, so swapping outline->filled cross-fades while a
        // selection change *between two items* does not re-animate this one.
        child: Icon(
          icon,
          key: ValueKey<IconData>(icon),
          size: 18,
          color: selected ? Colors.white : theme.iconTheme.color,
        ),
      ),
    );
  }
}

/// The connection light. It breathes only while the tunnel is actually up — a
/// pulsing dot that means nothing is the fastest way to train people to ignore
/// the one signal that matters.
class _LiveDot extends StatelessWidget {
  const _LiveDot({required this.connected});

  final bool connected;

  @override
  Widget build(BuildContext context) {
    return LivePulse(
      active: connected,
      period: const Duration(milliseconds: 2200),
      builder: (BuildContext context, double t) {
        final Color colour = Palette.mint;
        return Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: connected ? colour : Palette.mutedInk.withOpacity(0.6),
            boxShadow: <BoxShadow>[
              if (connected)
                BoxShadow(
                  color: colour.withOpacity(0.50 - 0.30 * t),
                  blurRadius: 6 + 10 * t,
                  spreadRadius: 0.5 + 1.5 * t,
                ),
            ],
          ),
        );
      },
    );
  }
}

/// The app mark: two offset chevrons (a "two" that is also a routed packet).
class _Logo extends StatelessWidget {
  const _Logo({this.size = 30, this.alive = false});

  final double size;
  final bool alive;

  @override
  Widget build(BuildContext context) {
    return LivePulse(
      active: alive,
      period: const Duration(milliseconds: 2600),
      builder: (BuildContext context, double t) {
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            gradient: Palette.accentGradient,
            borderRadius: BorderRadius.circular(size * 0.3),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Palette.violet.withOpacity(alive ? 0.34 + 0.22 * t : 0.22),
                blurRadius: alive ? 16 + 12 * t : 12,
                spreadRadius: -2,
              ),
            ],
          ),
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              // The mark itself drifts a pixel against the glow while connected, so
              // the only thing that moves in a resting app is the thing that says
              // "traffic is flowing".
              Transform.translate(
                offset: Offset(alive ? -1.2 * (t - 0.5) * 2 : 0, 0),
                child: Icon(Icons.account_tree_rounded, size: size * 0.64, color: Colors.white),
              ),
            ],
          ),
        );
      },
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
    final ThemeData theme = Theme.of(context);
    return Material(
      color: theme.scaffoldBackgroundColor,
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(6, 0, 6, 6),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Palette.hairline.withOpacity(0.6)),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                theme.colorScheme.primary.withOpacity(0.08),
                Colors.transparent,
              ],
            ),
          ),
          child: NavigationBar(
            selectedIndex: index,
            onDestinationSelected: onSelected,
            elevation: 0,
            height: 66,
            indicatorColor: theme.colorScheme.primary.withOpacity(0.20),
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            destinations: <NavigationDestination>[
              for (final _Destination d in destinations)
                NavigationDestination(
                  icon: Icon(d.icon),
                  selectedIcon: Icon(d.selectedIcon),
                  label: l10n.t(d.labelKey),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
