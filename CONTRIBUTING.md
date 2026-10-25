# Contributing to Naxlo Two

Thanks for showing up. This file is the short version of "what will make a
patch here acceptable". The repo is small on purpose, so most of this is about
keeping the boundaries where they are.

## Layout

```
packages/naxlo_core/   pure-Dart domain: models, ranking, config builders,
                       subscription/share-link parsing, store, updater manifest.
                       No Flutter, no dart:io beyond files you hand it.
app/                   Flutter UI + process/network services.
  lib/state/           engine supervisor, prober, proxy, storage, logs.
  lib/ui/              screens and shared widgets.
scripts/               version, engine fetch, platform bootstrap, manifest gen.
packaging/             Linux/Windows packaging templates.
docs/                  ranking math, engine contract, packaging, privacy.
release                the in-app update manifest (generated, do not hand-edit)
```

The rule that matters: **`naxlo_core` must not import Flutter or `dart:io`**.
Ranking, config generation and parsing are the parts worth testing on a VM in
ten milliseconds; if they can be reasoned about without a widget tree, they can
be debugged by anyone.

## Getting a dev build running

```bash
flutter --version                 # 3.24+ ; CI pins 3.24.5
scripts/bootstrap_platforms.sh    # generates app/{android,ios,linux,macos,windows}
cd app && flutter pub get
flutter run -d linux              # or -d windows / -d macos
```

`scripts/bootstrap_platforms.sh` is required because platform folders are
generated, not vendored. They are in `.gitignore` for the same reason.

To use an engine you built or downloaded yourself, set the binary path in
Settings → Engine (`xrayBinaryPath` / `singBoxBinaryPath`), or drop it in
`app/assets/engine/` after `scripts/fetch_engine.sh`.

## Checks before you open a pull request

```bash
cd packages/naxlo_core && dart analyze && dart test
cd app                  && flutter analyze && flutter test
dart format --line-length 110 --output=none --set-exit-if-changed .
```

`dart format` is enforced in CI with a line length of 110. If your editor
disagrees, run the formatter rather than arguing with it.

## Conventions you will notice in the code

* **Comments explain why, not what.** Every non-obvious trade-off in this repo
  has a paragraph next to it saying what the alternative was and why it lost.
  If you change behaviour that a comment justifies, update the comment.
* **No `dynamic` flowing into models.** JSON arrives through
  `packages/naxlo_core/lib/src/json/json_utils.dart` (`asString`, `asInt`,
  `asBool`, …) so a malformed subscription degrades instead of throwing.
* **State changes go through the service, not the widget.** If a screen needs
  something to happen, it calls a method on `AppState`; screens do not write to
  the bundle, spawn processes or open sockets themselves.
* **Nothing leaves the machine.** No analytics, no crash reporting, no
  "phone home on first run". The only outbound request the app makes on its own
  is the update-manifest fetch, and it can be turned off in Settings.
* **Never copy from Happ.** Happ's public repos are distribution-only; its
  source, icons, wording and binaries are not ours to reuse. This project
  re-implements the same idea on the same engine.

## Ranking changes need a story

If you touch `packages/naxlo_core/lib/src/ranking/`, say in the pull request
what ordering changes for which input, and add a case to `test/ranker_test.dart`
or `test/metrics_test.dart`. The ranker is the one part of this app where a
plausible-sounding tweak quietly makes it worse: a component that looks "more
correct" but has the same scale as another one just duplicates it.

A good test here pins a *decision*, not a number: *node A must beat node B while
latency dominates; A must lose to B once reliability dominates.*

## Commit messages and releases

Merged commits should use Conventional Commits — they become the release notes
and drive the automatic version bump:

| Subject | Effect on `VERSION` |
| --- | --- |
| `fix:` / `perf:` / `refactor:` | patch |
| `feat:` / `fix!:` / any `!` | minor |
| `BREAKING CHANGE:` footer | major |
| `[skip-release]` anywhere in the body | no release for that push |

Merging to `main` publishes a release by itself; a `vX.Y.Z` tag publishes one
manually. See `docs/PACKAGING.md`.

## Tests without a Dart SDK

If you are working in an environment where the Flutter/Dart SDK cannot be
installed, do not skip the checks silently — say so in the pull request. CI
runs `dart analyze`, `dart test`, `flutter analyze` and `flutter test` on every
push; treat a red CI as part of the patch, not as noise.

## Reporting problems

Open an issue with: app version (About card), OS, engine (Xray or sing-box) and
version, and — this is the useful part — the **Logs** screen contents. The
ranker writes its reasoning there too, so "it picked a worse server" issues can
usually be diagnosed from that dump alone. Strip server addresses and keys first.
