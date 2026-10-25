#!/usr/bin/env bash
# fetch_engine.sh — download the proxy engine binaries into app/assets/engine/.
#
#   scripts/fetch_engine.sh                     # latest xray + sing-box, host arch
#   scripts/fetch_engine.sh --engine xray --os windows --arch amd64
#   scripts/fetch_engine.sh --xray-version 26.9.9 --singbox-version 1.11.0
#
# Why a script instead of vendoring binaries: committing engine binaries makes
# the repo huge, ages the client against the engine, and hides which core a user
# is actually running. Why not "download at runtime": a first run that needs
# network to become functional is a bad trade for a tool people use *because*
# their network is broken. So: fetched at build time, verified, then shipped.
#
# Nothing here is executed. The app only runs what it finds in the user's
# app-support dir or an explicit path (see lib/state/engine_locator.dart).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest="$root/app/assets/engine"
xray_version="${XRAY_VERSION:-}"
singbox_version="${SINGBOX_VERSION:-}"
want_os=""
want_arch=""
want_engine="both"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine) want_engine="$2"; shift 2 ;;
    --os) want_os="$2"; shift 2 ;;
    --arch) want_arch="$2"; shift 2 ;;
    --xray-version) xray_version="$2"; shift 2 ;;
    --singbox-version) singbox_version="$2"; shift 2 ;;
    --dest) dest="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "fetch_engine: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

# --- host detection -----------------------------------------------------------
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
    386|i686) want_arch="386" ;;
    *) echo "fetch_engine: unsupported host arch '$uname_m'" >&2; exit 1 ;;
  esac
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "fetch_engine: needs '$1' on PATH" >&2; exit 1; }; }
need curl
need jq
need unzip
need tar

latest_tag() { # repo
  # || true: this runs inside a command substitution in an assignment, so a
  # non-zero exit here would abort the whole script before the friendly
  # "could not resolve latest tag" message could be printed.
  curl -fsSL --retry 3 --header "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$1/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' || true
}

sha256_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$1" | cut -d' ' -f1; }

# Matches "<asset>" against the checksum file Xray/sing-box attach to a release.
# Both publish a `checksums.txt` with lines of "<hash>  <name>"; if the asset is
# missing from it we fail rather than ship something unverified.
verify_checksum() { # asset_path checksums_path asset_name
  local asset="$1" sums="$2" name="$3"
  if [[ ! -s "$sums" ]]; then
    echo "fetch_engine: release has no checksums.txt - refusing to install unverified binary" >&2
    return 1
  fi
  local want have
  want="$(awk -v n="$name" '$2 == n || $2 == "./" n { print $1; exit }' "$sums")"
  have="$(sha256_of "$asset")"
  if [[ -z "$want" ]]; then
    echo "fetch_engine: $name not listed in checksums.txt" >&2
    return 1
  fi
  if [[ "$want" != "$have" ]]; then
    echo "fetch_engine: CHECKSUM MISMATCH for $name" >&2
    echo "  expected $want" >&2
    echo "  actual   $have" >&2
    return 1
  fi
  echo "  sha256 verified: $have"
}

fetch_xray() {
  local version="$xray_version"
  [[ -n "$version" ]] || version="$(latest_tag XTLS/Xray-core)"
  [[ -n "$version" ]] || { echo "fetch_engine: could not resolve latest Xray tag (rate limited?)" >&2; return 1; }
  local arch tag
  case "$want_arch" in
    amd64) arch="64" ;;
    arm64) arch="arm64-v8a" ;;
    armv7) arch="arm32-v7a" ;;
    386) arch="32" ;;
  esac
  tag="${version#v}"
  local base="https://github.com/XTLS/Xray-core/releases/download/v${tag}"
  local asset="Xray-${want_os}-${arch}.zip"
  local tmp; tmp="$(mktemp -d)"
  echo "xray v${tag} (${want_os}/${arch})"
  curl -fsSL --retry 3 -o "$tmp/$asset" "$base/$asset"
  curl -fsSL --retry 3 -o "$tmp/checksums.txt" "$base/checksums.txt" || true
  verify_checksum "$tmp/$asset" "$tmp/checksums.txt" "$asset"
  local out="$dest/${want_os}-${want_arch}/xray"
  mkdir -p "$out"
  unzip -qo "$tmp/$asset" -d "$out"
  chmod 755 "$out/xray" 2>/dev/null || true
  printf 'xray %s\n' "$tag" >"$out/.version"
  rm -rf "$tmp"
  echo "  → $out"
}

