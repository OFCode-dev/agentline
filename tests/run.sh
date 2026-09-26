#!/bin/bash
# agentline test suite — bash + python3 only, no bats, no network.
#
#   bash tests/run.sh            run every check
#   bash tests/run.sh --update   rewrite tests/golden/ from the current output
#                                (review the diff before committing it)
#
# The suite runs the real agentline.sh, install.sh and hooks as black boxes,
# under whichever bash runs this file: `/bin/bash tests/run.sh` on macOS tests
# bash 3.2, `bash tests/run.sh` on Linux tests bash 5. AGENTLINE_TEST_BASH
# overrides the interpreter the scripts under test are started with.
#
# Hermetic by construction. Every render runs under `env -i` with a fresh
# temp dir as TMPDIR, a fixture HOME (no ~/.claude.json, no services conf, no
# local.sh), an empty non-git cwd, TZ=UTC and LC_ALL=C. The host layer — CPU,
# RAM, disk, ports, services, MCP, git — is seeded through the script's own
# probe cache (render_<sid>.probes, AGENTLINE_PROBE_TTL=3600), so none of the
# host probes run; the hook side files follow AGENTLINE_TMP into the temp dir;
# and an empty cached e-mail plus a `claude` shim that only logs keep the CLI
# fallback from ever reaching the real account. What is left in the output is
# a function of the fixture alone, except the clock and date, which are masked.
#
# Bash 3.2 compatible like the scripts it tests: no associative arrays, no
# mapfile, no ${var,,}, no $EPOCHSECONDS.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TESTS="$ROOT/tests"
FIX="$TESTS/fixtures"
GOLD="$TESTS/golden"
WIDTHS="120 80 40"

UPDATE=0
case "${1:-}" in
  '') ;;
  --update) UPDATE=1 ;;
  -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "usage: bash tests/run.sh [--update]" >&2; exit 2 ;;
esac

TEST_BASH="${AGENTLINE_TEST_BASH:-$BASH}"
TEST_BASH_MAJOR=$("$TEST_BASH" -c 'echo "${BASH_VERSINFO[0]}"')

# pwd -P: macOS hands out /var/folders/… where /var is a symlink. Under
# `env -i` bash rebuilds $PWD from getcwd(), i.e. the physical path, and the
# probe cache is only honoured when its recorded cwd matches byte for byte.
T=$(mktemp -d "${TMPDIR:-/tmp}/agentline-test.XXXXXX") || exit 1
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT

HOME_F="$T/home"            # fixture HOME
WORK="$HOME_F/work"         # cwd of every render; shown as ~/work
TMP_F="$T/tmp"              # TMPDIR of every render
SIDE="$T/side"              # AGENTLINE_TMP: hook side files
SHIM="$T/shim"              # prepended to PATH
PAY="$T/payload"            # fixture templates, placeholders filled in
mkdir -p "$WORK" "$TMP_F" "$SIDE" "$SHIM" "$PAY" "$T/golden"
CACHE_DIR="$TMP_F/agentline-${EUID:-0}"
mkdir -m 700 "$CACHE_DIR"

# `claude auth status` is the one fallback that would read the real account.
# The shim answers nothing and records that it was asked, so a test can
# assert the fallback stayed off.
cat > "$SHIM/claude" <<EOF
#!/bin/sh
echo "\$*" >> "$T/claude-calls"
exit 1
EOF
chmod +x "$SHIM/claude"
PATH_F="$SHIM:$PATH"

# The probe variable list is read from agentline.sh itself, so a probe added
# there is seeded (empty unless a probe set names it) rather than silently
# re-enabling a real host command in the tests.
PROBE_VARS=$(sed -n 's/^PROBE_VARS="\(.*\)"$/\1/p' "$ROOT/agentline.sh")
ESC=$(printf '\033')

# === Reporting ===
n_pass=0; n_fail=0; n_skip=0
pass() { n_pass=$((n_pass + 1)); }
fail() { n_fail=$((n_fail + 1)); echo "FAIL: $*"; }
skip() { n_skip=$((n_skip + 1)); echo "SKIP: $*"; }
check() {  # check <name> <command...> — pass when the command succeeds
  local name="$1"; shift
  if "$@"; then pass; else fail "$name"; fi
}

# === Helpers ===
run_env() {  # run a command in the hermetic environment; extra VAR=val first
  env -i PATH="$PATH_F" HOME="$HOME_F" TMPDIR="$TMP_F" AGENTLINE_TMP="$SIDE" \
    TZ=UTC LC_ALL=C AGENTLINE_PROBE_TTL=3600 "$@"
}

# The session id exactly as agentline.sh derives it — parameter expansion on
# the raw bytes, before any JSON parse — because it names the cache files.
sid_of() {
  local input sid=default
  input=$(cat "$1")
  case "$input" in
    *'"session_id"'*)
      sid="${input#*\"session_id\"}"; sid="${sid#*\"}"; sid="${sid%%\"*}"
      case "$sid" in ''|*[!a-zA-Z0-9_-]*) sid=default ;; esac ;;
  esac
  printf '%s' "$sid"
}

# Fill a fixture template: @@HOME@@, @@CWD@@, @@FIXTURES@@ and @@NOW+<s>@@
# (an epoch <s> seconds from now, for reset timestamps rendered relative to
# the clock: +7230 s renders as 2h0m however long the suite takes to get
# there). The file is copied byte for byte otherwise — the malformed and empty
# fixtures must reach the script exactly as written.
fill() {  # fill <template> <out>
  python3 - "$1" "$2" "$HOME_F" "$WORK" "$FIX" <<'PYEOF'
import re, sys, time
src, dst, home, cwd, fix = sys.argv[1:6]
data = open(src, 'rb').read().decode('utf-8')
data = data.replace('@@HOME@@', home).replace('@@CWD@@', cwd).replace('@@FIXTURES@@', fix)
now = int(time.time())
data = re.sub(r'@@NOW\+(\d+)@@', lambda m: str(now + int(m.group(1))), data)
open(dst, 'wb').write(data.encode('utf-8'))
PYEOF
}

