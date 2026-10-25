#!/usr/bin/env bash
# fetch_engine.sh — download the proxy engine binaries into app/assets/engine/.
#
#   scripts/fetch_engine.sh                                   # latest, host arch
#   scripts/fetch_engine.sh --engine xray --os windows --arch amd64
#   scripts/fetch_engine.sh --xray-version v26.10.21 --singbox-version v1.14.4
#   scripts/fetch_engine.sh --sha256 4f2a…                     # pin what you expect
#
# Why a script instead of vendoring binaries: committing engine blobs makes the
# repo huge, ages the client against the engine, and hides which core a user is
# actually running. Why not "download at runtime": a first run that needs the
# network to become functional is a bad trade for a tool people use *because*
# their network is broken. So: fetched at build time, verified, then shipped.
#
# Nothing here is executed. The app only runs what it finds in the user's
# app-support dir or an explicit path (see lib/state/engine_locator.dart).
#
# ── integrity, stated honestly ──────────────────────────────────────────────
# The two engines publish different amounts of information:
#
#   Xray      `Xray-<os>-<arch>.zip` + `<asset>.dgst`  → always verified here;
#             a mismatch or a missing .dgst is a hard failure.
#   sing-box  `sing-box-<ver>-<os>-<arch>.tar.gz` and *no* digest of any kind.
#
# For sing-box there is therefore nothing to check against unless you pin a value,
# so this script (a) prints the sha256 it computed on every run, (b) consults
# packaging/engine-lock.json, and (c) warns — loudly — when no expectation exists.
# The lock file is the fix: run `--write-lock` once on a network you trust, commit
# the digests, and from then on a supply-chain swap is a mismatch instead of a
# build artifact. Refusing to *pretend* verification happened is the point.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest="$root/app/assets/engine"
lock_file="$root/packaging/engine-lock.json"
xray_version="${XRAY_VERSION:-}"
singbox_version="${SINGBOX_VERSION:-}"
pinned_sha="${ENGINE_SHA256:-}"
want_os=""
want_arch=""
want_engine="both"
write_lock=0
require_pin=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine) want_engine="$2"; shift 2 ;;
    --os) want_os="$2"; shift 2 ;;
    --arch) want_arch="$2"; shift 2 ;;
    --xray-version) xray_version="$2"; shift 2 ;;
    --singbox-version) singbox_version="$2"; shift 2 ;;
    --sha256) pinned_sha="$2"; shift 2 ;;
    --dest) dest="$2"; shift 2 ;;
    --write-lock) write_lock=1; shift ;;
    --require-pin) require_pin=1; shift ;;
    -h|--help) sed -n '2,33p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "fetch_engine: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

# --- host detection ----------------------------------------------------------
uname_s="$(uname -s)"
uname_m="$(uname -m)"
if [[ -z "$want_os" ]]; then
  case "$uname_s" in
    Linux) want_os=linux ;;
    Darwin) want_os=macos ;;
    MINGW*|MSYS*|CYGWIN*) want_os=windows ;;
    *) echo "fetch_engine: unsupported host OS '$uname_s'" >&2; exit 1 ;;
  esac
fi
if [[ -z "$want_arch" ]]; then
  case "$uname_m" in
    x86_64|amd64) want_arch=amd64 ;;
    aarch64|arm64) want_arch=arm64 ;;
    armv7*|armhf) want_arch=armv7 ;;
    i386|i686) want_arch="386" ;;
    *) echo "fetch_engine: unsupported host arch '$uname_m'" >&2; exit 1 ;;
  esac
fi

for tool in curl jq unzip tar; do
  command -v "$tool" >/dev/null 2>&1 || { echo "fetch_engine: needs '$tool' on PATH" >&2; exit 1; }
