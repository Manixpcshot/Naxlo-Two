import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'l10n/strings.dart';
import 'state/app_state.dart';
import 'theme/app_theme.dart';
import 'ui/root_shell.dart';

/// The MaterialApp shell: theme, locale plumbing and the single AppState.
///
/// RTL is not an afterthought here — Persian and Arabic are first-class locales
/// for this kind of tool, so `flutter_localizations` is wired in and the layout
/// uses logical (start/end) insets everywhere.
class NaxloApp extends StatelessWidget {
  const NaxloApp({required this.state, this.observer, super.key});

  final AppState state;
  final AppLifecycleObserver? observer;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AppState>.value(
      value: state,
      child: Consumer<AppState>(
        builder: (BuildContext context, AppState app, Widget? _) {
          return MaterialApp(
            title: 'Naxlo Two',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            themeMode: app.themeMode,
            supportedLocales: NaxloLocalizations.kSupported,
            localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
              NaxloLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            locale: app.settings.locale.isEmpty ? null : Locale(app.settings.locale),
            localeResolutionCallback: (Locale? device, Iterable<Locale> supported) {
              final forced = app.settings.locale;
              if (forced.isNotEmpty) return Locale(forced);
              if (device == null) return const Locale('en');
              for (final l in supported) {
                if (l.languageCode == device.languageCode) return l;
              }
              return const Locale('en');
            },
            home: const RootShell(),
          );
        },
      ),
    );
  }
}

/// Lets the platform shell (tray/window handling) hook lifecycle without the UI
/// layer knowing about it.
class AppLifecycleObserver extends WidgetsBindingObserver {
  AppLifecycleObserver({required this.onBackground});

  final VoidCallback onBackground;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      onBackground();
    }
  }
}
