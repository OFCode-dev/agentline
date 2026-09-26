#!/bin/bash
# agentline benchmark: CPU per call on each render path.
#
#   bash bench/bench.sh [runs] [script]    default: 100 runs of ../agentline.sh
#
# The status line runs up to once a second in every open session, so what
# matters is the aggregate CPU a call burns, not its latency. Each path below
# is timed over <runs> invocations with the `time` keyword (bash reports user
# and system time through getrusage, children included). That works the same
# with GNU and BSD userlands and needs no /usr/bin/time, whose -f flag is
# GNU-only. The printed figure is (user + sys) / runs.
#
#   tick            same payload, render cache fresh: the once-a-second path
#   payload change  a new payload on each call, probe cache fresh: the path an
#                   active turn takes about once a second
#   ... fable       the same with a Fable model (the gradient model name)
#   cold probe      a new payload and AGENTLINE_PROBE_TTL=0: every host probe
#                   runs (top, df, ss, who, crontab, git, systemctl, MCP)
#
# The host layer is real: the probes see this machine, your ~/.claude.json
# MCP list and your services file, and the cwd is this checkout (a git repo).
# Only the caches are private (a scratch TMPDIR and AGENTLINE_TMP), so a run
# never disturbs a live session. Where strace exists, each path is also
# traced once to count the programs it execs and the python3 boots among
# them. The tick is also run with an empty PATH (bash >= 5), which fails if
# it needs any program beyond the `cat` that reads stdin.
#
# AGENTLINE_BENCH_BASH picks the interpreter (for example macOS /bin/bash).
# Pass an older script as [script] to compare two versions on one host.

set -u
RUNS="${1:-100}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT="${2:-$HERE/../agentline.sh}"
BENCH_BASH="${AGENTLINE_BENCH_BASH:-$BASH}"
case "$RUNS" in ''|0*|*[!0-9]*) echo "usage: bash bench/bench.sh [runs] [script]" >&2; exit 2 ;; esac
[ -f "$SCRIPT" ] || { echo "no such script: $SCRIPT" >&2; exit 2; }