done
command -v unzip >/dev/null 2>&1 || { echo "fetch_engine: needs 'unzip' for Xray archives" >&2; exit 1; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

latest_tag() { # repo
  # Two ways to ask for "latest", because the API is the fragile one: runner IPs
  # are shared by thousands of jobs and an unauthenticated 403 is routine. Both
  # paths end in `|| true` — this runs inside a command substitution in an
  # assignment, and under `set -e` a non-zero there would abort the whole script
  # before the "could not resolve latest tag" message could be printed.
  local repo="$1"
  local -a auth=()
  if [[ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
    auth=(-H "Authorization: Bearer ${GH_TOKEN:-${GITHUB_TOKEN:-}}")
  fi
  local tag
  tag="$(curl -fsSL --retry 2 "${auth[@]}" -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null \
      | jq -r '.tag_name // empty' || true)"
  if [[ -z "$tag" ]]; then
    # /releases/latest answers with a 302 whose Location *is* the tag URL:
    # no API, no rate limit, no token.
    tag="$(curl -fsSI --max-redirs 0 "https://github.com/$repo/releases/latest" 2>/dev/null \
        | tr -d '\r' | awk 'tolower($1)=="location:"{print $2}' | sed 's#.*/tag/##' || true)"
  fi
  printf '%s' "$tag"
}

# Expected digest, in priority order: explicit pin, lock file, then (caller-specific)
# whatever upstream published. Empty return means "no expectation".
lock_sha() { # engine  os-arch
  [[ -f "$lock_file" ]] || return 0
  jq -r --arg e "$1" --arg k "$2" '.[$e][$k] // empty' "$lock_file" 2>/dev/null || true
}

record_sha() { # engine  os-arch  sha  url
  [[ $write_lock -eq 1 ]] || return 0
  local tmp; tmp="$(mktemp)"
  jq --arg e "$1" --arg k "$2" --arg s "$3" --arg u "$4" \
    '.[$e][$k] = $s | .[$e + "_url"] = {($k): $u} | .note = "sha256 of engine archives, per <os>-<arch>. Written by scripts/fetch_engine.sh --write-lock."' \
    "$lock_file" >"$tmp" 2>/dev/null || echo '{}' >"$tmp"
  mv "$tmp" "$lock_file"
  echo "    recorded $1/$2 = $3 in packaging/engine-lock.json"
}

check_against() { # label  actual  expected
  local label="$1" actual="$2" expected="$3"
  if [[ -z "$expected" ]]; then
    return 2
  fi
  if [[ "$actual" == "$expected" ]]; then
    echo "  $label ok: $actual"
    return 0
  fi
  echo "  $label MISMATCH" >&2
  echo "    expected $expected" >&2
  echo "    actual   $actual" >&2
  return 1
}

fetch_xray() {
  local version="$xray_version"
  [[ -n "$version" ]] || version="$(latest_tag XTLS/Xray-core)"
  [[ -n "$version" ]] || { echo "fetch_engine: could not resolve the latest Xray tag (API rate limited?)" >&2; return 1; }
  local arch
  case "$want_arch" in
    amd64) arch="64" ;;
    arm64) arch="arm64-v8a" ;;
    armv7) arch="arm32-v7a" ;;
    386) arch="32" ;;
  esac
  local tag="${version#v}"
  local base="https://github.com/XTLS/Xray-core/releases/download/v${tag}"
  local asset="Xray-${want_os}-${arch}.zip"
  local key="${want_os}-${want_arch}"
  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN

  echo "xray v${tag} (${want_os}/${want_arch})"
  if ! curl -fsSL --retry 3 -o "$tmp/$asset" "$base/$asset"; then
    echo "fetch_engine: download failed: $base/$asset" >&2
    echo "  HTTP $(curl -o /dev/null -sw '%{http_code}' -I "$base/$asset" || echo '?') from that URL" >&2
    return 1
  fi
  # The .dgst is best-effort to *fetch* (some mirrors drop it) but must be
  # satisfied unless a pin covers it. Errors are reported, never swallowed: a
  # `2>/dev/null || true` here turned a fixable download problem into
  # "no verifiable digest" with nothing to act on.
  local dgst_code
  dgst_code="$(curl -fsSL --retry 2 -o "$tmp/$asset.dgst" -w '%{http_code}' "$base/$asset.dgst" 2>"$tmp/dgst.err" || true)"
  if [[ ! -s "$tmp/$asset.dgst" ]]; then
    rm -f "$tmp/$asset.dgst"
    echo "fetch_engine: .dgst unavailable for $asset (http=${dgst_code:-?} $(head -1 "$tmp/dgst.err" 2>/dev/null || true))" >&2
    # Second path: the release-asset endpoint streams the same bytes through
    # api.github.com, which survives CDN/proxy quirks that kill the redirect to
    # the asset bucket. Needs the asset id, which the release listing already has.
    local -a gh_auth=()
    if [[ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
      gh_auth=(-H "Authorization: Bearer ${GH_TOKEN:-${GITHUB_TOKEN:-}}")
    fi
    local asset_id
    asset_id="$(curl -fsSL --retry 2 ${gh_auth[@]+"${gh_auth[@]}"} -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/XTLS/Xray-core/releases/tags/$tag" 2>/dev/null \
        | jq -r --arg n "$asset.dgst" '.assets[]? | select(.name == $n) | .id' 2>/dev/null | head -1 || true)"
    if [[ -n "$asset_id" && "$asset_id" != "null" ]]; then
      if curl -fsSL --retry 2 ${gh_auth[@]+"${gh_auth[@]}"} -H "Accept: application/octet-stream" \
          -o "$tmp/$asset.dgst" "https://api.github.com/repos/XTLS/Xray-core/releases/assets/$asset_id"; then
        echo "fetch_engine: recovered the digest via the api.github.com asset endpoint" >&2
      else
        rm -f "$tmp/$asset.dgst"
      fi
    fi
  fi

  local actual; actual="$(sha256_of "$tmp/$asset")"
  local expected; expected="$(lock_sha xray "$key")"
  # `|| status=$?` everywhere: a bare `check_against ...; status=$?` under
  # `set -e` aborts the whole script the moment a check does not pass, which is
  # how "digest not pinned yet" turned into an unexplained exit 1.
  local status=2
  if check_against "pin/lock sha256" "$actual" "${pinned_sha:-$expected}"; then
    status=0
  else
    status=$?
  fi
  if [[ $status -eq 2 && -s "$tmp/$asset.dgst" ]]; then
    # No pin: fall back to the .dgst Xray publishes beside every asset. Take the
    # hex on the SHA256-labelled line — a `[0-9a-f]{64}` grep would also match the
    # first 64 characters of the SHA512 field and compare that instead.
    # Match on *field length*, not /[0-9a-f]{64}/: mawk (the default awk on Debian
    # and Ubuntu runners) does not enable interval expressions, so a `{64}` regex
    # silently matches nothing and every digest looks "unavailable". MD5 is 32,
    # SHA1 40 and SHA512 128 characters, so a 64-char field on the SHA256 line is
    # unambiguous without needing intervals at all.
    local from_dgst
    from_dgst="$(awk '
      tolower($0) ~ /sha256/ {
        for (i = 1; i <= NF; i++)
          if (length($i) == 64 && $i ~ /^[0-9a-fA-F]+$/) { print $i; exit }
      }' "$tmp/$asset.dgst")"
    if [[ -z "$from_dgst" ]]; then
      # Bare "<hex>  <filename>" lines (coreutils format), SHA256-length only.
      from_dgst="$(awk '$1 ~ /^[0-9a-fA-F]+$/ && length($1) == 64 { print $1; exit }' "$tmp/$asset.dgst")"
    fi
    if check_against "upstream .dgst" "$actual" "$from_dgst"; then
      status=0
    else
      status=$?
    fi
  fi
  case $status in
    0) ;;
    1) echo "fetch_engine: refusing to install an Xray archive whose digest does not match" >&2; return 1 ;;
    *)
      # Nothing to check against — upstream's digest listing changed, or the
      # download of it failed. Two policies, because the two callers differ:
      # a developer/CI build should still work (loudly), a release must not
      # ship an engine we could not tie to what upstream published.
      if [[ $require_pin -eq 1 ]]; then
        echo "fetch_engine: refusing to ship $asset with no verifiable digest" >&2
        echo "  computed sha256 $actual" >&2
        echo "  pin it once on a network you trust:  $0 --write-lock --engine xray --os $os --arch $arch" >&2
        return 1
      fi
      echo "fetch_engine: WARNING - no verifiable digest for $asset (.dgst missing?)" >&2
      echo "  computed sha256 $actual - not checked against anything" >&2
      echo "  computed sha256 $actual — pin it with --sha256 or commit it via --write-lock" >&2
      return 1
      ;;
  esac

  local out="$dest/$key/xray"
  mkdir -p "$out"
  unzip -qo "$tmp/$asset" -d "$out"
  chmod 755 "$out/xray" 2>/dev/null || true
  printf 'xray %s\n' "$tag" >"$out/.version"
  record_sha xray "$key" "$actual" "$base/$asset"
  echo "  → $out"
}