fetch_singbox() {
  local version="$singbox_version"
  [[ -n "$version" ]] || version="$(latest_tag SagerNet/sing-box)"
  [[ -n "$version" ]] || { echo "fetch_engine: could not resolve latest sing-box tag" >&2; return 1; }
  local arch tag
  case "$want_arch" in
    amd64) arch="amd64" ;;
    arm64) arch="arm64" ;;
    armv7) arch="armv7" ;;
    386) arch="386" ;;
  esac
  tag="${version#v}"
  local ext=tar.gz asset
  case "$want_os" in
    windows) ext=zip ;;
    macos) asset="sing-box-${tag}-darwin-universal.tar.gz" ;;
  esac
  asset="${asset:-sing-box-${tag}-${want_os}-${arch}.tar.gz}"
  [[ "$want_os" == "windows" ]] && asset="sing-box-${tag}-${want_os}-${arch}.zip"
  local base="https://github.com/SagerNet/sing-box/releases/download/v${tag}"
  local tmp; tmp="$(mktemp -d)"
  echo "sing-box ${tag} (${want_os}/${arch})"
  curl -fsSL --retry 3 -o "$tmp/$asset" "$base/$asset"
  # sing-box publishes per-asset .sha256sum next to the archive.
  curl -fsSL --retry 3 -o "$tmp/checksums.txt" "$base/$asset.sha256sum" || true
  if [[ -s "$tmp/checksums.txt" ]]; then
    local want have
    want="$(awk '{print $1; exit}' "$tmp/checksums.txt")"
    have="$(sha256_of "$tmp/$asset")"
    if [[ "$want" != "$have" ]]; then
      echo "fetch_engine: CHECKSUM MISMATCH for $asset (want $want, got $have)" >&2
      return 1
    fi
    echo "  sha256 verified: $have"
  fi
  local out="$dest/${want_os}-${want_arch}/sing-box"
  mkdir -p "$out"
  if [[ "$ext" == zip ]]; then unzip -qo "$tmp/$asset" -d "$tmp/x"; else tar -xzf "$tmp/$asset" -C "$tmp"; fi
  # Archives nest a versioned directory; find the binary instead of assuming.
  local bin; bin="$(find "$tmp" -type f \( -name 'sing-box' -o -name 'sing-box.exe' \) -print -quit)"
  [[ -n "$bin" ]] || { echo "fetch_engine: no sing-box binary inside $asset" >&2; return 1; }
  cp "$bin" "$out/$(basename "$bin")"
  chmod 755 "$out/$(basename "$bin")"
  printf 'sing-box %s\n' "$tag" >"$out/.version"
  rm -rf "$tmp"
  echo "  → $out"
}

mkdir -p "$dest"
case "$want_engine" in
  xray) fetch_xray ;;
  sing-box) fetch_singbox ;;
  both) fetch_xray; fetch_singbox ;;
  *) echo "fetch_engine: --engine must be xray|sing-box|both" >&2; exit 2 ;;
esac

cat <<EOF

Done. app/assets/engine/ is gitignored on purpose — these binaries are built
into release artifacts by CI, never committed. Note the licenses you are
redistributing: Xray (MPL-2.0) and sing-box (GPL-3.0) are separate processes,
not linked; see NOTICE.
EOF
