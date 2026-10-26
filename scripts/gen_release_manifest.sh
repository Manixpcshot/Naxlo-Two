#!/usr/bin/env bash
# gen_release_manifest.sh — regenerate the `release` file the app's updater reads.
#
#   scripts/gen_release_manifest.sh v0.1.0
#   scripts/gen_release_manifest.sh              # latest published release
#
# Called by .github/workflows/release.yml after assets are uploaded, and safe to
# run by hand. It only *reads* a release (via gh) and writes one JSON file.
#
# The shape matches what Happ ships, plus `sha256` / `size` / `generatedAt`, so
# the client can verify a download instead of trusting the CDN. A platform's
# `block` array is carried over from the previous manifest rather than
# recomputed: "0.4.2 is broken, refuse to update onto it" is a human decision
# that no asset listing can derive.
#
# All selection logic is one jq program on purpose. Doing it in bash meant
# re-quoting a regex through three shell layers per platform, which is exactly
# how a release script ends up offering an .apk to a Windows user.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/release"
app_id="naxlo_two"
tag="${1:-}"

command -v gh >/dev/null 2>&1 || { echo "gen_release_manifest: needs the GitHub CLI (gh)" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "gen_release_manifest: needs jq" >&2; exit 1; }

if [[ -z "$tag" ]]; then
  tag="$(gh release view --latest --json tagName -q .tagName)"
fi
[[ -n "$tag" ]] || { echo "gen_release_manifest: could not determine a release tag" >&2; exit 1; }

echo "gen_release_manifest: building manifest for $tag"

release="$(gh release view "$tag" --json tagName,body,assets)"
version="$(echo "$release" | jq -r '.tagName | sub("^v"; "")')"
body="$(echo "$release" | jq -r '(.body // "") | .[0:1200]')"
# `digest` is populated by GitHub for assets it stored ("sha256:<hex>") and empty
# for externally-linked ones. Empty -> the client treats the artifact as
# unverified and will not auto-install it. That asymmetry is intentional.
assets="$(echo "$release" | jq -c '[.assets[] | {name, url, size, digest}]')"
filnum="$(echo "$assets" | jq 'length')"
generated="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

old_blocks='{}'
if [[ -f "$out" ]]; then
  old_blocks="$(jq -c '
    . as $in
    | reduce ["windows","macos","linux","android","ios"][] as $p
        ({}; .[$p] = ($in[$p].block // []))' "$out")"
fi

tmp="$(mktemp)"
jq -n \
  --argjson assets "$assets" \
  --argjson old "$old_blocks" \
  --arg app "$app_id" \
  --arg version "$version" \
  --arg body "$body" \
  --argjson filenum "$filnum" \
  --arg gen "$generated" '
def belongs($p):
  if $p == "windows" then test("(?i)\\.exe$")
  elif $p == "macos" then test("(?i)\\.(dmg|pkg)$")
  elif $p == "linux" then test("(?i)\\.(deb|rpm|zst|AppImage)$")
  elif $p == "android" then test("(?i)\\.apk$")
  else false
  end;
# Lower rank wins: the artifact that works on the widest machine for the
# platform. Anything not matched by belongs() is left out entirely, so source
# tarballs and checksum files never become a "download" link.
def rank($p):
  if $p == "windows" then
    (if test("^setup-Naxlo\\.x64\\.exe$") then 0 elif test("(?i)x64") then 1 else 2 end)
  elif $p == "macos" then
    (if test("(?i)universal\\.dmg$") then 0 elif test("(?i)\\.dmg$") then 1 else 2 end)
  elif $p == "linux" then
    (if test("(?i)(x64|amd64)\\.deb$") then 0
     elif test("(?i)\\.deb$") then 1
     elif test("(?i)AppImage$") then 2
     elif test("(?i)\\.rpm$") then 3
     else 4 end)
  else
    (if test("(?i)universal") then 0 elif test("(?i)arm64-v8a") then 1 else 2 end)
  end;
def entry($p):
  [ $assets[]
    | select(.name | belongs($p))
    | . + {rank: (.name | rank($p))} ]
  | sort_by(.rank, .name)
  | .[0]
  | if . == null then
      {}
    else
      {
        version: $version,
        link: .url,
        details: $body,
        sha256: ((.digest // "") | sub("^sha256:"; "")),
        size: (.size // 0),
        asset: .name,
        minSupported: "",
        update: {warnalways: "", updateonly: ""}
      }
    end;
def platform($p): {block: ($old[$p] // []), stable: entry($p), beta: {}};
{app: $app, filenum: $filenum, generatedAt: $gen}
+ (reduce ["windows","macos","linux","android","ios"][] as $p ({}; .[$p] = platform($p)))
' >"$tmp"

# A manifest the app cannot parse silently switches updates off for every
# install, so validate the shape before moving it into place.
if ! jq -e '(.windows | has("stable")) and (.linux | has("stable")) and (.macos | has("stable"))' "$tmp" >/dev/null; then
  echo "gen_release_manifest: generated JSON is malformed, refusing to write $out" >&2
  cat "$tmp" >&2
  exit 1
fi

mv "$tmp" "$out"
echo "  wrote $out from $filnum asset(s) -> $version"
