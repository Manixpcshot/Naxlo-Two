import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:naxlo_core/naxlo_core.dart';
import 'package:naxlo_two/app.dart';
import 'package:naxlo_two/state/probe_service.dart';
import 'package:naxlo_two/state/app_state.dart';
import 'package:naxlo_two/ui/home_page.dart';
import 'package:naxlo_two/ui/logs_page.dart';
import 'package:naxlo_two/ui/servers_page.dart';
import 'package:naxlo_two/ui/settings_page.dart';

/// Pumps the real widget tree against an in-memory [AppState]. No engine, no
/// network, no path_provider — enough to catch layout-time nulls, missing
/// delegates and RTL regressions, which is where hand-written Flutter usually
/// breaks first.
void main() {
  const twoLinks = '''
vless://11111111-1111-1111-1111-111111111111@fast.example.com:443?security=tls&sni=fast.example.com&type=ws#FAST
vless://22222222-2222-2222-2222-222222222222@slow.example.com:8443?security=reality&sni=www.microsoft.com&type=tcp#SLOW
''';

  AppState buildApp({String locale = 'en', String? json}) {
    final app = AppState.inMemory(
      initialJson: json,
      settings: RuntimeSettings(checkForUpdates: false, locale: locale),
    );
    return app;
  }

  Future<AppState> pumpApp(WidgetTester tester, {String locale = 'en'}) async {
    // Wide enough for the extended rail; the compact variant hides labels.
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final app = buildApp(locale: locale);
    await app.importLinks(twoLinks);
    await tester.pumpWidget(NaxloApp(state: app));
    await tester.pumpAndSettle();
    // The import armed the 900ms debounced autosave. A test that ends with a live
    // Timer fails ("A Timer is still pending"), and pumpAndSettle stops as soon as
    // there are no scheduled frames — which is immediately here. One long pump
    // lets the write happen, which is also what the app does in real life.
    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pumpAndSettle();
    addTearDown(app.dispose);
    return app;
  }

  testWidgets('shell boots on the connect page with the rail visible', (WidgetTester tester) async {
    await pumpApp(tester);
    expect(find.text('Naxlo Two'), findsWidgets);
    expect(find.byType(HomePage), findsOneWidget);
    expect(find.text('Connect'), findsWidgets);
    expect(find.text('Logs'), findsWidgets);
  });

  testWidgets('empty profile path shows the import affordance, not an exception', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1.0;
    final app = buildApp();
    await tester.pumpWidget(NaxloApp(state: app));
    await tester.pumpAndSettle();
    expect(find.textContaining('No profiles yet'), findsWidgets);
    app.dispose();
  });

  testWidgets('rail switches to every page', (WidgetTester tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const ValueKey<String>('rail-nav.servers')));
    await tester.pumpAndSettle();
    expect(find.byType(ServersPage), findsOneWidget);
    // Both imported nodes are listed with their latency unknown state.
    expect(find.text('FAST'), findsWidgets);
    expect(find.text('SLOW'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey<String>('rail-nav.settings')));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('rail-nav.logs')));
    await tester.pumpAndSettle();
    expect(find.byType(LogsPage), findsOneWidget);
    expect(find.textContaining('Nothing logged yet'), findsOneWidget);
  });

  testWidgets('persian locale flips the shell to rtl', (WidgetTester tester) async {
    await pumpApp(tester, locale: 'fa');
    final context = tester.element(find.byType(Navigator));
    expect(Directionality.of(context), TextDirection.rtl);
    expect(find.text('اتصال'), findsWidgets);
  });

  testWidgets('measurements reach the list in ranked order', (WidgetTester tester) async {
    final app = await pumpApp(tester);
    final fast = app.profile!.servers.firstWhere((ServerNode s) => s.name == 'FAST');
    final slow = app.profile!.servers.firstWhere((ServerNode s) => s.name == 'SLOW');
    final now = DateTime.now().millisecondsSinceEpoch;

    app.ingestSamples(<ProbeOutcome>[
      ProbeOutcome(
        serverId: fast.id,
        attempts: 3,
        sample: SamplePoint.success(atMs: now, latencyMs: 41),
      ),
      ProbeOutcome(
        serverId: slow.id,
        attempts: 1,
        sample: SamplePoint.success(atMs: now, latencyMs: 780),
      ),
    ]);
    await tester.pumpAndSettle();

    expect(app.ranked.first.serverId, fast.id);
    expect(app.rankOf(slow.id)!.latencyMs, 780);

    await tester.tap(find.byKey(const ValueKey<String>('rail-nav.servers')));
    await tester.pumpAndSettle();
    // Paint order is the contract: the top-ranked node is the topmost row.
    expect(tester.getTopLeft(find.text('FAST')).dy, lessThan(tester.getTopLeft(find.text('SLOW')).dy));
  });
}