fetch_singbox() {
  local version="$singbox_version"
  [[ -n "$version" ]] || version="$(latest_tag SagerNet/sing-box)"
  [[ -n "$version" ]] || { echo "fetch_engine: could not resolve the latest sing-box tag" >&2; return 1; }
  local tag="${version#v}"
  # sing-box names assets by GOOS/GOARCH and publishes no digest files, and its
  # macOS archives are per-arch (`darwin-amd64`, `darwin-arm64`) — there is no
  # universal archive to fetch, whatever a README from 2023 says.
  local os_part="$want_os" arch_part="$want_arch" ext=tar.gz
  case "$want_os" in
    macos) os_part=darwin ;;
    linux) ;;
    windows) ext=zip ;;
  esac
  case "$want_arch" in
    armv7) arch_part=armv7 ;;
    386) arch_part=386 ;;
  esac
  local asset="sing-box-${tag}-${os_part}-${arch_part}.${ext}"
  local key="${want_os}-${want_arch}"
  local base="https://github.com/SagerNet/sing-box/releases/download/v${tag}"
  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN

  echo "sing-box ${tag} (${want_os}/${want_arch})"
  curl -fsSL --retry 3 -o "$tmp/$asset" "$base/$asset"

  local actual; actual="$(sha256_of "$tmp/$asset")"
  local expected; expected="$(lock_sha sing-box "$key")"
  if [[ -n "${pinned_sha:-}" ]]; then
    check_against "pinned sha256" "$actual" "$pinned_sha" || {
      echo "fetch_engine: refusing the mismatched sing-box archive" >&2; return 1; }
  elif [[ -n "$expected" ]]; then
    check_against "lock sha256" "$actual" "$expected" || {
      echo "fetch_engine: digest does not match packaging/engine-lock.json — do not ship this" >&2
      return 1; }
  else
    # sing-box publishes no checksum, so there is genuinely nothing to verify
    # against here. Print the number instead of staying silent: it is what makes
    # `--write-lock` on a trusted network a one-command improvement.
    echo "  !! upstream publishes no digest for $asset" >&2
    echo "     computed sha256 $actual" >&2
    echo "     pin it:  scripts/fetch_engine.sh --engine sing-box --singbox-version ${tag} --sha256 $actual" >&2
    echo "     or commit it:  scripts/fetch_engine.sh --write-lock" >&2
  fi

  local out="$dest/$key/sing-box"
  mkdir -p "$out"
  if [[ "$ext" == zip ]]; then unzip -qo "$tmp/$asset" -d "$tmp/x"; else tar -xzf "$tmp/$asset" -C "$tmp"; fi
  # Archives nest a versioned directory; find the binary instead of assuming a path.
  local bin
  bin="$(find "$tmp" -type f \( -name 'sing-box' -o -name 'sing-box.exe' \) -print -quit)"
  [[ -n "$bin" ]] || { echo "fetch_engine: no sing-box binary inside $asset" >&2; return 1; }
  cp "$bin" "$out/$(basename "$bin")"
  chmod 755 "$out/$(basename "$bin")"
  printf 'sing-box %s\n' "$tag" >"$out/.version"
  record_sha sing-box "$key" "$actual" "$base/$asset"
  echo "  → $out"
}

[[ $write_lock -eq 1 && ! -f "$lock_file" ]] && printf '{}\n' >"$lock_file"
mkdir -p "$dest"

case "$want_engine" in
  xray) fetch_xray ;;
  sing-box) fetch_singbox ;;
  both) fetch_xray; fetch_singbox ;;
  *) echo "fetch_engine: --engine must be xray|sing-box|both" >&2; exit 2 ;;
esac

if [[ $write_lock -eq 1 ]]; then
  echo
  echo "packaging/engine-lock.json updated. Commit it: that file is what turns a"
  echo "silent engine swap into a build failure."
else
  cat <<'EOF'

Done. app/assets/engine/ is gitignored on purpose — these binaries go into
release artifacts, never into git. Note the licenses you are redistributing:
Xray (MPL-2.0) and sing-box (GPL-3.0) are separate processes, not linked; see
NOTICE.
EOF
fi
