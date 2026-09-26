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
# probe cache (render_<sid>.v<N>.probes, AGENTLINE_PROBE_TTL=3600), so none of the
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
# Cache names carry the script's format version (render_<sid>.v<N>.*); read
# it the same way, so a bump needs no edit here.
CACHE_FMT=$(sed -n 's/^CACHE_FORMAT=\([0-9][0-9]*\)$/\1/p' "$ROOT/agentline.sh")
cbase() { printf '%s' "$CACHE_DIR/render_$1.v$CACHE_FMT"; }  # cbase <sid>
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
    printf -v _wq '%q' "$WORK"  # the cwd is stored %q-quoted, like the values
    printf '%s\n%s\n%s' "$(date +%s)" "$_wq" "$body" > "$(cbase "$1").probes"
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

render() {  # render <payload> <width|-> [VAR=val...] -> $T/out $T/err $rc
  local p="$1" w="$2"; shift 2
  # A width of "-" leaves AGENTLINE_WIDTH unset, for the live-COLUMNS tests.
  [ "$w" = - ] || set -- AGENTLINE_WIDTH="$w" ${1+"$@"}
  # ${1+"$@"}: bash 3.2 under `set -u` rejects an empty "$@".
  ( cd "$WORK" && run_env ${1+"$@"} "$TEST_BASH" "$ROOT/agentline.sh" \
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
# bash 3.2 (macOS /bin/bash) parses a heredoc body nested inside `$(...)` as
# shell text: one apostrophe in a python comment there opened a quote and
# broke every full render with a syntax error, while bash 5 and `bash -n`
# under bash 5 were fine. Scripts read such programs into a variable at top
# level instead; this check keeps an odd apostrophe count out of any heredoc
# that still sits inside a command substitution, whichever bash runs it.
if python3 - "$ROOT/agentline.sh" "$ROOT/install.sh" "$ROOT"/hooks/*.sh "$TESTS/run.sh" > "$T/heredocs" 2>&1 <<"PYEOF"
import re, sys
bad = []
for path in sys.argv[1:]:
    lines = open(path, encoding="utf-8").read().split("\n")
    i = 0
    while i < len(lines):
        m = re.search(r"<<-?[\"']?(\w+)[\"']?", lines[i])
        start = lines[i].rfind("$(", 0, m.start()) if m else -1
        if m and start >= 0 and ")" not in lines[i][start:m.start()]:
            tag, body, j = m.group(1), [], i + 1
            while j < len(lines) and lines[j].strip() != tag:
                body.append(lines[j]); j += 1
            if sum(l.count(chr(39)) for l in body) % 2:
                bad.append("%s:%d" % (path.rsplit("/", 1)[-1], i + 1))
            i = j
        i += 1
if bad:
    sys.exit("odd apostrophes in a heredoc inside $(...): " + ", ".join(bad))
PYEOF
then pass; else fail "bash 3.2 heredoc hazard: $(cat "$T/heredocs")"; fi

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
    if grep -qE 'AGENTLINE_(CLOCK|ANIM)' "$T/got" || grep -q "$(printf '\002')" "$T/out"; then
      fail "$label: placeholder leaked"
    else
      pass
    fi
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

# Numbers python accepted but bash cannot use: Unicode digits ("٣٠"), an int
# past a double (OverflowError lost the whole parse), JSON 1e999 (inf) and a
# window size past 64 bits (`[ -gt ]` failed). Bad fields hide their segment;
# the huge window still gets the forced 200k warning, decided in python.
ctx_raw huge-numbers
check "huge numbers: exit 0 (got $rc)" [ "$rc" = 0 ]
check "huge numbers: stderr empty" [ ! -s "$T/err" ]
check "huge numbers: model still parsed" grep -q 'Opus 5' "$T/out"
check "huge numbers: huge window forces the yellow warning" grep -q "${ESC}\[1;33m⚠️  25%" "$T/out"
if grep -qE 'S:|W:|💰|⏱️|📥' "$T/out"; then fail "huge numbers: a bad or absurd field leaked a segment"; else pass; fi
check "huge numbers: a sane field next to them still shows" grep -q '📤 5.0k' "$T/out"

# Terminal-escape injection: the escapes fixture puts literal ESC/BEL/C1 and
# the backslash forms `printf %b` expands (\033, \e, \x1b, \a) into the
# session name, model, version, effort, e-mail, branch, remote, MCP names,
# dev-port process names and an agent label. In the raw render the only
# escapes allowed are the script's own SGR colour codes; nothing else from
# C0/DEL/C1 may survive, and no backslash may be left for %b to act on. The
# tainted segments must still render (cleaned), not vanish.
# Run under C (the harness default, and common on servers, where bash's
# [[:cntrl:]] does not cover C1) and under a UTF-8 locale, when one exists.
# An agent label with UTF-8 encoded C1 is added to the fixture's registry.
UTF8_LOCALE=""
for loc in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
  if [ "$(LC_ALL=$loc "$TEST_BASH" -c 'x=ş; echo ${#x}' 2>/dev/null)" = 1 ]; then UTF8_LOCALE=$loc; break; fi
done
esc_locales="C"
if [ -n "$UTF8_LOCALE" ]; then esc_locales="C $UTF8_LOCALE"; else skip "escapes: no UTF-8 locale installed"; fi
for loc in $esc_locales; do
fill "$FIX/payloads/escapes.json" "$PAY/escapes.json"
prepare escapes "$PAY/escapes.json"
printf '%s agent\302\2332J-\302\235x\n' "$(date +%s)" >> "$SIDE/claude_agents.txt"
render "$PAY/escapes.json" 120 LC_ALL="$loc"
check "escapes [$loc]: exit 0 (got $rc)" [ "$rc" = 0 ]
check "escapes [$loc]: stderr empty" [ ! -s "$T/err" ]
if msg=$(python3 - "$T/out" <<'PYEOF' 2>&1
import re, sys
s = open(sys.argv[1], 'rb').read().decode('utf-8')
rest = re.sub(r'\x1b\[[0-9;]*m', '', s)
bad = sorted({hex(ord(c)) for c in rest if c != '\n' and (ord(c) < 0x20 or 0x7f <= ord(c) <= 0x9f)})
if bad:
    sys.exit('control characters survived: %s' % ', '.join(bad))
if '\\' in rest:
    sys.exit('backslash survived')
for want in ('feat/]0;pwned-title-xe[5m31m-şğÇ🚀©', 'own033[2Jer/reepo@', 'Evil[41m e[7mModel',
             'evil[2J2Jmcp', 'node033[31m(3000)', 'agent2J-x', 'claude --resume esc-0001'):
    if want not in rest:
        sys.exit('segment missing: %r' % want)
PYEOF
); then pass; else fail "escapes [$loc]: $msg"; fi
done

# Lone surrogates in the payload: "\ud800" used to crash the output encode
# and lose every payload field (no model, no context, a traceback), and
# "\udc9b" came out as a raw 0x9B byte, the 8-bit CSI. Now both are dropped
# and the rest of the payload renders; the output is valid UTF-8.
for loc in $esc_locales; do
ctx_raw surrogates
render "$PAY/surrogates.json" 120 LC_ALL="$loc"
check "surrogates [$loc]: stderr empty" [ ! -s "$T/err" ]
if msg=$(python3 - "$T/out" <<'PYEOF' 2>&1
import re, sys
b = open(sys.argv[1], 'rb').read()
try:
    s = b.decode('utf-8')
except UnicodeDecodeError as e:
    sys.exit('output is not valid UTF-8: %s' % e)
rest = re.sub(r'\x1b\[[0-9;]*m', '', s)
if any(0x80 <= ord(c) <= 0x9f for c in rest):
    sys.exit('C1 survived')
for want in ('Opus 5', '30%', 'ab[31mc', 'v2.1'):
    if want not in rest:
        sys.exit('segment missing: %r' % want)
PYEOF
); then pass; else fail "surrogates [$loc]: $msg"; fi
done

# The folder segment is built from a cleaned cwd: a lone surrogate or a raw
# invalid byte in the payload cwd used to come out as a bare 0x9B/0x9D.
printf '{"session_id":"cwd-0001","cwd":"/nonexistent/a\\udc9b[31m\\u009d0;x"}\n' > "$T/cwd1.json"
printf '{"session_id":"cwd-0002","cwd":"/nonexistent/b\233[32m"}\n' > "$T/cwd2.json"
for cj in cwd1 cwd2; do
  prepare minimal "$T/$cj.json"
  render "$T/$cj.json" 120
  if msg=$(python3 -c '
import sys
b = open(sys.argv[1], "rb").read()
try:
    s = b.decode("utf-8")
except UnicodeDecodeError as e:
    sys.exit("not valid UTF-8: %s" % e)
if any(0x80 <= ord(c) <= 0x9f for c in s):
    sys.exit("C1 survived")
if sys.argv[2] not in s:
    sys.exit("folder missing: %r" % sys.argv[2])
' "$T/out" "$([ "$cj" = cwd1 ] && echo '/nonexistent/a[31m0;x' || echo '/nonexistent/b[32m')" 2>&1); then pass; else fail "$cj: $msg"; fi
done

# Placeholder forging: a session name spelling the old placeholders stays
# text — on the full render and on a cached tick — because the real tokens
# carry a C0 byte that no cleaned string can contain.
printf '{"session_id":"forge-0001","cwd":"%s","session_name":"@@AGENTLINE_ANIM_MAX@@","version":"@@AGENTLINE_CLOCK@@"}\n' "$WORK" > "$T/forge.json"
prepare minimal "$T/forge.json"
for pass_no in 1 2; do
  render "$T/forge.json" 120
  check "forging [render $pass_no]: session name kept literally" grep -qF '@@AGENTLINE_ANIM_MAX@@' "$T/out"
  check "forging [render $pass_no]: version kept literally" grep -qF 'v@@AGENTLINE_CLOCK@@' "$T/out"
done

# Probe-cache injection: a payload cwd with a newline used to write an extra
# line into the eval'd cache body, and the next render in the first half of
# that cwd ran it. Both renders share one session (one cache file); the
# first runs the real, harmless host probes because nothing is seeded.
MARK="$T/probe-pwned"
printf '{"session_id":"inject-0001","cwd":"%s\\nactive_mcps=$(touch %s)"}\n' "$WORK" "$MARK" > "$T/inject1.json"
printf '{"session_id":"inject-0001","cwd":"%s","version":"2"}\n' "$WORK" > "$T/inject2.json"
prepare minimal "$T/inject1.json"; rm -f "$CACHE_DIR"/render_inject-0001.*
render "$T/inject1.json" 120
render "$T/inject2.json" 120
check "probe cache: newline in cwd does not inject code" [ ! -e "$MARK" ]
check "probe cache: injected render exit 0 (got $rc)" [ "$rc" = 0 ]
# A body that is not exactly the PROBE_VARS lines is never eval'd.
prepare minimal "$T/inject2.json"
printf '\n%s\n' "active_mcps=\$(touch $MARK)" >> "$(cbase inject-0001).probes"
render "$T/inject2.json" 120
check "probe cache: an extra body line is not eval'd" [ ! -e "$MARK" ]

# ===========================================================================
# 3. Render-cache fast path
# ===========================================================================
p="$PAY/full.json"
sid=$(sid_of "$p")
prepare full "$p"
render "$p" 120
# Prove a tick is served from the cache, not re-rendered: replace the cached
# body with a marker and expect it back with the clock re-stamped.
render_file="$(cbase "$sid").render"
ts=$(head -n 1 "$render_file")
CLOCK_TOK=$(printf '@@\002AGENTLINE_CLOCK@@')  # the script's CLOCK_TOKEN
printf '%s\n%s' "$ts" "CACHED $CLOCK_TOK" > "$render_file"
render "$p" 120
check "tick serves the cached body" grep -Eq '^CACHED [0-9]{2}:[0-9]{2}:[0-9]{2}$' "$T/out"
# Expired (epoch 0) -> full render again.
printf '%s\n%s' 0 "CACHED $CLOCK_TOK" > "$render_file"
render "$p" 120
check "expired cache re-renders" grep -q 'Opus 5' "$T/out"
# A changed payload invalidates on the spot, whatever the cache age.
printf '%s\n%s' "$(date +%s)" "CACHED $CLOCK_TOK" > "$render_file"
sed 's/"used_percentage":42.4/"used_percentage":43/' "$p" > "$T/changed.json"
render "$T/changed.json" 120
check "payload change bypasses the cache" grep -q '43%' "$T/out"
# Caches of an older format (pre-versioned names) are never read: an old body
# holds the old plain placeholder, an old probe cache uncleaned labels.
prepare full "$p"
rm -f "$(cbase "$sid")".*
printf '%s' "$(cat "$p")" > "$CACHE_DIR/render_$sid.payload"
printf '%s\n%s' "$(date +%s)" 'OLD @@AGENTLINE_CLOCK@@' > "$CACHE_DIR/render_$sid.render"
render "$p" 120
check "old-format render cache is ignored" sh -c "! grep -q 'OLD' '$T/out' && grep -q 'Opus 5' '$T/out'"
rm -f "$CACHE_DIR/render_$sid".*

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
# 3a. Layout: AGENTLINE_LAYOUT, AGENTLINE_DROP, live COLUMNS
# ===========================================================================
# Every row fits the width, or is a single segment (a segment is never split).
rows_fit() {  # rows_fit <normalized> <width>
  python3 - "$1" "$2" <<'PYEOF'
import sys, unicodedata
rows = open(sys.argv[1], encoding="utf-8").read().splitlines()
width = int(sys.argv[2])
def vis(s):
    return sum(2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in s)
for r in rows:
    if vis(r) > width and " │ " in r:
        sys.exit("row over %d cells holds more than one segment: %r" % (width, r))
PYEOF
}
vis_line() {  # vis_line <normalized> -> width of its first row
  python3 - "$1" <<'PYEOF'
import sys, unicodedata
r = open(sys.argv[1], encoding="utf-8").read().splitlines()[0]
print(sum(2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in r))
PYEOF
}
has() { grep -qF -- "$2" "$1"; }  # has <file> <text>
n_rows() { wc -l < "$1" | tr -d ' '; }

p="$PAY/full.json"
LAYOUT_DEFAULT=$(sed -n 's/^AGENTLINE_LAYOUT_DEFAULT="\(.*\)"$/\1/p' "$ROOT/agentline.sh")
check "layout: default layout readable from the script" [ -n "$LAYOUT_DEFAULT" ]

# No COLUMNS, no AGENTLINE_WIDTH: the 120 fallback, nothing dropped — the
# golden. The default layout spelled out, and a layout that names nothing
# known (a typo), are the default too.
prepare full "$p"; render "$p" -; normalize "$T/out" "$T/got"
check "layout: no width anywhere = 120 golden" cmp -s "$T/got" "$GOLD/full.w120.txt"
prepare full "$p"; render "$p" 120 AGENTLINE_LAYOUT="$LAYOUT_DEFAULT"; normalize "$T/out" "$T/got"
check "layout: explicit default layout = golden" cmp -s "$T/got" "$GOLD/full.w120.txt"
prepare full "$p"; render "$p" 120 AGENTLINE_LAYOUT="modle, ctxx"; normalize "$T/out" "$T/got"
check "layout: all-unknown layout falls back to the default" cmp -s "$T/got" "$GOLD/full.w120.txt"

# A live width with room for everything renders exactly what the same fixed
# width does: fit mode changes nothing that already fits.
prepare full "$p"; render "$p" 200; normalize "$T/out" "$T/fixed"
prepare full "$p"; render "$p" - COLUMNS=202; normalize "$T/out" "$T/got"
check "layout: COLUMNS=202 (fits) = fixed 200 render" cmp -s "$T/got" "$T/fixed"
check "layout: COLUMNS=202 exit 0 (got $rc)" [ "$rc" = 0 ]
check "layout: COLUMNS=202 stderr empty" [ ! -s "$T/err" ]

# Narrow live width: low-priority segments go first, model/context/limits
# always survive, and every row fits (COLUMNS minus the 2-cell margin).
for cols in 122 62 30; do
  prepare full "$p"; render "$p" - COLUMNS="$cols"; normalize "$T/out" "$T/got"
  check "layout: COLUMNS=$cols exit 0 (got $rc)" [ "$rc" = 0 ]
  check "layout: COLUMNS=$cols stderr empty" [ ! -s "$T/err" ]
  for want in 'Opus 5' '📊 42%' 'S:71%' 'W:58%'; do
    check "layout: COLUMNS=$cols keeps $want" has "$T/got" "$want"
  done
  for gone in '📥' '📤' '⏱️'; do
    if has "$T/got" "$gone"; then fail "layout: COLUMNS=$cols kept low-priority $gone"; else pass; fi
  done
  if msg=$(rows_fit "$T/got" $((cols - 2)) 2>&1); then pass; else fail "layout: COLUMNS=$cols: $msg"; fi
done
# AGENTLINE_WIDTH is an explicit override and wins over COLUMNS.
prepare full "$p"; render "$p" 200 COLUMNS=62; normalize "$T/out" "$T/got"
check "layout: AGENTLINE_WIDTH wins over COLUMNS" has "$T/got" '📥 8.4m'
# The protected four stay even when AGENTLINE_DROP names them.
prepare full "$p"; render "$p" 20 AGENTLINE_DROP="model,ctx,5h,week,cost"; normalize "$T/out" "$T/got"
for want in 'Opus 5' '📊 42%' 'S:71%' 'W:58%'; do
  check "layout: AGENTLINE_DROP cannot drop $want" has "$T/got" "$want"
done
if has "$T/got" '💰'; then fail "layout: AGENTLINE_DROP=cost kept cost"; else pass; fi
# AGENTLINE_DROP="" asks for fit mode without dropping: every segment of the
# unconstrained render is still there, wrapped to fit.
prepare full "$p"; render "$p" 60 AGENTLINE_DROP=; normalize "$T/out" "$T/got"
if msg=$(python3 - "$T/got" "$T/fixed" <<'PYEOF' 2>&1
import sys
a, b = (sorted(s for r in open(f, encoding="utf-8").read().splitlines() for s in r.split(" │ ")) for f in sys.argv[1:3])
if a != b:
    sys.exit("segments differ: %r vs %r" % (a, b))
PYEOF
); then pass; else fail "layout: AGENTLINE_DROP= lost a segment: $msg"; fi
if msg=$(rows_fit "$T/got" 60 2>&1); then pass; else fail "layout: AGENTLINE_DROP=: $msg"; fi

# A custom layout: order and grouping follow the string, anything left out is
# hidden, empty lines collapse.
prepare full "$p"; render "$p" 120 AGENTLINE_LAYOUT="clock,model / / ctx, resume"; normalize "$T/out" "$T/got"
check "layout: custom layout has two rows (got $(n_rows "$T/got"))" [ "$(n_rows "$T/got")" = 2 ]
check "layout: custom order kept" grep -q '^HH:MM:SS │ Opus 5 🧠$' "$T/got"
check "layout: custom second line" grep -q '^📊 42% │ ♻️  claude --resume full-0001$' "$T/got"
if has "$T/got" 'v3.0.24' || has "$T/got" '💰'; then fail "layout: omitted segment still shown"; else pass; fi

# Placeholders are measured at their printed width, not their token length:
# a line exactly as wide as its rendered text stays one row in fit mode.
for spec in "effort-ultracode:model,effort" "full:model,clock"; do
  fx="${spec%%:*}"; lay="${spec#*:}"
  fill "$FIX/payloads/$fx.json" "$PAY/$fx.json"
  prepare "$fx" "$PAY/$fx.json"; render "$PAY/$fx.json" 10000 AGENTLINE_LAYOUT="$lay"; normalize "$T/out" "$T/got"
  lw=$(vis_line "$T/got")
  prepare "$fx" "$PAY/$fx.json"; render "$PAY/$fx.json" "$lw" AGENTLINE_LAYOUT="$lay" AGENTLINE_DROP=; normalize "$T/out" "$T/got"
  check "layout: $fx [$lay] fits in its own width $lw (got $(n_rows "$T/got") rows)" [ "$(n_rows "$T/got")" = 1 ]
done

# The render cache is keyed on the width and layout settings too: a resize or
# a layout change re-renders at once instead of serving the old width for
# the rest of the TTL.
sid=$(sid_of "$p")
prepare full "$p"
render "$p" - COLUMNS=202
printf '%s\n%s' "$(date +%s)" "CACHED" > "$(cbase "$sid").render"
render "$p" - COLUMNS=202
check "layout: same COLUMNS serves the cache" grep -qx 'CACHED' "$T/out"
render "$p" - COLUMNS=62
check "layout: changed COLUMNS bypasses the cache" grep -q 'Opus 5' "$T/out"
printf '%s\n%s' "$(date +%s)" "CACHED" > "$(cbase "$sid").render"
render "$p" - COLUMNS=62 AGENTLINE_LAYOUT="model"
check "layout: changed AGENTLINE_LAYOUT bypasses the cache" grep -q 'Opus 5' "$T/out"
rm -f "$(cbase "$sid")".*

# ===========================================================================
# 3b. Fork budget: python3 boots per render, the bash e-mail mask, gradient
# ===========================================================================
# A python3 start is ~20 ms, the largest fixed cost of a full render. With the
# probe cache fresh, a render boots exactly two: the payload parser and the
# layout pass. The e-mail mask is bash, and the Fable gradient is painted by
# the layout pass. A logging shim ahead of the real python3 counts the boots.
REAL_PY=$(command -v python3)
PYSHIM="$T/pyshim"; mkdir -p "$PYSHIM"
cat > "$PYSHIM/python3" <<EOF
#!/bin/sh
echo x >> "$T/py-boots"
exec "$REAL_PY" "\$@"
EOF
chmod +x "$PYSHIM/python3"
for fx in full fable-max; do
  fill "$FIX/payloads/$fx.json" "$PAY/$fx.json"
  prepare "$fx" "$PAY/$fx.json"; rm -f "$T/py-boots"
  render "$PAY/$fx.json" 120 PATH="$PYSHIM:$PATH_F"
  boots=$(wc -l < "$T/py-boots" 2>/dev/null | tr -d ' ')
  check "fork budget: $fx render boots 2 python3 (got ${boots:-0})" [ "${boots:-0}" = 2 ]
done

# The gradient comes out of the layout pass exactly as the old helper drew it.
grad_want=$(python3 -c '
s = "✦ Fable 5.1"; a, b = (255, 215, 90), (255, 125, 25); n = max(len(s) - 1, 1)
print("".join("\033[1;38;2;%d;%d;%dm%s" % tuple([int(a[k] + (b[k] - a[k]) * i / n) for k in range(3)] + [c]) for i, c in enumerate(s)))')
prepare fable-max "$PAY/fable-max.json"; render "$PAY/fable-max.json" 120
check "fork budget: Fable gradient painted by the layout pass" grep -qF "$grad_want" "$T/out"
if grep -q 'AGENTLINE_GRAD' "$T/out"; then fail "fork budget: gradient marker leaked"; else pass; fi

# The bash mask is the regex it replaced, case for case, including the ones
# that only the regex backtracking decides (several "@", trailing dots) and
# the non-ASCII addresses it hands back to python3.
for addr in octocat@example.com a@b.c ab@cd.e ab@cd.ef x.y@sub.example.co.uk ab@c.d@e ab@@cd.ef \
            ab@cd. @ab.cd ab@.cd ab@cd.ef@gh.ij a-b_c+d@x-y.z9 abc ab@c.d.e. ab@cd.. ab@cd.e.f \
            "o'brien@ex.com" 'şule@örnek.com.tr' 'ab*x@cd.ef'; do
  want=$(python3 -c '
import re, sys
e = sys.argv[1]
m = re.match(r"^(.)(.*)(.)(@)(.)(.*)(.)(\..+)$", e)
print(m and "".join([m[1], "*" * len(m[2]), m[3], m[4], m[5], "*" * len(m[6]), m[7], m[8]]) or e)' "$addr")
  printf '{"session_id":"mask-0001","cwd":"%s","account":{"email":"%s"}}\n' "$WORK" "$addr" > "$T/mask.json"
  prepare minimal "$T/mask.json"
  render "$T/mask.json" 120 AGENTLINE_LAYOUT=email; normalize "$T/out" "$T/got"
  check "e-mail mask: $addr -> $want" grep -qxF "🤖 $want" "$T/got"
done

# ===========================================================================
# 3c. Opt-in /usage fetch: claim file, detached refresh
# ===========================================================================
# No network: fake credentials plus a sitecustomize that replaces urlopen
# with a canned /usage reply after FAKE_USAGE_DELAY seconds. It patches only
# urlopen, so every other python3 the render runs is unaffected.
mkdir -p "$T/usagehook"
cat > "$T/usagehook/sitecustomize.py" <<'EOF'
import errno, io, json, os, time, urllib.request
def _fake(req, timeout=None):
    if os.environ.get('FAKE_USAGE_LOG'):
        with open(os.environ['FAKE_USAGE_LOG'], 'a') as f:
            f.write('fetch\n')
    time.sleep(float(os.environ.get('FAKE_USAGE_DELAY', '0')))
    return io.BytesIO(json.dumps({'limits': [{'kind': 'weekly_scoped',
        'scope': {'model': {'display_name': 'Fable'}}, 'percent': 63}]}).encode())
urllib.request.urlopen = _fake
# FAKE_REPLACE_FAIL=1: the rename of the fetched result fails (a full disk).
if os.environ.get('FAKE_REPLACE_FAIL'):
    _real_replace = os.replace
    def _fail(src, dst, *a, **k):
        if '/usage.' in str(dst):
            raise OSError(errno.ENOSPC, 'No space left on device', str(dst))
        return _real_replace(src, dst, *a, **k)
    os.replace = _fail
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

# A result that cannot be written keeps its claim, so the renders after it
# do not each fetch again (8 fetches in 8 renders before the fix).
prepare minimal "$p"; rm -f "$UCLAIM" "$T/fetches"
printf 37 > "$UCACHE"; age_file "$UCACHE" 310
for i in 1 2 3 4 5; do
  prepare minimal "$p"
  urender FAKE_REPLACE_FAIL=1 FAKE_USAGE_LOG="$T/fetches"
  [ "$i" = 1 ] && wait_for 5 [ -s "$T/fetches" ]
done
sleep 1
check "usage: failed cache write, one fetch not $(wc -l < "$T/fetches" 2>/dev/null | tr -d ' ')" \
  [ "$(wc -l < "$T/fetches" 2>/dev/null | tr -d ' ')" = 1 ]
check "usage: failed cache write keeps the claim" [ -f "$UCLAIM" ]
check "usage: failed cache write leaves no temp file" sh -c "! ls '$UCACHE'.[0-9]* >/dev/null 2>&1"
# A claim that cannot be written starts no fetch at all.
rm -f "$UCLAIM" "$T/fetches"; mkdir "$UCLAIM"
prepare minimal "$p"
urender FAKE_USAGE_LOG="$T/fetches"
sleep 1
check "usage: unwritable claim starts no fetch" [ ! -e "$T/fetches" ]
check "usage: unwritable claim, stderr quiet" [ ! -s "$T/err" ]
rmdir "$UCLAIM"

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
# flock(2) on <file>.lock, taken by python3. The holder below is a separate
# python3 that takes the same lock and sleeps, so a test can hold it, and
# kill -9 it, at will.
REG="$T/lock/agents.txt"; LOCKF="$REG.lock"; LOCKD="$REG.d"
reg() {  # reg <op> <label> [VAR=val...] -> $T/rerr, $lrc, $lsecs (killed after 20 s)
  local op="$1" lab="$2" start pid i=0; shift 2
  mkdir -p "$T/lock"
  start=$(date +%s)
  env -i PATH="$PATH_F" CLAUDE_AGENTS_FILE="$REG" ${1+"$@"} "$TEST_BASH" "$AGENT" "$op" "$lab" 2> "$T/rerr" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; lrc=hung; wait "$pid" 2>/dev/null
  else wait "$pid"; lrc=$?; fi
  lsecs=$(( $(date +%s) - start ))
}
hold_lock() {  # hold_lock <seconds> -> $holder (pid), returns once the lock is held
  rm -f "$T/held"
  python3 - "$LOCKF" "$1" "$T/held" <<'PYEOF' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[3], 'w').close()
time.sleep(float(sys.argv[2]))
PYEOF
  holder=$!
  wait_for 5 [ -e "$T/held" ]
}
old_stamp=200001010000

rm -rf "$T/lock"; mkdir -p "$T/lock"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  env -i PATH="$PATH_F" CLAUDE_AGENTS_FILE="$REG" "$TEST_BASH" "$AGENT" add "parallel $i" 2>/dev/null &
done
wait
check "lock: 12 parallel adds all land" [ "$(grep -c 'parallel' "$REG")" = 12 ]
check "lock: no mkdir-lock artefacts" sh -c "! ls -d '$LOCKD'* >/dev/null 2>&1"

# The reviewer's wedge: an aged leftover mkdir lock plus 12 concurrent adds,
# many rounds. Every round must land every row and leave nothing behind.
bad_rounds=0
for round in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  rm -f "$REG"; mkdir -p "$LOCKD"; touch -t "$old_stamp" "$LOCKD"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    env -i PATH="$PATH_F" CLAUDE_AGENTS_FILE="$REG" "$TEST_BASH" "$AGENT" add "round $i" 2>/dev/null &
  done
  wait
  if [ "$(grep -c 'round' "$REG" 2>/dev/null)" != 12 ] || ls -d "$LOCKD"* >/dev/null 2>&1; then
    bad_rounds=$((bad_rounds + 1))
  fi
done
check "lock stress: 15 rounds x 12 adds, $bad_rounds bad" [ "$bad_rounds" = 0 ]

# A live lock is waited on, then the write is skipped — never raced, never hung.
cp "$REG" "$T/reg.before"
hold_lock 8
reg add "blocked"
check "lock held: gives up with exit 0 (got $lrc)" [ "$lrc" = 0 ]
check "lock held: within the deadline (${lsecs}s)" [ "$lsecs" -le 7 ]
check "lock held: waited for it (${lsecs}s)" [ "$lsecs" -ge 4 ]
check "lock held: says skipped" grep -q 'registry busy' "$T/rerr"
check "lock held: file untouched" cmp -s "$REG" "$T/reg.before"
# A holder that dies (kill -9, no cleanup) releases the lock with it.
kill -9 "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
reg add "after a dead holder"
check "dead holder: add succeeds at once (rc $lrc, ${lsecs}s)" [ "$lrc" = 0 -a "$lsecs" -le 2 ]
check "dead holder: row written" grep -q 'after a dead holder' "$REG"

# flock(1) — what earlier releases locked this same file with — is excluded
# by, and excludes, the python lock: one mechanism for every writer.
if command -v flock >/dev/null 2>&1; then
  flock "$LOCKF" sleep 8 & fpid=$!
  sleep 0.5
  reg add "vs flock(1)"
  check "flock(1) holder: python writer waits it out" grep -q 'registry busy' "$T/rerr"
  kill "$fpid" 2>/dev/null; wait "$fpid" 2>/dev/null
else
  skip "flock(1) interop: flock not installed"
fi

# Errors that waiting cannot cure fail fast instead of costing the deadline:
# a lock name that cannot be opened (a directory in the way stands in for
# another user's lock file), an unwritable directory.
rm -f "$LOCKF"; mkdir "$LOCKF"
reg add "lock unopenable"
check "unopenable lock: exit 0 at once (rc $lrc, ${lsecs}s)" [ "$lrc" = 0 -a "$lsecs" -le 2 ]
check "unopenable lock: says why" grep -q 'cannot open the lock' "$T/rerr"
rmdir "$LOCKF"
mkdir -p "$T/ro"; chmod 555 "$T/ro"
if [ -w "$T/ro" ]; then
  skip "unwritable registry dir: running as root"
else
  reg add "read-only dir" CLAUDE_AGENTS_FILE="$T/ro/agents.txt"
  check "unwritable dir: exit 0 at once (rc $lrc, ${lsecs}s)" [ "$lrc" = 0 -a "$lsecs" -le 2 ]
  check "unwritable dir: says skipped" grep -q 'skipped add' "$T/rerr"
fi
chmod 755 "$T/ro"

# Leftovers of the old mkdir lock are swept on the next write — aged ones
# only; a fresh one may belong to an older helper still running.
mkdir -p "$LOCKD/junk" "$LOCKD.stale.1.2/junk" "$LOCKD.stale.3.4"
touch -t "$old_stamp" "$LOCKD" "$LOCKD.stale.1.2"
reg add "sweeper"
check "sweep: aged lock dir removed" [ ! -e "$LOCKD" ]
check "sweep: aged stale dir removed" [ ! -e "$LOCKD.stale.1.2" ]
check "sweep: fresh stale dir kept" [ -d "$LOCKD.stale.3.4" ]
check "sweep: flock file kept" [ -f "$LOCKF" ]
rm -rf "$LOCKD.stale.3.4"
# Once a sweep finds nothing to wait for, it marks the lock file, and later
# writes skip the directory listing (and the glob/shutil imports) entirely.
: > "$LOCKF"
reg add "sweep marker"
check "sweep: clean pass marks the lock file" [ "$(cat "$LOCKF")" = 2 ]
check "sweep marker: write still lands" grep -q 'sweep marker' "$REG"
check "sweep marker: no temp file left" sh -c "! ls '$REG'.[0-9]* >/dev/null 2>&1"

# A label cannot inject a second row.
reg add "$(printf 'two\nlines')"
check "label newline: one row" grep -qx '[0-9]* two lines' "$REG"

# No python3: the write is skipped with a note, never half-done.
NOPY="$T/nopy"; mkdir -p "$NOPY"
for tool in dirname mkdir; do ln -sf "$(command -v "$tool")" "$NOPY/$tool"; done
cp "$REG" "$T/reg.before"
env -i PATH="$NOPY" CLAUDE_AGENTS_FILE="$REG" "$TEST_BASH" "$AGENT" add "no python" 2> "$T/rerr"; lrc=$?
check "no python3: exit 0 (got $lrc)" [ "$lrc" = 0 ]
check "no python3: says skipped" grep -q 'python3 not found' "$T/rerr"
check "no python3: file untouched" cmp -s "$REG" "$T/reg.before"

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
# Neither the directory nor a missing-looking compound command proves a
# pre-rename script is ours. rz1989s/claude-code-statusline documents
# ~/.claude/statusline/statusline.sh; a `statusline/` project dir is common;
# a compound command or an unexpanded variable is not a path that can be
# judged missing; a wrapper that runs agentline mentions it by name.
foreign_kept() {  # foreign_kept <label> <command-json-string>
  printf '{"statusLine": {"type": "command", "command": "%s"}}\n' "$2" > "$S"
  cp "$S" "$T/orig.json"
  install_run
  check "$1: exit 3 (got $irc)" [ "$irc" = 3 ]
  check "$1: settings untouched" cmp -s "$S" "$T/orig.json"
}
for rel in .claude/statusline/statusline.sh code/statusline/statusline.sh; do
  inst_home foreign-dir
  mkdir -p "$(dirname "$H/$rel")"
  printf '#!/bin/bash\necho "third-party line"\n' > "$H/$rel"; cp "$H/$rel" "$T/theirs.orig"
  foreign_kept "foreign ~/$rel" "~/$rel"
  check "foreign ~/$rel: script untouched" cmp -s "$H/$rel" "$T/theirs.orig"
done
inst_home compound-missing
foreign_kept "compound missing pre-rename" 'bash -c \"source ~/.profile; ~/.claude/statusline.sh\"'
inst_home unexpanded
foreign_kept "unexpanded \$XDG pre-rename" '$XDG_CONFIG_HOME/claude/statusline.sh'
inst_home wrapper-file
printf '#!/bin/bash\n~/.claude/agentline/agentline.sh | sed "s/x/y/"\n' > "$H/.claude/statusline.sh"
cp "$H/.claude/statusline.sh" "$T/theirs.orig"
foreign_kept "wrapper naming agentline" '~/.claude/statusline.sh'
check "wrapper naming agentline: wrapper untouched" cmp -s "$H/.claude/statusline.sh" "$T/theirs.orig"
inst_home old-marker-word
printf '#!/bin/bash\n# agentline — old copy\n' > "$H/.claude/statusline-command.sh"
foreign_kept "bare word 'agentline' is no marker" '~/.claude/statusline-command.sh'
# A FIFO at the name is never opened for reading: the old open() blocked
# forever on one with no writer. Killed after 20 s so a regression fails
# instead of hanging the suite.
if command -v mkfifo >/dev/null 2>&1; then
  inst_home fifo
  mkfifo "$H/.claude/statusline.sh"
  printf '{"statusLine": {"type": "command", "command": "~/.claude/statusline.sh"}}\n' > "$S"
  install_run & ipid=$!
  i=0; while kill -0 "$ipid" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$ipid" 2>/dev/null; then
    kill -9 "$ipid" 2>/dev/null; wait "$ipid" 2>/dev/null; fail "fifo pre-rename: installer hung"
  else
    wait "$ipid"; pass
  fi
else
  skip "fifo pre-rename: mkfifo not installed"
fi

# The same names are migrated when the script is provably agentline's: it
# carries agentline's header or the pre-rename conf name, or the command is
# one absolute path that is missing (nothing to lose).
inst_home marker
head -n 3 "$ROOT/agentline.sh" > "$H/.claude/statusline-command.sh"
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
# string as the install target and mkdir'd it under the cwd. agentline run
# from inside a wrapper is still agentline: the copy it runs is upgraded in
# place and the wrapper (and the env it sets) is left alone — no "NOT
# active", and no --force suggestion that would drop the wrapper.
inst_home compound
printf '%s\n' '{"statusLine": {"type": "command", "command": "bash -c \"AGENTLINE_TZ=UTC exec ~/.claude/agentline/agentline.sh\"", "refreshInterval": 1}}' > "$S"
cp "$S" "$T/orig.json"
install_run
check "wrapped default: exit 0 (got $irc)" [ "$irc" = 0 ]
check "wrapped default: says behind a wrapper" grep -q 'behind a wrapper' "$T/iout"
check "wrapped default: no NOT active, no --force" sh -c "! grep -qE 'NOT active|--force' '$T/iout'"
check "wrapped default: settings untouched" cmp -s "$S" "$T/orig.json"
check "wrapped default: installed to the default location" cmp -s "$ROOT/agentline.sh" "$H/.claude/agentline/agentline.sh"
if ls "$T" | grep -q 'AGENTLINE_TZ'; then fail "compound: stray path created under the cwd"; else pass; fi
# A wrapped custom copy is the one upgraded, piped or not.
inst_home wrapped-custom
mkdir -p "$H/opt"; echo '# old local copy' > "$H/opt/agentline.sh"
printf '%s\n' '{"statusLine": {"type": "command", "command": "bash -c \"~/opt/agentline.sh | sed s/x/y/\"", "refreshInterval": 1}}' > "$S"
cp "$S" "$T/orig.json"
install_run
check "wrapped custom: exit 0 (got $irc)" [ "$irc" = 0 ]
check "wrapped custom: upgraded in place" cmp -s "$ROOT/agentline.sh" "$H/opt/agentline.sh"
check "wrapped custom: default location unused" [ ! -e "$H/.claude/agentline/agentline.sh" ]
check "wrapped custom: settings untouched" cmp -s "$S" "$T/orig.json"

# A command that runs this very checkout (wrapped or not) makes the install
# target the installer's own source: `cp` onto itself used to fail and abort
# the install with status 1. The copy is skipped and the checkout untouched.
for cmdjson in "bash -c \\\"exec $ROOT/agentline.sh | cat\\\"" "bash $ROOT/agentline.sh"; do
  inst_home self-copy
  printf '{"statusLine": {"type": "command", "command": "%s", "refreshInterval": 1}}\n' "$cmdjson" > "$S"
  install_run
  check "self copy [$cmdjson]: exit 0 (got $irc)" [ "$irc" = 0 ]
  check "self copy [$cmdjson]: says already current" grep -q 'already current' "$T/iout"
  check "self copy [$cmdjson]: no backup of the checkout" sh -c "! ls '$ROOT'/agentline.sh.bak-* >/dev/null 2>&1"
done

# --with-hooks on a settings.json whose "hooks" is not an object is refused
# up front — before the old code had already copied the script and saved
# statusLine, then failed with "Nothing was changed".
inst_home bad-hooks
printf '{"hooks": []}\n' > "$S"; cp "$S" "$T/orig.json"
install_run --with-hooks
check "bad hooks: exit 1 (got $irc)" [ "$irc" = 1 ]
check "bad hooks: settings untouched" cmp -s "$S" "$T/orig.json"
check "bad hooks: script not installed" [ ! -e "$H/.claude/agentline/agentline.sh" ]

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