# Seed the probe cache for <sid> from a probe set, in the format agentline.sh
# writes: epoch, cwd, then one `var=<printf %q>` line per PROBE_VARS entry.
seed_probes() {  # seed_probes <sid> <set-name>
  (
    for _v in $PROBE_VARS; do eval "$_v="; done
    # shellcheck source=/dev/null
    . "$FIX/probes/$2.sh"
    body=""
    for _v in $PROBE_VARS; do
      printf -v _q '%q' "${!_v}"
      body="${body}${_v}=${_q}"$'\n'
    done
    printf '%s\n%s\n%s' "$(date +%s)" "$WORK" "$body" > "$CACHE_DIR/render_$1.probes"
  )
}

# Reset per-render state: no render cache (so every width is a full render),
# fresh probes, the fixture's side files and a fresh empty e-mail cache.
prepare() {  # prepare <fixture-name> <filled-payload>
  local name="$1" sid pset now label key
  sid=$(sid_of "$2")
  rm -f "$CACHE_DIR"/render_* "$SIDE"/claude_*
  pset=busy
  [ -f "$FIX/payloads/$name.probes" ] && pset=$(cat "$FIX/payloads/$name.probes")
  seed_probes "$sid" "$pset"
  [ -f "$FIX/payloads/$name.wordcount" ] && cp "$FIX/payloads/$name.wordcount" "$SIDE/claude_wordcount.txt"
  if [ -f "$FIX/payloads/$name.agents" ]; then
    now=$(date +%s)
    while IFS= read -r label; do
      [ -n "$label" ] && printf '%s %s\n' "$now" "$label"
    done < "$FIX/payloads/$name.agents" > "$SIDE/claude_agents.txt"
  fi
  key="$HOME_F/.claude"
  : > "$CACHE_DIR/email.${key//[!A-Za-z0-9]/_}"
}

render() {  # render <payload> <width> [VAR=val...] -> $T/out $T/err $rc
  local p="$1" w="$2"; shift 2
  # ${1+"$@"}: bash 3.2 under `set -u` rejects an empty "$@".
  ( cd "$WORK" && run_env AGENTLINE_WIDTH="$w" ${1+"$@"} "$TEST_BASH" "$ROOT/agentline.sh" \
      < "$p" > "$T/out" 2> "$T/err" )
  rc=$?
}

# ANSI stripped, clock and date masked. BSD sed has no \x1b, hence $ESC.
normalize() {  # normalize <in> <out>
  sed -e "s/${ESC}\[[0-9;]*m//g" "$1" \
    | sed -E -e 's/[0-9]{2}:[0-9]{2}:[0-9]{2}/HH:MM:SS/g' \
             -e 's#[0-9]{2}/[0-9]{2}/[0-9]{4} [A-Z][a-z]{2}#DD/MM/YYYY Day#g' > "$2"
  # The script prints no trailing newline; the golden files end with one.
  if [ -s "$2" ] && [ -n "$(tail -c 1 "$2")" ]; then echo >> "$2"; fi
  return 0
}

# Wrap contract for lines 3+ (the Claude and system layers): rows break only
# at " │ " boundaries — the narrow render's segments, in order, are exactly
# the unwrapped render's — and a row wider than the budget is always a single
# segment, the one legitimate overflow (a segment is never split). Widths are
# measured the way the script measures them: wide glyphs count two cells.
check_wrap() {  # check_wrap <narrow-normalized> <wide-normalized> <width>
  python3 - "$1" "$2" "$3" <<'PYEOF'
import sys, unicodedata
narrow = open(sys.argv[1], encoding='utf-8').read()
wide = open(sys.argv[2], encoding='utf-8').read()
width = int(sys.argv[3])
SEP = ' │ '
def vis(s):
    return sum(2 if unicodedata.east_asian_width(c) in ('W', 'F') else 1 for c in s)
def segs(rows):
    return [s for r in rows for s in r.split(SEP)]
n_rows, w_rows = narrow.splitlines()[2:], wide.splitlines()[2:]
if segs(n_rows) != segs(w_rows):
    sys.exit('segments differ:\n  %r\n  %r' % (segs(n_rows), segs(w_rows)))
for r in n_rows:
    if vis(r) > width and SEP in r:
        sys.exit('row over %d cells holds more than one segment: %r' % (width, r))
PYEOF
}

