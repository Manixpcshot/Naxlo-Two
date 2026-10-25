import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:naxlo_core/naxlo_core.dart';

import 'app.dart';
import 'state/app_state.dart';
import 'state/system_proxy.dart';
import 'version_info.dart';

/// Entry point.
///
/// Deliberately tiny: everything that can fail (reading state, locating the
/// engine binary, restoring the system proxy) happens inside [AppState.load], so
/// a broken profile can never stop the window from appearing. A client that
/// won't open is a client that leaves your system proxy pointing at a dead port.
///
/// The few flags below exist for packaging scripts, not for users: a package
/// manager's `%preun`/uninstall hook runs headless, with no display and no
/// session, so it cannot "just open the app and click disconnect".
Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.write(_usage);
    exit(0);
  }
  if (args.contains('--version')) {
    stdout.writeln('naxlo_two $versionLabel');
    exit(0);
  }
  if (args.contains('--disable-system-proxy')) {
    exit(await _clearSystemProxy());
  }

  WidgetsFlutterBinding.ensureInitialized();

  AppState.createDesktop().then((state) async {
    await state.load();
    runApp(NaxloApp(state: state));
  });
}

/// Clears the proxy settings this app would have set, then exits.
///
/// Why it does not try to *restore* previous values: the snapshot of "what was
/// there before us" lives in the memory of the running process, and a package
/// script runs after that process is gone. So this is deliberately narrower than
/// [SystemProxyController.restore] — it turns our own knobs off and touches
/// nothing else, which is the safe default when we cannot prove ownership.
Future<int> _clearSystemProxy() async {
  final controller = SystemProxyController();
  final failures = await controller.apply(const RuntimeSettings(), enable: false);
  for (final f in failures) {
    stderr.writeln('naxlo_two: $f');
  }
  if (failures.isEmpty) {
    stdout.writeln('naxlo_two: system proxy cleared');
    return 0;
  }
  // Non-zero only when the tools themselves are missing: "no proxy was set" is a
  // success for an uninstall hook, and a hard failure there blocks the removal.
  return failures.every((f) => f.contains('Not found') || f.contains('not found')) ? 0 : 1;
}

const String _usage = '''
Naxlo Two — proxy client for Xray-core and sing-box.

Usage: naxlo-two [flags]

  --help, -h                 this text
  --version                  print version and exit
  --disable-system-proxy     clear proxy settings this app sets, then exit
                             (used by package uninstall hooks; never enables)

Normal use is the window. These flags exist so `pacman -Rns` or an uninstaller
can leave the machine in a working state when the app is not running.
''';
