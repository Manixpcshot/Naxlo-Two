#!/usr/bin/env bash
# verify-engine-config.sh — generate configs with the real builders, then have
# the real engines accept or reject them.
#
#   scripts/fetch_engine.sh --os linux --arch amd64
#   scripts/verify-engine-config.sh
#
# Why: `xray run` does not care how elegant your Dart was — it cares whether the
# JSON has the keys it expects, spelled the way it expects. Unit tests can prove
# the builder is self-consistent; only the engines prove it is *acceptable*. This
# closes the gap for the price of two subprocess calls per sample.
#
# It is a verification script, not a test suite: it needs network (once, to fetch
# engines) and two external binaries, so CI runs it as a separate advisory job.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/build/engine-samples"
xray_bin="${XRAY_BIN:-}"
singbox_bin="${SINGBOX_BIN:-}"

failures=0
checked=0
# Reported separately on purpose: if a whole engine family is skipped because its
# binary did not download, "48 configs accepted" would be a lie about coverage.
accepted=0
skipped=0

# --- 1. generate -------------------------------------------------------------
command -v dart >/dev/null 2>&1 || {
  echo "verify-engine-config: needs the Dart SDK (flutter's bundled one is fine: 'flutter' puts it on PATH)" >&2
  exit 1
}
echo "==> generating sample configs"
rm -rf "$out"
mkdir -p "$out"
(cd "$root/packages/naxlo_core" && dart pub get >/dev/null && dart run tool/gen_samples.dart "$out") || {
  echo "verify-engine-config: sample generation failed" >&2
  exit 1
}

# --- 2. find the engines -----------------------------------------------------
triple() { # os-arch guess for the asset dir fetch_engine.sh wrote
  local uname_s uname_m
  uname_s="$(uname -s)"
  uname_m="$(uname -m)"
  case "$uname_s" in
    Linux) uname_s=linux ;;
    Darwin) uname_s=macos ;;
    *) uname_s=linux ;;
  esac
  case "$uname_m" in
    x86_64|amd64) uname_m=amd64 ;;
    arm64|aarch64) uname_m=arm64 ;;
    *) uname_m=amd64 ;;
  esac
  echo "${uname_s}-${uname_m}"
}
guess="$(triple)"

find_bin() { # name  subdir
  local name="$1" sub="$2" cand
  for cand in \
    "$root/app/assets/engine/$guess/$sub/$name" \
    "$root/app/assets/engine/$guess/$name" \
    "$(command -v "$name" 2>/dev/null || true)"; do
    [[ -n "$cand" && -x "$cand" ]] && { echo "$cand"; return 0; }
  done
  return 1
}

[[ -n "$xray_bin" ]] || xray_bin="$(find_bin xray xray || true)"
[[ -n "$singbox_bin" ]] || singbox_bin="$(find_bin sing-box sing-box || true)"

if [[ -z "$xray_bin" && -z "$singbox_bin" ]]; then
  cat >&2 <<EOF
verify-engine-config: neither \`xray\` nor \`sing-box\` was found.

Fetch them next to the app assets (recommended, it is what releases ship):
  scripts/fetch_engine.sh --os linux --arch amd64
or point the script at whatever you already have:
  XRAY_BIN=/usr/local/bin/xray SINGBOX_BIN=$HOME/.local/bin/sing-box scripts/verify-engine-config.sh

Not treating "no engines" as success is the whole point: a skipped verification
looks identical to a passing one in a CI log.
EOF
  exit 1
fi

# --- 3. ask each engine about its own files ---------------------------------
verify() { # pattern  binary  args...
  local pattern="$1" bin="$2"
  shift 2
  local n=0
  for f in "$out"/$pattern; do
    [[ -e "$f" ]] || continue
    n=$((n + 1))
    checked=$((checked + 1))
    if [[ -z "$bin" ]]; then
      echo "   SKIP $(basename "$f") (no binary for this family)"
      skipped=$((skipped + 1))
      continue
    fi
    accepted=$((accepted + 1))
    local err
    if err="$("$bin" "$@" "$f" 2>&1 >/dev/null)"; then
      echo "   PASS $(basename "$f")"
    else
      echo "   FAIL $(basename "$f")"
      echo "$err" | sed 's/^/          /' | head -12
      failures=$((failures + 1))
    fi
  done
  return 0
}

echo "==> xray test  ${xray_bin:-<not found>}  (v$("$xray_bin" version 2>/dev/null | head -1 | tr -d '\n' || echo '?'))"
# `xray run -test -config F`: modern Xray has no `test` subcommand, so every config
# was marked rejected with "xray test: unknown command". `-test` validates and exits
# without binding a single port.
verify 'xray-*.json' "$xray_bin" run -test -config
echo "==> sing-box check  ${singbox_bin:-<not found>}  ($("$singbox_bin" version 2>/dev/null | head -1 || echo '?'))"
verify 'singbox-*.json' "$singbox_bin" check -c

echo
if [[ $failures -gt 0 ]]; then
  echo "verify-engine-config: $failures of $checked config(s) REJECTED by the engine." >&2
  echo "Fix the builder in packages/naxlo_core/lib/src/{xray,singbox}/ — the file is the diff." >&2
  exit 1
fi
echo "verify-engine-config: $accepted accepted, $skipped skipped for want of a binary, $failures rejected."
if [[ $skipped -gt 0 ]]; then
  echo "  (partial coverage: the skipped families were never read by an engine)" >&2
fi