# ===========================================================================
# 1. Syntax
# ===========================================================================
for f in "$ROOT/agentline.sh" "$ROOT/install.sh" "$ROOT"/hooks/*.sh "$TESTS/run.sh"; do
  check "bash -n ${f#"$ROOT"/}" "$TEST_BASH" -n "$f"
done

# ===========================================================================
# 2. Golden renders: every fixture at every width
# ===========================================================================
for tpl in "$FIX"/payloads/*.json; do
  name=$(basename "$tpl" .json)
  p="$PAY/$name.json"
  fill "$tpl" "$p"

  prepare "$name" "$p"
  render "$p" 10000
  normalize "$T/out" "$T/wide"

  for w in $WIDTHS; do
    label="$name @ $w"
    prepare "$name" "$p"
    render "$p" "$w"
    check "$label: exit 0 (got $rc)" [ "$rc" = 0 ]
    if [ -s "$T/err" ]; then
      fail "$label: stderr not empty: $(head -c 300 "$T/err")"
    else
      pass
    fi
    normalize "$T/out" "$T/got"
    g="$GOLD/$name.w$w.txt"
    if [ "$UPDATE" = 1 ]; then
      cp "$T/got" "$T/golden/$name.w$w.txt"
      pass
    elif [ ! -f "$g" ]; then
      fail "$label: no golden file ${g#"$ROOT"/} (run: bash tests/run.sh --update)"
    elif cmp -s "$T/got" "$g"; then
      pass
    else
      fail "$label: output differs from ${g#"$ROOT"/}"
      diff -u "$g" "$T/got" | head -n 20 | sed 's/^/    /'
    fi
    if msg=$(check_wrap "$T/got" "$T/wide" "$w" 2>&1); then pass; else fail "$label: wrap: $msg"; fi
    if grep -q '@@AGENTLINE_' "$T/got"; then fail "$label: placeholder leaked"; else pass; fi
  done

  # A tick with the same payload is served from the render cache and must be
  # indistinguishable from the full render once the clock is masked.
  prepare "$name" "$p"
  render "$p" 120; normalize "$T/out" "$T/first"
  render "$p" 120; normalize "$T/out" "$T/tick"
  check "$name: cached tick exit 0" [ "$rc" = 0 ]
  check "$name: cached tick equals full render" cmp -s "$T/first" "$T/tick"
done

if [ "$UPDATE" = 1 ]; then
  mkdir -p "$GOLD"
  rm -f "$GOLD"/*.txt
  cp "$T"/golden/*.txt "$GOLD"/
  echo "UPDATED: $(ls "$T"/golden | wc -l | tr -d ' ') golden files in ${GOLD#"$ROOT"/}"
fi

# Nothing in the payload may reach a shell: the parse eval is shlex-quoted
# and every value is printed, never executed.
for f in pwned pwned2 pwned3 pwned4; do
  if [ -e "$WORK/$f" ] || [ -e "$HOME_F/$f" ] || [ -e "$ROOT/$f" ]; then
    fail "hostile payload executed: $f exists"
  else
    pass
  fi
done
check "claude CLI fallback never ran" [ ! -e "$T/claude-calls" ]

# Colour is stripped from the goldens, so the context warning's colour is
# asserted on the raw render: exceeds_200k_tokens on a 1M window forces the
# yellow ⚠️ at 25%; on a 200k window the same flag is ignored (green 📊).
ctx_raw() {  # ctx_raw <fixture> -> raw render in $T/out
  fill "$FIX/payloads/$1.json" "$PAY/$1.json"
  prepare "$1" "$PAY/$1.json"
  render "$PAY/$1.json" 120
}
ctx_raw one-million-over-200k
check "1M window over 200k: yellow warning" grep -q "${ESC}\[1;33m⚠️  25%" "$T/out"
ctx_raw standard-window
check "200k window: exceeds flag ignored, green" grep -q "${ESC}\[1;32m📊 30%" "$T/out"
# Garbage in numeric fields hides those segments instead of printing "0%"
# (stderr staying empty is already checked by the golden loop).
ctx_raw bad-numbers
if grep -qE '📊|⚠️ |💰|⏱️|📥|S:' "$T/out"; then
  fail "non-numeric fields leaked a segment"
else
  pass
fi

# Terminal-escape injection: the escapes fixture puts literal ESC/BEL/C1 and
# the backslash forms `printf %b` expands (\033, \e, \x1b, \a) into the
# session name, model, version, effort, e-mail, branch, remote, MCP names,
# dev-port process names and an agent label. In the raw render the only
# escapes allowed are the script's own SGR colour codes; nothing else from
# C0/DEL/C1 may survive, and no backslash may be left for %b to act on. The
# tainted segments must still render (cleaned), not vanish.
ctx_raw escapes
check "escapes: exit 0 (got $rc)" [ "$rc" = 0 ]
if msg=$(python3 - "$T/out" <<'PYEOF' 2>&1
import re, sys
s = open(sys.argv[1], 'rb').read().decode('utf-8')
rest = re.sub(r'\x1b\[[0-9;]*m', '', s)
bad = sorted({hex(ord(c)) for c in rest if c != '\n' and (ord(c) < 0x20 or 0x7f <= ord(c) <= 0x9f)})
if bad:
    sys.exit('control characters survived: %s' % ', '.join(bad))
if '\\' in rest:
    sys.exit('backslash survived')
for want in ('feat/]0;pwned-title-xe[5m', 'own033[2Jer/reepo@', 'Evil[41m e[7mModel',
             'evil[2Jmcp', 'node033[31m(3000)', 'claude --resume esc-0001'):
    if want not in rest:
        sys.exit('segment missing: %r' % want)
PYEOF
); then pass; else fail "escapes: $msg"; fi

# ===========================================================================
# 3. Render-cache fast path
# ===========================================================================
p="$PAY/full.json"
sid=$(sid_of "$p")
prepare full "$p"
render "$p" 120
# Prove a tick is served from the cache, not re-rendered: replace the cached
# body with a marker and expect it back with the clock re-stamped.
render_file="$CACHE_DIR/render_$sid.render"
ts=$(head -n 1 "$render_file")
printf '%s\n%s' "$ts" 'CACHED @@AGENTLINE_CLOCK@@' > "$render_file"
render "$p" 120
check "tick serves the cached body" grep -Eq '^CACHED [0-9]{2}:[0-9]{2}:[0-9]{2}$' "$T/out"
# Expired (epoch 0) -> full render again.
printf '%s\n%s' 0 'CACHED @@AGENTLINE_CLOCK@@' > "$render_file"
render "$p" 120
check "expired cache re-renders" grep -q 'Opus 5' "$T/out"
# A changed payload invalidates on the spot, whatever the cache age.
printf '%s\n%s' "$(date +%s)" 'CACHED @@AGENTLINE_CLOCK@@' > "$render_file"
sed 's/"used_percentage":42.4/"used_percentage":43/' "$p" > "$T/changed.json"
render "$T/changed.json" 120
check "payload change bypasses the cache" grep -q '43%' "$T/out"

# Fork count. Only strace sees forks from $(...) and subshells — a PATH shim
# sees execs alone — so this runs where strace exists (the Linux CI job).
# The baseline is the script's first line, `input=$(cat)`: one fork, one exec
# of cat. bash >= 5 then needs nothing else ($EPOCHSECONDS, printf %()T);
# older bash pays two `date` forks for the clock.
if ! command -v strace >/dev/null 2>&1; then
  skip "fast-path fork count: strace not installed"
elif ! strace -f -o /dev/null true >/dev/null 2>&1; then
  skip "fast-path fork count: strace cannot trace here (ptrace denied)"
else
  count_procs() {  # count_procs <strace-log> -> "forks prog,prog,..."
    python3 - "$1" <<'PYEOF'
import os, re, sys
forks, progs = 0, []
for line in open(sys.argv[1], errors='replace'):
    if re.search(r'\b(clone3?|v?fork)\(', line):
        forks += 1
    m = re.search(r'execve\("([^"]+)"', line)
    if m and '= -1 ' not in line:
        progs.append(os.path.basename(m.group(1)))
print(forks, ','.join(progs[1:]))  # progs[0] is the traced bash itself
PYEOF
  }
  strace_render() {  # strace_render <payload> <log>
    ( cd "$WORK" && run_env AGENTLINE_WIDTH=120 strace -f -qq -o "$2" \
        -e trace=clone,clone3,fork,vfork,execve "$TEST_BASH" "$ROOT/agentline.sh" \
        < "$1" > /dev/null 2>&1 )
  }
  prepare full "$p"
  strace_render "$p" "$T/st-full"
  strace_render "$p" "$T/st-tick"
  read -r full_forks full_progs <<< "$(count_procs "$T/st-full")"
  read -r tick_forks tick_progs <<< "$(count_procs "$T/st-tick")"
  if [ "$TEST_BASH_MAJOR" -ge 5 ]; then max_forks=1; allowed='cat'; else max_forks=3; allowed='cat date'; fi
  check "strace sees the full render's forks ($full_forks)" [ "$full_forks" -gt 5 ]
  check "fast path: at most $max_forks fork(s), got $tick_forks ($tick_progs)" [ "$tick_forks" -le "$max_forks" ]
  bad=""
  for prog in ${tick_progs//,/ }; do
    case " $allowed " in *" $prog "*) ;; *) bad="$bad $prog" ;; esac
  done
  check "fast path execs only [$allowed], got [$tick_progs]" [ -z "$bad" ]
  # The seeded probe cache must keep every host probe from running.
  leaked=""
  for prog in ${full_progs//,/ }; do
    case "$prog" in top|df|ss|lsof|who|crontab|git|systemctl|pgrep|claude|vm_stat|sysctl) leaked="$leaked $prog" ;; esac
  done
  check "seeded probes: no host probe ran (got:$leaked)" [ -z "$leaked" ]
fi

# ===========================================================================
# 3b. Opt-in /usage fetch: claim file, detached refresh
# ===========================================================================
# No network: fake credentials plus a sitecustomize that replaces urlopen
# with a canned /usage reply after FAKE_USAGE_DELAY seconds. It patches only
# urlopen, so every other python3 the render runs is unaffected.
mkdir -p "$T/usagehook"
cat > "$T/usagehook/sitecustomize.py" <<'EOF'
import io, json, os, time, urllib.request
def _fake(req, timeout=None):
    time.sleep(float(os.environ.get('FAKE_USAGE_DELAY', '0')))
    return io.BytesIO(json.dumps({'limits': [{'kind': 'weekly_scoped',
        'scope': {'model': {'display_name': 'Fable'}}, 'percent': 63}]}).encode())
urllib.request.urlopen = _fake
EOF
mkdir -p "$HOME_F/.claude"
echo '{"claudeAiOauth": {"accessToken": "fake-token"}}' > "$HOME_F/.claude/.credentials.json"
ukey="$HOME_F/.claude"; UCACHE="$CACHE_DIR/usage.${ukey//[!A-Za-z0-9]/_}"; UCLAIM="$UCACHE.claim"
age_file() {  # age_file <file> <seconds-old>
  python3 -c 'import os, sys, time; t = time.time() - int(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$1" "$2"
}
wait_for() {  # wait_for <seconds> <command...> — poll until it succeeds
  local n=$(( $1 * 10 )); shift
  while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.1; n=$((n - 1)); done
  return 1
}
cache_is() { [ "$(cat "$UCACHE" 2>/dev/null)" = "$1" ]; }
p="$PAY/minimal.json"
urender() { render "$p" 120 AGENTLINE_USAGE_API=1 AGENTLINE_USAGE_TTL=300 PYTHONPATH="$T/usagehook" ${1+"$@"}; }

# Expired cache, no claim: the previous figure is shown while a detached
# fetch runs; the render does not wait for it, and it lands afterwards.
prepare minimal "$p"; rm -f "$UCLAIM"
printf 37 > "$UCACHE"; age_file "$UCACHE" 310
urender FAKE_USAGE_DELAY=2
check "usage: stale figure shown during the refresh" grep -q 'F:37%' "$T/out"
check "usage: render did not wait for the fetch" cache_is 37
check "usage: claim recorded in its own file" [ -f "$UCLAIM" ]
check "usage: detached fetch lands after the render" wait_for 8 cache_is 63
check "usage: claim dropped after the fetch" wait_for 2 [ ! -e "$UCLAIM" ]
prepare minimal "$p"
urender
check "usage: fresh result rendered" grep -q 'F:63%' "$T/out"

# A live claim (another session is fetching) serves the old value and
# starts no second fetch.
prepare minimal "$p"
printf 41 > "$UCACHE"; age_file "$UCACHE" 310
date +%s > "$UCLAIM"
urender
check "usage: live claim serves the old value" grep -q 'F:41%' "$T/out"
sleep 1
check "usage: live claim starts no second fetch" cache_is 41
# An abandoned claim (render killed before it could fetch) ages out.
echo $(( $(date +%s) - 60 )) > "$UCLAIM"
prepare minimal "$p"
urender
check "usage: abandoned claim is retaken" wait_for 8 cache_is 63

# Past TTL + 60 s grace an unconfirmed figure is hidden.
prepare minimal "$p"
printf 55 > "$UCACHE"; age_file "$UCACHE" 420
date +%s > "$UCLAIM"
urender
check "usage: figure past the grace is hidden" sh -c "! grep -q 'F:' '$T/out'"

# Claude Code cancels an in-flight render; killing the render's whole
# process group must not abort the fetch (it runs in its own session).
if command -v setsid >/dev/null 2>&1; then
  prepare minimal "$p"; rm -f "$UCLAIM"
  printf 37 > "$UCACHE"; age_file "$UCACHE" 310
  ( cd "$WORK" && exec setsid env -i PATH="$PATH_F" HOME="$HOME_F" TMPDIR="$TMP_F" AGENTLINE_TMP="$SIDE" \
      TZ=UTC LC_ALL=C AGENTLINE_PROBE_TTL=3600 AGENTLINE_WIDTH=120 AGENTLINE_USAGE_API=1 \
      PYTHONPATH="$T/usagehook" FAKE_USAGE_DELAY=2 "$TEST_BASH" "$ROOT/agentline.sh" \
      < "$p" > /dev/null 2>&1 ) &
  rpid=$!
  wait "$rpid"
  kill -TERM -- "-$rpid" 2>/dev/null
  check "usage: fetch survives a kill of the render's process group" wait_for 8 cache_is 63
else
  skip "usage: process-group kill: setsid not installed"
fi
rm -f "$HOME_F/.claude/.credentials.json" "$UCACHE" "$UCLAIM"

# The daily sweep repairs modes a pre-umask release left behind.
prepare minimal "$p"
echo old > "$CACHE_DIR/legacy.cache"; chmod 644 "$CACHE_DIR/legacy.cache"
chmod 755 "$CACHE_DIR"; rm -f "$CACHE_DIR/.pruned"
render "$p" 120
case "$(ls -l "$CACHE_DIR/legacy.cache")" in -rw-------*) pass ;; *) fail "prune: cache file not repaired to 600: $(ls -l "$CACHE_DIR/legacy.cache")" ;; esac
case "$(ls -ld "$CACHE_DIR")" in drwx------*) pass ;; *) fail "prune: cache dir not repaired to 700: $(ls -ld "$CACHE_DIR")" ;; esac
rm -f "$CACHE_DIR/legacy.cache"

# ===========================================================================
# 4. Hooks and the AGENTLINE_TMP seam
# ===========================================================================
hook_env() { env -i PATH="$PATH_F" HOME="$HOME_F" AGENTLINE_TMP="$SIDE" "$@"; }
rm -f "$SIDE"/claude_*
printf '%s\n' \
  '{"type":"user","message":{"content":"one two three"}}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"four five"},{"type":"tool_use","text":"not counted"}]}}' \
  '{"type":"system","message":{"content":"not counted either"}}' \
  'not json' > "$T/transcript.jsonl"
echo "{\"transcript_path\":\"$T/transcript.jsonl\"}" | hook_env "$TEST_BASH" "$ROOT/hooks/wordcount-hook.sh"
check "wordcount hook writes \$AGENTLINE_TMP" [ "$(cat "$SIDE/claude_wordcount.txt" 2>/dev/null)" = "3 2" ]
echo 'garbage' | hook_env "$TEST_BASH" "$ROOT/hooks/wordcount-hook.sh"
check "wordcount hook on garbage writes 0 0" [ "$(cat "$SIDE/claude_wordcount.txt" 2>/dev/null)" = "0 0" ]

AGENT="$ROOT/hooks/agentline-agent.sh"
hook_env "$TEST_BASH" "$AGENT" add "external run"
hook_env "$TEST_BASH" "$AGENT" add "external run"
check "registry add is idempotent" [ "$(grep -c 'external run' "$SIDE/claude_agents.txt")" = 1 ]
echo '{"tool_name":"Agent","session_id":"s1","tool_input":{"description":"subagent one"}}' \
  | hook_env "$TEST_BASH" "$ROOT/hooks/agent-tracker-hook.sh"
check "tracker registers a subagent" grep -q 'subagent one' "$SIDE/claude_agents.txt"
echo '{"session_id":"s1"}' | hook_env "$TEST_BASH" "$ROOT/hooks/agent-tracker-hook.sh"
check "Stop clears the session's own subagent" sh -c "! grep -q 'subagent one' '$SIDE/claude_agents.txt'"
check "Stop keeps an external agent" grep -q 'external run' "$SIDE/claude_agents.txt"
hook_env "$TEST_BASH" "$AGENT" remove "external run"
check "registry remove" sh -c "! grep -q 'external run' '$SIDE/claude_agents.txt'"
hook_env CLAUDE_AGENTS_FILE="$T/custom-agents.txt" "$TEST_BASH" "$AGENT" add "relocated"
check "CLAUDE_AGENTS_FILE beats AGENTLINE_TMP" grep -q relocated "$T/custom-agents.txt"
prepare minimal "$PAY/minimal.json"
render "$PAY/minimal.json" 120 CLAUDE_AGENTS_FILE="$T/custom-agents.txt"
check "reader honours CLAUDE_AGENTS_FILE" grep -q 'relocated' "$T/out"

# --- Registry lock -----------------------------------------------------------
# Run under a PATH with no flock (macOS has none): every tool the registry
# needs is linked in, flock is not. A second PATH also replaces mv with one
# that always fails, which makes a stale lock unbreakable.
NOFLOCK="$T/noflock"; MVFAIL="$T/mvfail"
mkdir -p "$NOFLOCK" "$MVFAIL"
for tool in env date stat mkdir rmdir mv rm awk mktemp chmod wc tail sleep dirname cat sh; do
  tp=$(command -v "$tool") && ln -s "$tp" "$NOFLOCK/$tool" && ln -s "$tp" "$MVFAIL/$tool"
done
rm -f "$MVFAIL/mv"; printf '#!/bin/sh\nexit 1\n' > "$MVFAIL/mv"; chmod +x "$MVFAIL/mv"
REG="$T/lock/agents.txt"; LOCKD="$REG.d"
reg() {  # reg <path-dir> <op> <label> -> $T/rerr, $lrc, $lsecs (killed after 20 s)
  local pathdir="$1" start pid i=0; shift
  mkdir -p "$T/lock"
  start=$(date +%s)
  env -i PATH="$pathdir" CLAUDE_AGENTS_FILE="$REG" "$TEST_BASH" "$AGENT" "$@" 2> "$T/rerr" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; lrc=hung; wait "$pid" 2>/dev/null
  else wait "$pid"; lrc=$?; fi
  lsecs=$(( $(date +%s) - start ))
}
old_stamp=200001010000

check "lock test PATH has no flock" sh -c "! PATH='$NOFLOCK' command -v flock >/dev/null"
rm -rf "$T/lock"; mkdir -p "$T/lock"
for i in 1 2 3 4 5 6 7 8; do
  env -i PATH="$NOFLOCK" CLAUDE_AGENTS_FILE="$REG" "$TEST_BASH" "$AGENT" add "parallel $i" 2>/dev/null &
done
wait
check "lock: 8 parallel adds all land" [ "$(grep -c 'parallel' "$REG")" = 8 ]
check "lock: released after use" [ ! -e "$LOCKD" ]
# One mechanism for every writer: with flock on PATH the same mkdir lock is
# honoured, so a writer that has flock cannot slip past one that does not.
mkdir "$LOCKD"
reg "$PATH_F" add "flock on path"
check "lock is the same with flock on PATH" grep -q 'registry busy' "$T/rerr"
rmdir "$LOCKD"

# A live lock is waited on, then the write is skipped — never raced, never hung.
mkdir "$LOCKD"; cp "$REG" "$T/reg.before"
reg "$NOFLOCK" add "blocked"
check "lock held: gives up with exit 0 (got $lrc)" [ "$lrc" = 0 ]
check "lock held: within the deadline (${lsecs}s)" [ "$lsecs" -le 8 ]
check "lock held: says skipped" grep -q 'registry busy' "$T/rerr"
check "lock held: file untouched" cmp -s "$REG" "$T/reg.before"
check "lock held: live lock left alone" [ -d "$LOCKD" ]
rmdir "$LOCKD"

# Stale locks that the old `rmdir; continue` could not clear, and spun on
# forever: a regular file in the way, and a non-empty directory.
touch "$LOCKD"; touch -t "$old_stamp" "$LOCKD"
reg "$NOFLOCK" add "after stale file"
check "stale file lock: add succeeds (got $lrc)" [ "$lrc" = 0 ]
check "stale file lock: row written" grep -q 'after stale file' "$REG"
check "stale file lock: cleared" [ ! -e "$LOCKD" ]
mkdir -p "$LOCKD/junk"; touch -t "$old_stamp" "$LOCKD"
reg "$NOFLOCK" add "after stale dir"
check "stale non-empty lock: add succeeds (got $lrc)" [ "$lrc" = 0 ]
check "stale non-empty lock: row written" grep -q 'after stale dir' "$REG"
check "stale non-empty lock: set aside, not deleted" sh -c "ls -d '$LOCKD'.stale.* >/dev/null 2>&1"
rm -rf "$LOCKD" "$LOCKD".stale.*

# A stale lock that cannot be broken (rename refused, as for another user's
# directory in a sticky /tmp) must still give up at the deadline.
mkdir "$LOCKD"; touch -t "$old_stamp" "$LOCKD"
reg "$MVFAIL" add "unbreakable"
check "unbreakable stale lock: exit 0, not hung (got $lrc)" [ "$lrc" = 0 ]
check "unbreakable stale lock: within the deadline (${lsecs}s)" [ "$lsecs" -le 8 ]
check "unbreakable stale lock: says skipped" grep -q 'registry busy' "$T/rerr"
rm -rf "$LOCKD"

# ===========================================================================
# 5. install.sh, end to end against a fixture HOME
# ===========================================================================
# install.sh takes every path from $HOME, so it runs unmodified — exactly the
# script a clone-and-run install executes.
H=""; S=""
inst_home() { H="$T/inst/$1"; rm -rf "$H"; mkdir -p "$H/.claude"; S="$H/.claude/settings.json"; }
INST_ENV=""  # extra VAR=val words for the next install_run (unquoted on purpose)
install_run() {  # install_run [args...] -> $T/iout, $irc
  # shellcheck disable=SC2086
  ( cd "$T" && env -i PATH="$PATH_F" HOME="$H" TZ=UTC LC_ALL=C $INST_ENV "$TEST_BASH" "$ROOT/install.sh" ${1+"$@"} \
      > "$T/iout" 2>&1 )
  irc=$?
}
# jeq <file> <python expr over d> <expected JSON> — compare as JSON values.
# The eval'd expression is always a literal written in this file, never data.
jeq() {
  python3 - "$@" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
try:
    got = eval(sys.argv[2], {'d': d})
except Exception as e:
    got = '<%s>' % type(e).__name__
want = json.loads(sys.argv[3])
if got != want:
    sys.exit('%s: got %r, want %r' % (sys.argv[2], got, want))
PYEOF
}
jcheck() {  # jcheck <name> <file> <expr> <expected>
  local name="$1" msg; shift
  if msg=$(jeq "$@" 2>&1); then pass; else fail "$name: $msg"; fi
}
n_backups() { local f n=0; for f in "$S".agentline-bak-*; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }

# Fresh machine: no settings.json at all.
inst_home fresh
install_run
DEFAULT="$H/.claude/agentline/agentline.sh"
check "fresh: exit 0" [ "$irc" = 0 ]
check "fresh: script installed and executable" [ -x "$DEFAULT" ]
check "fresh: installed copy is agentline.sh" cmp -s "$ROOT/agentline.sh" "$DEFAULT"
jcheck "fresh: statusLine" "$S" "d['statusLine']" "{\"type\":\"command\",\"command\":\"$DEFAULT\",\"refreshInterval\":1}"
check "fresh: services conf seeded" [ -f "$H/.claude/agentline-services.conf" ]
# Idempotent re-run: nothing to change, so nothing is written or backed up.
cp "$S" "$T/before.json"; before=$(n_backups)
install_run
check "re-run: exit 0" [ "$irc" = 0 ]
check "re-run: settings.json byte-identical" cmp -s "$S" "$T/before.json"
check "re-run: no new backup" [ "$(n_backups)" = "$before" ]
check "re-run: says left as-is" grep -q 'left as-is' "$T/iout"

# Unrelated keys survive, and the backup holds the original bytes.
inst_home preserve
cat > "$S" <<'EOF'
{
  "permissions": {"allow": ["Bash(git status)"], "deny": ["Bash(rm -rf *)"]},
  "env": {"AGENTLINE_TZ": "Europe/Istanbul"},
  "hooks": {"Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "/usr/local/bin/my-own-hook.sh"}]}]},
  "model": "opus"
}
EOF
cp "$S" "$T/orig.json"
install_run
DEFAULT="$H/.claude/agentline/agentline.sh"
check "preserve: exit 0" [ "$irc" = 0 ]
jcheck "preserve: permissions kept" "$S" "d['permissions']" '{"allow":["Bash(git status)"],"deny":["Bash(rm -rf *)"]}'
jcheck "preserve: env kept" "$S" "d['env']" '{"AGENTLINE_TZ":"Europe/Istanbul"}'
jcheck "preserve: model kept" "$S" "d['model']" '"opus"'
jcheck "preserve: statusLine added" "$S" "d['statusLine']['command']" "\"$DEFAULT\""
check "preserve: one timestamped backup" [ "$(n_backups)" = 1 ]
for b in "$S".agentline-bak-*; do
  case "${b##*.agentline-bak-}" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) pass ;;
    *) fail "preserve: backup name is not timestamped: $b" ;;
  esac
  check "preserve: backup holds the original" cmp -s "$b" "$T/orig.json"
done
# --with-hooks, twice: the user's hook stays, ours are added exactly once.
install_run --with-hooks
check "hooks: exit 0" [ "$irc" = 0 ]
check "hooks: says wired" grep -q 'Hooks wired' "$T/iout"
for hk in wordcount-hook.sh agent-tracker-hook.sh agentline-agent.sh; do
  check "hooks: $hk installed" [ -x "$H/.claude/agentline/$hk" ]
done
cp "$S" "$T/hooked.json"
install_run --with-hooks
check "hooks twice: exit 0" [ "$irc" = 0 ]
check "hooks twice: says already wired" grep -q 'already wired' "$T/iout"
check "hooks twice: settings.json byte-identical" cmp -s "$S" "$T/hooked.json"
COUNT="lambda ev, name: sum(h.get('command','').endswith('/' + name) for g in d['hooks'].get(ev, []) for h in g.get('hooks', []))"
jcheck "hooks: PostToolUse wordcount x1" "$S" "($COUNT)('PostToolUse', 'wordcount-hook.sh')" 1
jcheck "hooks: Stop wordcount x1" "$S" "($COUNT)('Stop', 'wordcount-hook.sh')" 1
jcheck "hooks: Stop tracker x1" "$S" "($COUNT)('Stop', 'agent-tracker-hook.sh')" 1
jcheck "hooks: PreToolUse tracker x1" "$S" "($COUNT)('PreToolUse', 'agent-tracker-hook.sh')" 1
jcheck "hooks: tracker matcher" "$S" "[g['matcher'] for g in d['hooks']['PreToolUse']]" '["Agent|Task"]'
jcheck "hooks: user's own Stop hook kept" "$S" "($COUNT)('Stop', 'my-own-hook.sh')" 1

# A settings.json that does not parse is refused and left byte for byte.
inst_home malformed
printf '{\n  "permissions": {"allow": ["Bash(ls)"],},\n}\n' > "$S"
cp "$S" "$T/orig.json"
install_run
check "malformed: non-zero exit" [ "$irc" != 0 ]
check "malformed: error names the line" grep -q 'not valid JSON (line' "$T/iout"
check "malformed: file untouched" cmp -s "$S" "$T/orig.json"
check "malformed: no backup written" [ "$(n_backups)" = 0 ]
check "malformed: script not installed" [ ! -e "$H/.claude/agentline/agentline.sh" ]
inst_home not-object
echo '["statusLine"]' > "$S"; cp "$S" "$T/orig.json"
install_run
check "array: refused" [ "$irc" != 0 ]
check "array: file untouched" cmp -s "$S" "$T/orig.json"

# Foreign status lines are matched by file name, never by substring: a
# command merely containing "statusline" is somebody else's.
for cmd in 'npx -y ccstatusline@latest' 'bash ~/bin/my-statusline.sh' '~/bin/custom.sh'; do
  inst_home foreign
  printf '{"statusLine": {"type": "command", "command": "%s"}}\n' "$cmd" > "$S"
  mkdir -p "$H/bin"; echo 'echo mine' > "$H/bin/custom.sh"; cp "$H/bin/custom.sh" "$T/custom.orig"
  cp "$S" "$T/orig.json"
  install_run
  check "foreign '$cmd': exit 3 (installed, not active)" [ "$irc" = 3 ]
  check "foreign '$cmd': settings untouched" cmp -s "$S" "$T/orig.json"
  check "foreign '$cmd': warns" grep -q 'not agentline' "$T/iout"
  check "foreign '$cmd': says NOT active" grep -q 'NOT active' "$T/iout"
  check "foreign '$cmd': no success line" sh -c "! grep -q '^Done' '$T/iout'"
  check "foreign '$cmd': their script not overwritten" cmp -s "$H/bin/custom.sh" "$T/custom.orig"
done
install_run --force
check "foreign --force: exit 0" [ "$irc" = 0 ]
jcheck "foreign --force: repointed" "$S" "d['statusLine']['command']" "\"$H/.claude/agentline/agentline.sh\""
check "foreign --force: backup kept" [ "$(n_backups)" = 1 ]

# --with-hooks on a foreign status line wires nothing: the hooks only feed
# agentline, which Claude Code is not running.
inst_home foreign-hooks
printf '{"statusLine": {"type": "command", "command": "npx -y ccstatusline@latest"}}\n' > "$S"
cp "$S" "$T/orig.json"
install_run --with-hooks
check "foreign --with-hooks: exit 3" [ "$irc" = 3 ]
check "foreign --with-hooks: settings untouched" cmp -s "$S" "$T/orig.json"
check "foreign --with-hooks: says hooks not wired" grep -q 'Hooks not wired' "$T/iout"
check "foreign --with-hooks: no hook scripts copied" [ ! -e "$H/.claude/agentline/wordcount-hook.sh" ]

# The two most common names of somebody else's status line — the docs
# example and what Claude Code's /statusline setup writes — are pre-rename
# names too, but a real foreign script under them is never taken over.
for rel in .claude/statusline.sh .claude/statusline-command.sh; do
  inst_home "foreign-name"
  printf '#!/bin/bash\necho "my own line"\n' > "$H/$rel"; cp "$H/$rel" "$T/theirs.orig"
  printf '{"statusLine": {"type": "command", "command": "~/%s"}}\n' "$rel" > "$S"
  cp "$S" "$T/orig.json"
  install_run
  check "foreign ~/$rel: exit 3" [ "$irc" = 3 ]
  check "foreign ~/$rel: settings untouched" cmp -s "$S" "$T/orig.json"
  check "foreign ~/$rel: script untouched" cmp -s "$H/$rel" "$T/theirs.orig"
done
# The same names are migrated when the script is provably agentline's: it
# carries a marker, or it is missing (nothing to lose).
inst_home marker
printf '#!/bin/bash\n# agentline — old copy\n' > "$H/.claude/statusline-command.sh"
printf '{"statusLine": {"type": "command", "command": "~/.claude/statusline-command.sh"}}\n' > "$S"
install_run
check "marker: exit 0" [ "$irc" = 0 ]
jcheck "marker: migrated" "$S" "d['statusLine']['command']" "\"$H/.claude/agentline/agentline.sh\""
inst_home marker-conf
printf '#!/bin/bash\nconf=~/.claude/statusline-services.conf\n' > "$H/.claude/statusline.sh"
printf '{"statusLine": {"type": "command", "command": "~/.claude/statusline.sh"}}\n' > "$S"
install_run
jcheck "pre-rename conf marker: migrated" "$S" "d['statusLine']['command']" "\"$H/.claude/agentline/agentline.sh\""
inst_home dangling
printf '{"statusLine": {"type": "command", "command": "~/.claude/statusline.sh"}}\n' > "$S"
install_run
check "dangling pre-rename: exit 0" [ "$irc" = 0 ]
jcheck "dangling pre-rename: migrated" "$S" "d['statusLine']['command']" "\"$H/.claude/agentline/agentline.sh\""

# A compound command is not a path: the old resolver took the whole quoted
# string as the install target and mkdir'd it under the cwd.
inst_home compound
printf '%s\n' '{"statusLine": {"type": "command", "command": "bash -c \"AGENTLINE_TZ=UTC exec ~/.claude/agentline/agentline.sh\""}}' > "$S"
cp "$S" "$T/orig.json"
install_run
check "compound: exit 3" [ "$irc" = 3 ]
check "compound: settings untouched" cmp -s "$S" "$T/orig.json"
check "compound: installed to the default location" [ -x "$H/.claude/agentline/agentline.sh" ]
if ls "$T" | grep -q 'AGENTLINE_TZ'; then fail "compound: stray path created under the cwd"; else pass; fi

# Pre-rename names are migrated to the default location.
inst_home legacy
printf '{"statusLine": {"type": "command", "command": "~/.claude/statusline/statusline-command.sh"}}\n' > "$S"
install_run
jcheck "legacy: migrated" "$S" "d['statusLine']['command']" "\"$H/.claude/agentline/agentline.sh\""
check "legacy: prints the old command" grep -q 'was: ~/.claude/statusline/statusline-command.sh' "$T/iout"

# A single-file bind mount refuses os.replace with EBUSY. No mount is possible
# here, so a sitecustomize makes the rename fail the same way; the installer
# must rewrite the file in place, keep the backup, and print no traceback.
inst_home bindmount
echo '{"model": "opus"}' > "$S"
mkdir -p "$T/pyhook"
cat > "$T/pyhook/sitecustomize.py" <<'EOF'
import errno, os
_real = os.replace
def _busy(src, dst, *a, **k):
    if str(dst).endswith('settings.json'):
        raise OSError(errno.EBUSY, 'Device or resource busy', str(dst))
    return _real(src, dst, *a, **k)
os.replace = _busy
EOF
ino_before=$(ls -i "$S" | awk '{print $1}')
INST_ENV="PYTHONPATH=$T/pyhook"
install_run
INST_ENV=""
check "bind mount: exit 0 (got $irc)" [ "$irc" = 0 ]
check "bind mount: no traceback" sh -c "! grep -q Traceback '$T/iout'"
check "bind mount: says rewritten in place" grep -q 'rewritten in place' "$T/iout"
jcheck "bind mount: statusLine written" "$S" "d['statusLine']['refreshInterval']" 1
jcheck "bind mount: other keys kept" "$S" "d['model']" '"opus"'
check "bind mount: same inode (written in place)" [ "$(ls -i "$S" | awk '{print $1}')" = "$ino_before" ]
check "bind mount: backup taken" [ "$(n_backups)" = 1 ]
check "bind mount: no temp file left" sh -c "! ls -a '$H/.claude' | grep -q '^\.settings\.json\.'"

# Backup stamps are UTC, so name order is age order across DST.
inst_home utcstamp
echo '{}' > "$S"
u1=$(date -u +%Y%m%d-%H)
INST_ENV="TZ=Etc/GMT-14"
install_run
INST_ENV=""
u2=$(date -u +%Y%m%d-%H)
stamp=""; for b in "$S".agentline-bak-*; do stamp="${b##*.agentline-bak-}"; done
case "$stamp" in
  "$u1"*|"$u2"*) pass ;;
  *) fail "backup stamp is not UTC: $stamp (UTC hour $u1)" ;;
esac

# A custom agentline path is upgraded in place; a chosen interval is kept.
inst_home custom
mkdir -p "$H/opt"
printf '{"statusLine": {"type": "command", "command": "bash ~/opt/agentline.sh", "refreshInterval": 5}}\n' > "$S"
echo '# old local copy' > "$H/opt/agentline.sh"
install_run
check "custom path: exit 0" [ "$irc" = 0 ]
check "custom path: upgraded in place" cmp -s "$ROOT/agentline.sh" "$H/opt/agentline.sh"
n=0; for f in "$H"/opt/agentline.sh.bak-*; do [ -e "$f" ] && n=$((n + 1)); done
check "custom path: old copy kept as .bak" [ "$n" = 1 ]
check "custom path: default location unused" [ ! -e "$H/.claude/agentline/agentline.sh" ]
jcheck "custom path: statusLine verbatim + interval kept" "$S" "d['statusLine']" '{"type":"command","command":"bash ~/opt/agentline.sh","refreshInterval":5}'

# A symlinked settings.json (dotfile managers) stays a symlink.
inst_home symlink
mkdir -p "$H/dotfiles"
echo '{"model": "opus"}' > "$H/dotfiles/settings.json"
ln -s "$H/dotfiles/settings.json" "$S"
install_run
check "symlink: exit 0" [ "$irc" = 0 ]
check "symlink: still a symlink" [ -L "$S" ]
jcheck "symlink: target updated" "$H/dotfiles/settings.json" "d['statusLine']['refreshInterval']" 1
n=0; for f in "$H"/dotfiles/settings.json.agentline-bak-*; do [ -e "$f" ] && n=$((n + 1)); done
check "symlink: backup beside the target" [ "$n" = 1 ]

inst_home badarg
install_run --bogus
check "unknown option: exit 2" [ "$irc" = 2 ]

# ===========================================================================
echo "agentline tests (bash $TEST_BASH_MAJOR): $n_pass passed, $n_fail failed, $n_skip skipped"
[ "$n_fail" = 0 ]
