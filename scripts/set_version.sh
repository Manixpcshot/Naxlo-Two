#!/usr/bin/env bash
# set_version.sh — fan one version number out to every place it is duplicated.
#
#   scripts/set_version.sh 0.1.3
#   scripts/set_version.sh            # print the current version
#
# VERSION is the source of truth. These files must always agree, and the reason
# to script it instead of remembering it is that a mismatch is invisible: the
# About card shows one number, pub resolves another, and the updater compares
# the git tag against a third.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version_file="$root/VERSION"
dart_version="$root/packages/naxlo_core/lib/src/version.dart"
pubspec="$root/app/pubspec.yaml"
core_pubspec="$root/packages/naxlo_core/pubspec.yaml"

if [[ $# -eq 0 ]]; then
  cat "$version_file"
  exit 0
fi

new="$1"
if [[ ! "$new" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "set_version: '$new' is not a semver version (expected MAJOR.MINOR.PATCH[-prerelease])" >&2
  exit 2
fi

old="$(tr -d '[:space:]' <"$version_file")"
echo "set_version: ${old:-<none>} -> $new"

printf '%s\n' "$new" >"$version_file"

# 1. The core constant the app compares against the update manifest at runtime.
if [[ -f "$dart_version" ]]; then
  awk -v v="$new" '
    /const String kNaxloVersion/ { print "const String kNaxloVersion = \"" v "\";"; next }
    { print }
  ' "$dart_version" >"$dart_version.tmp" && mv "$dart_version.tmp" "$dart_version"
fi

# 2. pubspecs — `version: X.Y.Z+build`, where build is the commit count so CI
#    artifacts stay distinguishable within one version.
build="$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 1)"
for spec in "$pubspec" "$core_pubspec"; do
  [[ -f "$spec" ]] || continue
  awk -v v="$new" -v b="$build" '
    /^version:/ { print "version: " v "+" b; next }
    { print }
  ' "$spec" >"$spec.tmp" && mv "$spec.tmp" "$spec"
done

# 3. Packaging templates that embed the version literally. Drift here breaks the
#    package build in a way that looks like a packaging bug, not a version bug.
for f in "$root"/packaging/windows/naxlo-two.iss \
         "$root"/packaging/linux/PKGBUILD \
         "$root"/packaging/linux/naxlo-two.spec \
         "$root"/packaging/linux/debian/changelog; do
  [[ -f "$f" ]] || continue
  tmp="$f.tmp"
  case "$(basename "$f")" in
    *.iss)
      awk -v v="$new" '
        $1 == "#define" && $2 == "MyAppVersion" { print "#define MyAppVersion \"" v "\""; next }
        { print }
      ' "$f" >"$tmp" && mv "$tmp" "$f"
      ;;
    PKGBUILD)
      awk -v v="$new" '
        /^pkgver=/ { print "pkgver=" v; next }
        { print }
      ' "$f" >"$tmp" && mv "$tmp" "$f"
      ;;
    *.spec)
      awk -v v="$new" '
        /^Version:/ { print "Version:        " v; next }
        { print }
      ' "$f" >"$tmp" && mv "$tmp" "$f"
      ;;
    changelog)
      awk -v v="$new" '
        NR == 1 { print "(" v ") unstable; urgency=medium" }
        NR != 1 { print }
      ' "$f" >"$tmp" && mv "$tmp" "$f"
      ;;
  esac
done

if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$root" add -- "$version_file" "$dart_version" "$pubspec" 2>/dev/null || true
  if ! git -C "$root" diff --cached --quiet 2>/dev/null; then
    cat <<EOF

Updated: VERSION, $(basename "$dart_version"), $(basename "$pubspec").
Commit before tagging, or let auto-release.yml do it:
  git commit -m "chore(release): v$new" && git tag v$new && git push origin v$new
EOF
  fi
fi
