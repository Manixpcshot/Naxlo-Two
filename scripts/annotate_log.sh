#!/usr/bin/env bash
# Pack a test/build log into a few GitHub check annotations.
#
# Why this exists: GitHub keeps only ~10 annotations per check run and drops the
# rest without saying so, so the obvious "one ::error:: per failing line" trick
# reported 4 of 18 test failures and left the log's actual error format guessable
# (it silently matched nothing twice, which is how a whole CI round was lost).
# Here each annotation carries a *block* of lines joined with %0A, so ten
# annotations hold hundreds of lines, and the pattern matches diagnostic words
# rather than one tool's column layout.
set -u

usage() {
  cat <<'USAGE'
usage: scripts/annotate_log.sh <log> [--level failure|warning] [--grep ERE]
                               [--ctx N] [--max M]

  --grep  ERE of lines worth showing (default: test/build failures)
  --ctx   context lines to keep after each hit (default 4)
  --max   maximum number of annotations (default 6)
USAGE
}

log=""
# "failure" is the *REST annotation level*; the workflow command is `::error::`.
# Emitting `::failure::` is a no-op GitHub prints as plain log text — which is how
# one full CI round came back showing nothing but "Process completed with exit
# code 1". The name is accepted here and translated, so the flag reads naturally
# at both layers.
level="error"
ctx=4
max=6
pattern='(\[E\]$|Expected:|Actual:|Which:|^\s*error|Error:|error •|error -|FAILED|failed|Exception|unhandled|Cannot open|No such file)'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --level) level="${2:-failure}"; shift 2 ;;
    --grep) pattern="${2:-}"; shift 2 ;;
    --ctx) ctx="${2:-4}"; shift 2 ;;
    --max) max="${2:-6}"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    -*) echo "annotate_log: unknown flag $1" >&2; usage; exit 2 ;;
    *)
      if [[ -z "$log" ]]; then log="$1"; shift; else usage; exit 2; fi
      ;;
  esac
done

case "$level" in
  error | fail | failure) level="error" ;;
  warning | warn) level="warning" ;;
  notice | info) level="notice" ;;
  *) echo "annotate_log: --level must be error, warning or notice" >&2; exit 2 ;;
esac

if [[ -z "$log" || ! -f "$log" ]]; then
  echo "::${level}::annotate_log: no log file at '${log:-<none>}'"
  exit 0
fi

# % must become %25, \r must go: workflow-command parsing eats raw % and CR.
clean() { sed -E 's/\r//g; s/^[[:space:]]+//; s/[[:space:]]+$//' | sed 's/%/%25/g'; }

# 1) A one-annotation inventory: which tests/steps are red at all. Even if the
#    detail blocks below overflow, this alone says what broke.
inv="$(grep -E '\[E\]$|^(Error|Failed to|Build failed)' "$log" | clean | head -40)"
if [[ -n "$inv" ]]; then
  packed="$(printf '%s\n' "$inv" | awk '{printf "%s%s", (NR>1 ? "%0A" : ""), $0}')"
  echo "::${level}::failing tests/steps: ${packed}"
fi

# 2) Packed context blocks. awk buffers lines and flushes a whole annotation
#    when it approaches GitHub's ~2 KiB message limit, so nothing is split
#    mid-message.
grep -E -A "$ctx" -- "$pattern" "$log" 2>/dev/null |
  grep -v '^--$' |
  clean |
  head -400 |
  awk -v lvl="$level" -v maxa="$max" '
    {
      line = $0
      gsub(/\|/, "!", line)
      if (buf != "" && length(buf) + length(line) > 1500) {
        printf "::%s::%s\n", lvl, buf
        buf = ""
        n++
        if (n >= maxa) { exit }
      }
      buf = (buf == "" ? line : buf "%0A" line)
    }
    END {
      if (buf != "" && n < maxa) printf "::%s::%s\n", lvl, buf
    }'

# Never silent: an annotation guard that prints nothing when the log's format
# changes is indistinguishable from a passing step. Say so, and show the tail.
# The guard has to ask about *the same pattern the packer used*, case-insensitively.
# With its own narrower list it called "WARNING - no verifiable digest" a
# non-diagnostic and printed "nothing matched" over a log that was full of them —
# which is how a real failure looked like an empty one.
if ! grep -qiE -- "$pattern" "$log"; then
  tail="$(tail -12 "$log" | clean | awk '{printf "%s%s", (NR > 1 ? "%0A" : ""), $0}')"
  echo "::${level}::annotate_log: nothing matched the diagnostic pattern; raw tail:%0A${tail}"
fi