W=$(mktemp -d "${TMPDIR:-/tmp}/agentline-bench.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/tmp" "$W/side" "$W/nopath"
CWD="$(cd "$HERE/.." && pwd -P)"

# An e-mail in the payload keeps the `claude auth status` fallback (a CLI cold
# start) out of the numbers; it is cached for 60 s anyway.
TPL='{"session_id":"bench-0001","session_name":"bench","cwd":"@@CWD@@","version":"3.0.24","model":{"id":"@@MODEL@@","display_name":"x"},"effort":{"level":"high"},"thinking":{"enabled":true},"context_window":{"used_percentage":42.4,"total_input_tokens":8400000,"total_output_tokens":12@@N@@},"rate_limits":{"five_hour":{"used_percentage":71,"resets_at":1790200000},"seven_day":{"used_percentage":58,"resets_at":1790208000}},"cost":{"total_cost_usd":12.468,"total_duration_ms":13320000,"total_lines_added":1204,"total_lines_removed":336},"account":{"email":"octocat@example.com"}}'
TPL="${TPL//@@CWD@@/$CWD}"
mkpayloads() {  # mkpayloads <tag> <model-id> -> $W/<tag>.<i>, i = 0..RUNS+1
  local i p="${TPL//@@MODEL@@/$2}"
  for (( i = 0; i <= RUNS + 1; i++ )); do printf '%s\n' "${p//@@N@@/$i}" > "$W/$1.$i"; done
}
mkpayloads opus claude-opus-5
mkpayloads fable claude-fable-5

agent() {  # agent <payload-file> [VAR=val...] — one call, in the scratch env
  local f="$1"; shift
  ( cd "$CWD" && env TMPDIR="$W/tmp" AGENTLINE_TMP="$W/side" ${1+"$@"} \
      "$BENCH_BASH" "$SCRIPT" < "$f" > /dev/null 2>&1 )
}
loop() {  # loop <tag> <same|vary> [VAR=val...]
  local tag="$1" mode="$2" i f; shift 2
  for (( i = 1; i <= RUNS; i++ )); do
    f="$W/$tag.$i"; [ "$mode" = same ] && f="$W/$tag.0"
    agent "$f" ${1+"$@"}
  done
}

HAVE_STRACE=0
command -v strace >/dev/null 2>&1 && strace -f -o /dev/null true >/dev/null 2>&1 && HAVE_STRACE=1
execs() {  # execs <payload-file> [VAR=val...] -> "N execs, K python3"
  local f="$1"; shift
  ( cd "$CWD" && env TMPDIR="$W/tmp" AGENTLINE_TMP="$W/side" ${1+"$@"} \
      strace -f -qq -o "$W/st" -e trace=execve "$BENCH_BASH" "$SCRIPT" < "$f" > /dev/null 2>&1 )
  awk '/execve\(/ && !/= -1 / { n++; if ($0 ~ /python3?"/) py++ }
       END { printf "%d execs, %d python3", n - 1, py }' "$W/st"
}

row() {  # row <label> <tag> <same|vary> [VAR=val...]
  local label="$1" tag="$2" mode="$3" r u s t extra=""; shift 3
  TIMEFORMAT='%3R %3U %3S'
  { time loop "$tag" "$mode" ${1+"$@"}; } 2> "$W/time"
  read -r r u s < "$W/time"
  if [ "$HAVE_STRACE" = 1 ]; then
    # Traced on a payload the loop never sent, so it takes the loop's path.
    t="$W/$tag.0"; [ "$mode" = vary ] && t="$W/$tag.$((RUNS + 1))"
    extra="  [$(execs "$t" ${1+"$@"})]"
  fi
  awk -v l="$label" -v r="$r" -v u="$u" -v s="$s" -v n="$RUNS" -v x="$extra" \
    'BEGIN { printf "%-22s %6.1f ms CPU/call  %6.1f ms wall/call%s\n", l, (u + s) * 1000 / n, r * 1000 / n, x }'
}

echo "agentline bench: $RUNS runs per path, $("$BENCH_BASH" -c 'echo "bash $BASH_VERSION"'), $(uname -s)"
echo "script: $SCRIPT"

# Tick: warm the render cache once, then every call is a cache hit.
agent "$W/opus.0" AGENTLINE_CACHE_TTL=100000 AGENTLINE_PROBE_TTL=100000
row "tick" opus same AGENTLINE_CACHE_TTL=100000 AGENTLINE_PROBE_TTL=100000
# Payload change: the probe cache stays fresh, the render cache never hits.
row "payload change" opus vary AGENTLINE_PROBE_TTL=100000
agent "$W/fable.0" AGENTLINE_PROBE_TTL=100000
row "payload change, fable" fable vary AGENTLINE_PROBE_TTL=100000
row "cold probe" opus vary AGENTLINE_PROBE_TTL=0

# Fork-free tick: with an empty PATH a tick may only fail to find `cat`
# (stdin then reads as empty, which the warm-up rendered and cached too).
if [ "$("$BENCH_BASH" -c 'echo "${BASH_VERSINFO[0]}"')" -ge 5 ]; then
  : > "$W/empty"
  agent "$W/empty" AGENTLINE_CACHE_TTL=100000 AGENTLINE_PROBE_TTL=100000
  ( cd "$CWD" && env -i PATH="$W/nopath" TMPDIR="$W/tmp" AGENTLINE_TMP="$W/side" HOME="${HOME:-/}" \
      AGENTLINE_CACHE_TTL=100000 AGENTLINE_PROBE_TTL=100000 \
      "$BENCH_BASH" "$SCRIPT" < "$W/empty" > "$W/tick.out" 2> "$W/tick.err" )
  rc=$?
  others=$(grep -v 'cat: command not found' "$W/tick.err")
  if [ "$rc" = 0 ] && [ -s "$W/tick.out" ] && [ -z "$others" ]; then
    echo "tick with an empty PATH: OK (no program needed beyond cat)"
  else
    echo "tick with an empty PATH: FAILED (rc=$rc) $others"
    exit 1
  fi
else
  echo "tick with an empty PATH: skipped (bash < 5 forks date for the clock)"
fi
