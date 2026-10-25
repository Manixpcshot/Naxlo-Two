import 'package:flutter/foundation.dart';
import 'package:naxlo_core/naxlo_core.dart';

/// The app version, kept identical to `packages/naxlo_core/lib/src/version.dart`
/// by scripts/set_version.sh (which rewrites both plus `VERSION` and pubspecs).
///
/// It is a `const` rather than a `String.fromEnvironment` because the release
/// workflow builds with `--dart-define` for the *channel* only; an accidental
/// rebuild without the define must not silently produce a "0.0.0" client that
/// then thinks every published update is newer than itself.
const String kAppVersion = kNaxloVersion;

/// `dev` | `beta` | `stable` — baked in at build time by CI.
const String kAppChannel = String.fromEnvironment('channel', defaultValue: 'dev');

const String kRepoUrl = 'https://github.com/Manixpcshot/Naxlo-Two';

bool get isDebugBuild => kDebugMode;

String get versionLabel {
  // const, not final: `kAppChannel` comes from `String.fromEnvironment`, so the
  // channel is known at compile time and so is this label.
  const suffix = kAppChannel == 'stable' ? '' : ' ($kAppChannel)';
  return '$kAppVersion$suffix';
}
