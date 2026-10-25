#!/usr/bin/env bash
# bootstrap_platforms.sh — generate the Flutter platform folders this repo does
# not vendor.
#
#   scripts/bootstrap_platforms.sh              # every platform
#   scripts/bootstrap_platforms.sh linux android
#
# Why generated instead of committed: `flutter create` platform scaffolding is
# ~400 files of Gradle, CMake, plist and manifest boilerplate that changes with
# the SDK version. Vendoring it freezes you to the SDK that generated it and
# makes every Flutter upgrade a merge conflict in files nobody reads. The cost
# is one command before the first build, which CI does for you.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="$root/app"
org="dev.naxlo"
project="naxlo_two"
platforms=("$@")
[[ ${#platforms[@]} -eq 0 ]] && platforms=(linux windows macos android ios)

command -v flutter >/dev/null 2>&1 || {
  cat >&2 <<'EOF'
bootstrap_platforms: `flutter` is not on PATH.
Install the Flutter SDK (https://docs.flutter.dev/get-started/install), then:
  flutter --version && scripts/bootstrap_platforms.sh
CI does this for you via subosito/flutter-action; only local builds need it.
EOF
  exit 1
}

cd "$app"

if [[ ! -d .dart_tool ]]; then
  echo "==> flutter pub get"
  flutter pub get
fi

for p in "${platforms[@]}"; do
  case "$p" in
    linux|windows|macos|android|ios|web) ;;
    *) echo "bootstrap_platforms: unknown platform '$p'" >&2; exit 2 ;;
  esac
  if [[ -d "$p" ]]; then
    echo "==> $p already exists, leaving it alone"
    continue
  fi
  echo "==> flutter create --platforms=$p"
  # `--project-name` and `--org` are what make the bundle id, package name and
  # executable name match the identifiers the packaging scripts and the updater
  # assume; a plain `flutter create` would silently name things "app".
  flutter create \
    --platforms="$p" \
    --org "$org" \
    --project-name "$project" \
    .
done

# Linux desktop entry: `flutter create` gives us a generic one. The Exec/Name
# pair has to say "naxlo_two" or the window does not group under its own icon and
# the tray icon never appears.
if [[ -d linux && -f linux/runner/my_application.cc ]]; then
  if ! grep -q naxlo_two linux/runner/my_application.cc; then
    echo "==> note: linux/runner/my_application.cc still has the default app id"
    echo "   (replace 'app' with '$project' in gtk_application_new / window title)"
  fi
fi

cat <<EOF

Platform folders ready. Next:
  cd app && flutter run -d linux        # or windows / macos / an Android device
Engine binaries (only if you want them bundled next to the build):
  scripts/fetch_engine.sh
EOF
