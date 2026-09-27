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

# One pinned clock for the whole run. Fixtures are stamped relative to TNOW
# (@@NOW+<s>@@, the pace and prompt-cache payloads), and every render gets
# AGENTLINE_NOW=$TNOW, so a countdown or a pace arrow is the same number
# however long the suite takes to reach it: renders a minute after the
# fixture was filled used to floor ↻2h0m to ↻1h59m and ⇡12% to ⇡11% on a
# slow host. The probe cache and agent rows the harness writes carry TNOW
# too (an agent row newer than "now" is not shown). The tests that need
# time to pass for real — cache ages, the /usage TTL and claim — render with
# AGENTLINE_NOW= (empty, ignored by the script).
TNOW=$(date +%s)

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
# The script renders under LC_ALL=C unless AGENTLINE_TEST_LC names another
# locale (e.g. C.UTF-8): the suite also passes with the script in a UTF-8
# locale, which is where most users run it.
run_env() {  # run a command in the hermetic environment; extra VAR=val first
  env -i PATH="$PATH_F" HOME="$HOME_F" TMPDIR="$TMP_F" AGENTLINE_TMP="$SIDE" \
    TZ=UTC LC_ALL="${AGENTLINE_TEST_LC:-C}" AGENTLINE_PROBE_TTL=3600 AGENTLINE_NOW="$TNOW" "$@"
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
# (the epoch <s> seconds after TNOW, the pinned clock every render reads:
# +7230 s renders as 2h0m however long the suite takes to get there). The
# file is copied byte for byte otherwise — the malformed and empty fixtures
# must reach the script exactly as written.
fill() {  # fill <template> <out>
  python3 - "$1" "$2" "$HOME_F" "$WORK" "$FIX" "$TNOW" <<'PYEOF'
import re, sys
src, dst, home, cwd, fix = sys.argv[1:6]
data = open(src, 'rb').read().decode('utf-8')
data = data.replace('@@HOME@@', home).replace('@@CWD@@', cwd).replace('@@FIXTURES@@', fix)
now = int(sys.argv[6])
data = re.sub(r'@@NOW\+(\d+)@@', lambda m: str(now + int(m.group(1))), data)
open(dst, 'wb').write(data.encode('utf-8'))
PYEOF
}

# Seed the probe cache for <sid> from a probe set, in the format agentline.sh
# writes: epoch, cwd, then one `var=<printf %q>` line per PROBE_VARS entry.
seed_probes() {  # seed_probes <sid> <set-name>
  (
    # %q under the C locale, as the script itself writes it in the suite. The
    # harness runs in the CI runner's locale, and bash 3.2's %q decides
    # byte by byte with isprint(3) whether to spell a byte as \ooo: macOS
    # counts 0xE2 as printable (â) in a UTF-8 locale but not the C1-range
    # continuation bytes, so "│" came out as a raw E2 followed by \224\202.
    # eval turns that back into the right bytes, but the file is no longer
    # UTF-8, and the tests that patch it with sed ("illegal byte sequence")
    # or python (UnicodeDecodeError) failed on macOS only.
    LC_ALL=C
    for _v in $PROBE_VARS; do eval "$_v="; done
    # shellcheck source=/dev/null
    . "$FIX/probes/$2.sh"
    body=""
    for _v in $PROBE_VARS; do
      printf -v _q '%q' "${!_v}"
      body="${body}${_v}=${_q}"$'\n'
    done
    printf -v _wq '%q' "$WORK"  # the cwd is stored %q-quoted, like the values
    printf '%s\n%s\n%s' "$TNOW" "$_wq" "$body" > "$(cbase "$1").probes"
  )
}

# Reset per-render state: no render cache (so every width is a full render),
# fresh probes, the fixture's side files and a fresh empty e-mail cache.
prepare() {  # prepare <fixture-name> <filled-payload>
  local name="$1" sid pset now label key
  sid=$(sid_of "$2")
  rm -f "$CACHE_DIR"/render_* "$CACHE_DIR"/compact.* "$SIDE"/claude_*
  pset=busy
  [ -f "$FIX/payloads/$name.probes" ] && pset=$(cat "$FIX/payloads/$name.probes")
  seed_probes "$sid" "$pset"
  [ -f "$FIX/payloads/$name.wordcount" ] && cp "$FIX/payloads/$name.wordcount" "$SIDE/claude_wordcount.txt"
  if [ -f "$FIX/payloads/$name.agents" ]; then
    now=$TNOW
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
# LC_ALL=C: some renders carry deliberately invalid bytes, which BSD sed
# refuses under a UTF-8 locale; the patterns are all ASCII. OSC-8 hyperlink
# openers and closers go too (the link text stays), so the goldens hold
# what is drawn; the links themselves are asserted on the raw render.
BEL=$(printf '\007')
normalize() {  # normalize <in> <out>
  LC_ALL=C sed -e "s/${ESC}\[[0-9;]*m//g" -e "s/${ESC}]8;;[^${BEL}]*${BEL}//g" "$1" \
    | LC_ALL=C sed -E -e 's/[0-9]{2}:[0-9]{2}:[0-9]{2}/HH:MM:SS/g' \
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
    # As agentline.sh measures: VS16 makes the character before it two
    # cells, other combining marks and format characters take none.
    n = prev = 0
    for c in s:
        if c == '\N{VARIATION SELECTOR-16}':
            n, prev = n + 2 - prev, 2
        elif unicodedata.category(c) in ('Mn', 'Me', 'Cf'):
            continue
        else:
            prev = 2 if unicodedata.east_asian_width(c) in ('W', 'F') else 1
            n += prev
    return n
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
for f in "$ROOT/agentline.sh" "$ROOT/install.sh" "$ROOT"/hooks/*.sh "$TESTS/run.sh" "$ROOT"/bench/*.sh; do
  check "bash -n ${f#"$ROOT"/}" "$TEST_BASH" -n "$f"
done
# bash 3.2 (macOS /bin/bash) parses a heredoc body nested inside `$(...)` as
# shell text: one apostrophe in a python comment there opened a quote and
# broke every full render with a syntax error, while bash 5 and `bash -n`
# under bash 5 were fine. Scripts read such programs into a variable at top
# level instead; this check keeps such hazards out of any heredoc that still
# sits inside a command substitution, whichever bash runs it.
#
# A small tokenizer follows quotes, comments and ( / $( nesting across lines,
# so a heredoc counts as inside $(...) wherever the opener is — also on an
# earlier line. Its body must not hold an odd number of apostrophes, double
# quotes or backticks, nor unbalanced parentheses: bash 3.2 reads all four
# while it looks for the closing `)`. It also flags a `case ... in pat)`
# inside $(...) on one line, whose `)` bash 3.2 takes for the end of the
# substitution (write the pattern as `(pat)`). The checker is self-tested on
# one sample per hazard, so a guard that stops seeing one fails too.
cat > "$T/heredoc_guard.py" <<"PYEOF"
import re, sys
HEREDOC = re.compile(r"<<-?\s*([\"']?)(\w+)\1")
CASE_IN_SUBST = re.compile(r"\$\((?:(?!\)).)*?\bcase\b.*?\bin\s+(\S)")

def scan(path):
    bad, name = [], path.rsplit("/", 1)[-1]
    lines = open(path, encoding="utf-8").read().split("\n")
    stack, quote, i = [], None, 0  # stack: (kind, quote to restore on `)`)
    while i < len(lines):
        line, pending = lines[i], []
        j = 0
        while j < len(line):
            c = line[j]
            if quote == "'":
                if c == "'":
                    quote = None
            elif c == "\\":
                j += 1
            elif quote == '"' and c == '"':
                quote = None
            elif line.startswith("$(", j):
                m = CASE_IN_SUBST.match(line, j)
                if m and m.group(1) != "(":
                    bad.append("%s:%d: case pattern inside $(...), write it (pat)" % (name, i + 1))
                stack.append(("$(", quote))
                quote = None
                j += 1
            elif quote is None:
                if c in "'\"":
                    quote = c
                elif c == "#" and (j == 0 or line[j - 1] in " \t;"):
                    break
                elif c == "(":
                    stack.append(("(", None))
                elif c == ")":
                    if stack:
                        quote = stack.pop()[1]
                elif line.startswith("<<", j) and not line.startswith("<<<", j):
                    h = HEREDOC.match(line, j)
                    if h:
                        pending.append((h.group(2), sum(k == "$(" for k, _ in stack), i + 1))
                        j = h.end() - 1
            j += 1
        i += 1
        for tag, depth, at in pending:
            body = []
            while i < len(lines) and lines[i].strip() != tag:
                body.append(lines[i])
                i += 1
            i += 1
            text, probs = "\n".join(body), []
            if depth:
                for ch, what in (("'", "apostrophes"), ('"', "double quotes"), ("`", "backticks")):
                    if text.count(ch) % 2:
                        probs.append("odd " + what)
                if text.count("(") != text.count(")"):
                    probs.append("unbalanced parentheses")
            if probs:
                bad.append("%s:%d: heredoc inside $(...): %s" % (name, at, ", ".join(probs)))
    return bad

bad = [b for p in sys.argv[1:] for b in scan(p)]
print("\n".join(bad))
sys.exit(1 if bad else 0)
PYEOF
if python3 "$T/heredoc_guard.py" "$ROOT/agentline.sh" "$ROOT/install.sh" "$ROOT"/hooks/*.sh \
     "$TESTS/run.sh" "$ROOT"/bench/*.sh > "$T/heredocs" 2>&1; then
  pass
else
  fail "bash 3.2 heredoc hazard: $(tr '\n' ' ' < "$T/heredocs")"
fi
# Self-test: each sample holds one hazard and must be flagged; the clean one
# (a top-level heredoc with anything in it, a balanced one inside $(...))
# must not.
G="$T/guard"; mkdir -p "$G"
q="'"; bq='`'
printf 'x=$(python3 - <<%sEOF%s\n# it%ss\nEOF\n)\n' "$q" "$q" "$q" > "$G/apostrophe.sh"
printf 'x=$(python3 - <<%sEOF%s\nprint("a)\nEOF\n)\n' "$q" "$q" > "$G/dquote.sh"
printf 'x=$(cat <<%sEOF%s\n%s\nEOF\n)\n' "$q" "$q" "$bq" > "$G/backtick.sh"
printf 'x=$(cat <<%sEOF%s\nf(\nEOF\n)\n' "$q" "$q" > "$G/paren.sh"
printf 'x=$(\n  python3 - <<%sEOF%s\n# it%ss\nEOF\n)\n' "$q" "$q" "$q" > "$G/earlier.sh"
printf 'y=$(case "$a" in b) echo 1 ;; esac)\n' > "$G/case.sh"
printf 'cat <<%sEOF%s\nit%ss "( `\nEOF\nx=$(cat <<%sEOF%s\nf("a", %sb%s)\nEOF\n)\ny=$(case "$a" in (b) echo 1 ;; esac)\n' \
  "$q" "$q" "$q" "$q" "$q" "$q" "$q" > "$G/clean.sh"
for s in apostrophe dquote backtick paren earlier case; do
  if python3 "$T/heredoc_guard.py" "$G/$s.sh" > /dev/null 2>&1; then fail "heredoc guard misses: $s"; else pass; fi
done
if msg=$(python3 "$T/heredoc_guard.py" "$G/clean.sh" 2>&1); then pass; else fail "heredoc guard false alarm: $msg"; fi

# Portability lint: every sed, grep and tr the runtime runs must carry an
# LC_ALL=C prefix. Under a UTF-8 locale BSD sed and tr abort at the first
# invalid byte ("illegal byte sequence") and GNU grep treats such input as
# binary, and their input is often someone else's bytes (a remote URL, a
# transcript, a label). macOS CI only sees the bytes its fixtures happen to
# carry, so the rule is enforced by spelling rather than by running.
#
# Its limits, deliberately: it reads spelling, not data flow, so it cannot
# tell trusted ASCII input from untrusted input and asks for the prefix on
# all of them (it costs nothing). A call written as `LC_ALL=C; sed`, an
# exported locale, a command run through a variable or `env` goes unseen,
# as does anything in a heredoc body (the python programs). awk is out of
# scope: no awk aborts on invalid bytes, and pinning it would make
# length()/substr() count bytes. A line that must keep the user's locale says
# so with a `# locale-ok` comment and its reason above it.
cat > "$T/locale_lint.py" <<"PYEOF"
import re, sys
HEREDOC = re.compile(r"<<-?\s*([\"']?)(\w+)\1")
CMD = re.compile(r"(?:^|[|;&(`]|\$\(|\b(?:if|elif|while|until|then|do|else)\s|!\s)\s*"
                 r"((?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*)(sed|grep|tr)(?=\s|$)")
bad = []
for path in sys.argv[1:]:
    tag = None
    for n, line in enumerate(open(path, encoding="utf-8").read().split("\n"), 1):
        if tag:
            if line.strip() == tag:
                tag = None
            continue
        h = HEREDOC.search(line)
        if h and "<<<" not in line:
            tag = h.group(2)
        if line.lstrip().startswith("#") or "# locale-ok" in line:
            continue
        code = re.sub(r"\s#\s.*$", "", line)
        for m in CMD.finditer(code):
            if "LC_ALL=C" not in m.group(1).split():
                bad.append("%s:%d: %s without LC_ALL=C" % (path.rsplit("/", 1)[-1], n, m.group(2)))
print("\n".join(bad))
sys.exit(1 if bad else 0)
PYEOF
if python3 "$T/locale_lint.py" "$ROOT/agentline.sh" "$ROOT/install.sh" "$ROOT"/hooks/*.sh > "$T/lint" 2>&1; then
  pass
else
  fail "locale lint: $(tr '\n' ' ' < "$T/lint")"
fi
# Self-test: each unpinned spelling is flagged; pinned calls, comments, a
# locale-ok line and a heredoc body are not.
printf 'x=$(echo a | sed s/a/b/)\n' > "$G/l-pipe.sh"
printf 'if grep -q a f; then :; fi\n' > "$G/l-if.sh"
printf 'y=$(tr -d x < f)\n' > "$G/l-subst.sh"
printf 'a=1; ! grep -q a f\n' > "$G/l-bang.sh"
printf 'LANG=C sed -n p f\n' > "$G/l-wrongvar.sh"
printf '%s\n' 'x=$(echo a | LC_ALL=C sed s/a/b/)' 'LC_ALL=C grep -q a f || LC_ALL=C tr -d x < f' \
  '# | sed s/x/y/ in a comment' 'z=$(sed s/a/b/ f)  # locale-ok' "cat <<'EOF'" 'echo | sed x' 'EOF' \
  'untr=1; grep_x=2; sed_y=3' > "$G/l-clean.sh"
for s in pipe if subst bang wrongvar; do
  if python3 "$T/locale_lint.py" "$G/l-$s.sh" > /dev/null 2>&1; then fail "locale lint misses: $s"; else pass; fi
done
if msg=$(python3 "$T/locale_lint.py" "$G/l-clean.sh" 2>&1); then pass; else fail "locale lint false alarm: $msg"; fi

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
    if grep -qE 'AGENTLINE_(CLOCK|ANIM|PCEXP)' "$T/got" || grep -q "$(printf '\002')" "$T/out"; then
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

# --- Themes and glyph sets ----------------------------------------------------
# ascii prints nothing above U+007F, mono no SGR sequence at all, in every
# fixture. A fixture whose own data (payload, agent labels, probe set) is not
# ASCII is skipped for ascii: those bytes are the user's, not agentline's.
all_ascii() { python3 -c 'import sys; sys.exit(any(b > 127 for b in open(sys.argv[1], "rb").read()))' "$1"; }
n_ascii=0
for tpl in "$FIX"/payloads/*.json; do
  name=$(basename "$tpl" .json)
  p="$PAY/$name.json"; fill "$tpl" "$p"
  pset=busy; [ -f "$FIX/payloads/$name.probes" ] && pset=$(cat "$FIX/payloads/$name.probes")
  prepare "$name" "$p"
  render "$p" 120 AGENTLINE_THEME=mono
  check "$name mono: exit 0 (got $rc)" [ "$rc" = 0 ]
  if grep -q "${ESC}\[" "$T/out" || grep -qF '\033[' "$T/out"; then fail "$name mono: an SGR sequence is left"; else pass; fi
  render "$p" 120 AGENTLINE_THEME=mono  # a cached tick, animation tokens included
  if grep -q "${ESC}\[" "$T/out"; then fail "$name mono tick: an SGR sequence is left"; else pass; fi
  if all_ascii "$tpl" && { [ ! -f "$FIX/payloads/$name.agents" ] || LC_ALL=C sed 's/^✓//' "$FIX/payloads/$name.agents" > "$T/lab" && all_ascii "$T/lab"; } \
     && { [ "$pset" != escapes ]; }; then
    prepare "$name" "$p"
    render "$p" 120 AGENTLINE_GLYPHS=ascii
    check "$name ascii: exit 0 (got $rc)" [ "$rc" = 0 ]
    check "$name ascii: stderr empty" [ ! -s "$T/err" ]
    normalize "$T/out" "$T/got"
    if all_ascii "$T/got"; then pass; else fail "$name ascii: non-ASCII left: $(LC_ALL=C grep -n "$(printf '[\200-\377]')" "$T/got" | head -2)"; fi
    n_ascii=$((n_ascii + 1))
  fi
done
check "ascii: most fixtures checked ($n_ascii)" [ "$n_ascii" -ge 15 ]
prepare full "$PAY/full.json"
render "$PAY/full.json" 120 NO_COLOR=1
check "NO_COLOR selects mono" sh -c "! grep -q '${ESC}\[' '$T/out'"
prepare full "$PAY/full.json"
render "$PAY/full.json" 120 NO_COLOR=
check "an empty NO_COLOR is no request" grep -q "${ESC}\[" "$T/out"
prepare agents-overflow "$PAY/agents-overflow.json"
render "$PAY/agents-overflow.json" 200 AGENTLINE_GLYPHS=ascii
normalize "$T/out" "$T/got"
check "ascii: agents joined with /, done as ok:" grep -qF 'agents:explore the repo / review #a1b2c3 / fork / codex round 1 / +2 / ok:code review | claude --resume agents-0001' "$T/got"
prepare full "$PAY/full.json"
render "$PAY/full.json" 200 AGENTLINE_GLYPHS=ascii
normalize "$T/out" "$T/got"
check "ascii: services, git counts" grep -qE 'svc:Web ok / DB FAIL / Cache ok' "$T/got"
check "ascii: a failed service still warns (never dropped)" sh -c "grep -q 'DB FAIL' '$T/got'"
# light swaps only the fixed colours: the Fable gradient, GOLD/ORANGE and
# the max rainbow; the ANSI-16 roles stay the terminal's.
fill "$FIX/payloads/fable-max.json" "$PAY/fable-max.json"
prepare fable-max "$PAY/fable-max.json"
render "$PAY/fable-max.json" 120
check "dark: Fable gradient starts amber" grep -q "38;2;255;215;90m" "$T/out"
prepare fable-max "$PAY/fable-max.json"
render "$PAY/fable-max.json" 120 AGENTLINE_THEME=light
check "light: Fable gradient starts dark amber" grep -q "38;2;180;110;0m" "$T/out"
check "light: no dark-wheel or dark-gradient colour" sh -c "! grep -q '38;2;255;' '$T/out'"
check "light: ANSI-16 roles untouched" grep -qE "${ESC}\[(1;36|2)m" "$T/out"
prepare fable-max "$PAY/fable-max.json"
render "$PAY/fable-max.json" 120 AGENTLINE_THEME=light
check "light: cached tick keeps the light wheel" sh -c "! grep -q '38;2;255;' '$T/out'"
prepare full "$PAY/full.json"
render "$PAY/full.json" 120 AGENTLINE_THEME=light
check "light: ORANGE is 166" grep -q "38;5;166m" "$T/out"
prepare fable-max "$PAY/fable-max.json"
render "$PAY/fable-max.json" 120 AGENTLINE_THEME=bogus
check "unknown theme is dark" grep -q "38;2;255;215;90m" "$T/out"
# Overrides: "r,g,b" each 0-255, or ignored whole.
prepare full "$PAY/full.json"
render "$PAY/full.json" 120 AGENTLINE_COLOR_ORANGE=1,2,3
check "override: ORANGE" grep -q "38;2;1;2;3m" "$T/out"
for bad in 300,0,0 1,2 1,2,3,4 a,b,c ,1,2 1,,2; do
  prepare full "$PAY/full.json"
  render "$PAY/full.json" 120 AGENTLINE_COLOR_ORANGE="$bad"
  check "override: bad ORANGE '$bad' ignored" grep -q "38;5;208m" "$T/out"
done
prepare fable-max "$PAY/fable-max.json"
render "$PAY/fable-max.json" 120 AGENTLINE_COLOR_FABLE_FROM=10,20,30 AGENTLINE_COLOR_FABLE_TO=40,50,60
check "override: Fable gradient from" grep -q "38;2;10;20;30m" "$T/out"
check "override: Fable gradient to" grep -q "38;2;40;50;60m" "$T/out"
# Several emoji with a variation selector on one line are measured at the
# cells they take: base + U+FE0F = 2. The line fits a width of exactly its
# measured size and wraps at one less.
prepare full "$PAY/full.json"
render "$PAY/full.json" 1000 AGENTLINE_LAYOUT="mcp,resume,services,disk" AGENTLINE_DROP=
normalize "$T/out" "$T/got"
vs_w=$(python3 -c '
import sys, unicodedata as u
s = open(sys.argv[1], encoding="utf-8").read().splitlines()[0]
print(sum(2 if u.east_asian_width(c) in "WF" else 1 for c in s if c != "️") + s.count("️"))' "$T/got")
check "vs16: the line holds three VS16 emoji" [ "$(grep -o "$(printf '\357\270\217')" "$T/got" | wc -l | tr -d ' ')" -ge 3 ]
prepare full "$PAY/full.json"
render "$PAY/full.json" "$vs_w" AGENTLINE_LAYOUT="mcp,resume,services,disk" AGENTLINE_DROP=
normalize "$T/out" "$T/got"
check "vs16: fits at its measured width ($vs_w)" [ "$(wc -l < "$T/got" | tr -d ' ')" = 1 ]
prepare full "$PAY/full.json"
render "$PAY/full.json" "$(( vs_w - 1 ))" AGENTLINE_LAYOUT="mcp,resume,services,disk" AGENTLINE_DROP=
normalize "$T/out" "$T/got"
check "vs16: wraps one cell narrower" [ "$(wc -l < "$T/got" | tr -d ' ')" = 2 ]

# Colour is stripped from the goldens, so the context warning's colour is
# asserted on the raw render: exceeds_200k_tokens on a 1M window forces the
# yellow ⚠️ at 25%; on a 200k window the same flag is ignored (green 📊).
ctx_raw() {  # ctx_raw <fixture> -> raw render in $T/out
  fill "$FIX/payloads/$1.json" "$PAY/$1.json"
  prepare "$1" "$PAY/$1.json"
  render "$PAY/$1.json" 120
}
ctx_raw one-million-over-200k
check "1M window over 200k: yellow warning" grep -q "${ESC}\[1;33m⚠️ 25%" "$T/out"
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
check "huge numbers: huge window forces the yellow warning" grep -q "${ESC}\[1;33m⚠️ 25%" "$T/out"
if grep -qE 'S:|W:|💰|⏱️|📥' "$T/out"; then fail "huge numbers: a bad or absurd field leaked a segment"; else pass; fi
check "huge numbers: a sane field next to them still shows" grep -q '📤 5.0k' "$T/out"
# An integer literal past 4300 digits made json.loads itself raise on Python
# 3.11+, which lost the whole payload ("⚠ payload"). It is dropped alone now.
big=$(printf '%05000d' 0 | tr 0 7)
printf '{"session_id":"bigint-0001","cwd":"%s","model":{"id":"claude-opus-5"},"context_window":{"total_input_tokens":%s,"total_output_tokens":5000}}\n' \
  "$WORK" "$big" > "$T/bigint.json"
prepare minimal "$T/bigint.json"
render "$T/bigint.json" 120
check "5000-digit int: exit 0 (got $rc)" [ "$rc" = 0 ]
check "5000-digit int: payload still parsed" grep -q 'Opus 5' "$T/out"
check "5000-digit int: field next to it still shows" grep -q '📤 5.0k' "$T/out"
if grep -qE '⚠ payload|📥' "$T/out"; then fail "5000-digit int: payload lost or the int leaked"; else pass; fi

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
printf '%s agent\302\2332J-\302\235x\n' "$TNOW" >> "$SIDE/claude_agents.txt"
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
# A cwd that cleans to nothing used to fall back to the raw value on screen.
printf '{"session_id":"cwd-0003","cwd":"\233\\u001b\233"}\n' > "$T/cwd3.json"
for cj in cwd1 cwd2 cwd3; do
  # Chosen out here, not with a `case` inside the $(...) below: bash 3.2
  # takes the `)` of a case pattern there for the end of the substitution.
  if [ "$cj" = cwd1 ]; then want_folder='/nonexistent/a[31m0;x'
  elif [ "$cj" = cwd2 ]; then want_folder='/nonexistent/b[32m'
  else want_folder=''; fi
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
' "$T/out" "$want_folder" 2>&1); then pass; else fail "$cj: $msg"; fi
  check "$cj: exit 0 (got $rc)" [ "$rc" = 0 ]
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

# Pace arrows (C01): used% − elapsed% beside S:/W:, elapsed inferred from
# resets_at − window length. Timestamps are relative to the pinned TNOW, so
# the elapsed share is exact: +9000 s is 50% of 5 h, +302400 s 50% of 7 d.
pace() {  # pace <five_hour-json> <seven_day-json> [VAR=val...] -> raw $T/out, line 1 in $T/pl
  local f="$1" s="$2"; shift 2
  printf '{"session_id":"pace-0001","cwd":"%s","model":{"id":"claude-opus-5"},"rate_limits":{"five_hour":%s,"seven_day":%s}}\n' \
    "$WORK" "$f" "$s" > "$T/pace.json"
  prepare minimal "$T/pace.json"
  render "$T/pace.json" 300 ${1+"$@"}
  normalize "$T/out" "$T/pn"; head -n 1 "$T/pn" > "$T/pl"
}
pnow=$TNOW
pace "{\"used_percentage\":80.5,\"resets_at\":$((pnow + 9000))}" "{\"used_percentage\":58,\"resets_at\":$((pnow + 302400))}"
check "pace: exit 0 (got $rc)" [ "$rc" = 0 ]
check "pace: stderr empty" [ ! -s "$T/err" ]
check "pace: 5h over pace ⇡30%, before the reset" grep -qF 'S:80% ⇡30% ↻2h' "$T/pl"
check "pace: 5h ⇡ red from 15 points" grep -q "${ESC}\[1;31m⇡30%" "$T/out"
check "pace: week over pace ⇡8%, yellow" grep -q "${ESC}\[1;33m⇡8%" "$T/out"
check "pace: week arrow sits after W:" grep -qF 'W:58% ⇡8% ↻' "$T/pl"
check "pace: S: keeps its absolute colour" grep -q "${ESC}\[1;33mS:80%" "$T/out"
pace "{\"used_percentage\":20,\"resets_at\":$((pnow + 3600))}" "{\"used_percentage\":94,\"resets_at\":$((pnow + 3600))}"
check "pace: 5h under pace ⇣60%, dim" grep -q "${ESC}\[2m⇣60%" "$T/out"
# 94% used at 99% elapsed is under pace, and still red: the wall is near.
check "pace: under pace at 94% stays red" grep -q "${ESC}\[1;31mW:94%" "$T/out"
check "pace: -5 exactly shows ⇣5%" grep -qF 'W:94% ⇣5%' "$T/pl"
pace "{\"used_percentage\":52,\"resets_at\":$((pnow + 9000))}" "{\"used_percentage\":46,\"resets_at\":$((pnow + 302400))}"
if grep -qE '⇡|⇣' "$T/pl"; then fail "pace: within ±5 points shows no arrow"; else pass; fi
# Early in a window (<10% of 5 h, <3% of 7 d), expired, further off than a
# window, ISO or missing resets_at: no arrow, whatever the delta.
pace "{\"used_percentage\":40,\"resets_at\":$((pnow + 17000))}" "{\"used_percentage\":30,\"resets_at\":$((pnow + 600000))}"
if grep -qE '⇡|⇣' "$T/pl"; then fail "pace: early window shows no arrow"; else pass; fi
pace "{\"used_percentage\":40,\"resets_at\":$((pnow - 10))}" "{\"used_percentage\":30,\"resets_at\":$((pnow + 700000))}"
if grep -qE '⇡|⇣' "$T/pl"; then fail "pace: expired or out-of-window reset shows no arrow"; else pass; fi
check "pace: expired reset still shows S:" grep -qF 'S:40%' "$T/pl"
pace '{"used_percentage":90,"resets_at":"2026-09-26T20:00:00Z"}' '{"used_percentage":90}'
if grep -qE '⇡|⇣' "$T/pl"; then fail "pace: ISO or missing resets_at shows no arrow"; else pass; fi
check "pace: ISO resets_at, exit 0 (got $rc)" [ "$rc" = 0 ]
# The arrow rounds used% as S: prints it (F4): 80.9 is S:81%, so ⇡31 at 50%.
pace "{\"used_percentage\":80.9,\"resets_at\":$((pnow + 9000))}" "{\"used_percentage\":58,\"resets_at\":$((pnow + 302400))}"
check "pace: arrow rounds like S: (81 − 50 = ⇡31%)" grep -qF 'S:81% ⇡31%' "$T/pl"
# A used% past 100 is garbage (F5): the percentage shows, no arrow does.
pace "{\"used_percentage\":150,\"resets_at\":$((pnow + 9000))}" "{\"used_percentage\":1e14,\"resets_at\":$((pnow + 302400))}"
check "pace: used% over 100, exit 0 (got $rc)" [ "$rc" = 0 ]
check "pace: used% over 100 still shows S:" grep -qF 'S:150%' "$T/pl"
if grep -qE '⇡|⇣' "$T/pl"; then fail "pace: used% over 100 shows no arrow"; else pass; fi
pace "{\"used_percentage\":80.5,\"resets_at\":$((pnow + 9000))}" "{\"used_percentage\":58,\"resets_at\":$((pnow + 302400))}" AGENTLINE_PACE=0
if grep -qE '⇡|⇣' "$T/pl"; then fail "pace: AGENTLINE_PACE=0 turns it off"; else pass; fi

# Prompt cache (C02): hidden while warm, a live countdown near expiry, the
# first miss cause when cold, nothing when the object is absent or the
# provider reports no caching. The cold case is also a golden fixture.
pcache() {  # pcache <prompt_cache-json> [VAR=val...] -> raw $T/out, line 1 in $T/pl
  local pc="$1"; shift
  printf '{"session_id":"pcache-0002","cwd":"%s","model":{"id":"claude-opus-5"},"prompt_cache":%s}\n' \
    "$WORK" "$pc" > "$T/pcache.json"
  prepare minimal "$T/pcache.json"
  render "$T/pcache.json" 300 ${1+"$@"}
  normalize "$T/out" "$T/pn"; head -n 1 "$T/pn" > "$T/pl"
}
pnow=$TNOW
pcache "{\"warm\":true,\"ttl\":\"5m\",\"expires_at\":$((pnow + 200)),\"hit_ratio\":0.9}"
check "cache: exit 0 (got $rc)" [ "$rc" = 0 ]
check "cache: stderr empty" [ ! -s "$T/err" ]
if grep -q '🗄️' "$T/pl"; then fail "cache: warm and far from expiry is hidden"; else pass; fi
pcache "{\"warm\":true,\"ttl\":\"5m\",\"expires_at\":$((pnow + 45))}"
check "cache: warm within 60 s shows a countdown" grep -qE '🗄️ ↻(4[0-5]|3[0-9])s' "$T/pl"
check "cache: countdown is yellow" grep -q "${ESC}\[1;33m↻" "$T/out"
check "cache: no placeholder left" [ -z "$(tr -cd '\002' < "$T/out")" ]
# A cached tick fills the countdown in from its own epoch, fork-free: point
# the cached token at +125 s and the tick must print it.
python3 -c '
import re, sys
p, t = sys.argv[1], sys.argv[2]
b = open(p, "rb").read()
open(p, "wb").write(re.sub(rb"AGENTLINE_PCEXP:[0-9]+@@", b"AGENTLINE_PCEXP:" + t.encode() + b"@@", b))
' "$(cbase pcache-0002).render" "$(( TNOW + 125 ))"
render "$T/pcache.json" 300
check "cache: a cached tick re-fills the countdown" grep -qE '↻2m0[0-5]s' "$T/out"
pcache "{\"warm\":true,\"ttl\":\"1h\",\"expires_at\":$((pnow + 250))}"
check "cache: a 1h TTL warns from 5 minutes" grep -qE '🗄️ ↻4m[0-9]{2}s' "$T/pl"
pcache "{\"warm\":true,\"ttl\":\"5m\",\"expires_at\":$((pnow + 200))}" AGENTLINE_CACHE_WARN=300
check "cache: AGENTLINE_CACHE_WARN widens the window" grep -qE '🗄️ ↻3m[0-9]{2}s' "$T/pl"
pcache "{\"warm\":true,\"ttl\":\"5m\",\"expires_at\":$(( (pnow + 50) * 1000 ))}"
check "cache: expires_at in milliseconds" grep -qE '🗄️ ↻[0-9]+s' "$T/pl"
# Past expires_at the TTL ran out, whatever `warm` still says (F2) and
# whatever miss was recorded before (F1): the cause shown is ttl.
pcache "{\"warm\":true,\"ttl\":\"5m\",\"expires_at\":$((pnow - 5)),\"recache_tokens_if_cold\":45230}"
check "cache: warm but already past expiry reads cold·ttl" grep -qF '🗄️ cold·ttl ~45k' "$T/pl"
check "cache: expired warm cache is red" grep -q "${ESC}\[1;31mcold" "$T/out"
pcache "{\"warm\":false,\"ttl\":\"5m\",\"expires_at\":$((pnow - 3600)),\"last_miss_cause\":{\"causes\":[\"tools_changed\"]}}"
check "cache: idle past expiry blames the TTL, not an old miss" grep -qF '🗄️ cold·ttl' "$T/pl"
if grep -q 'cold·tools' "$T/pl"; then fail "cache: an old tools miss is not shown after expiry"; else pass; fi
# No expiry to judge by: the recorded cause is the latest response's.
pcache '{"warm":false,"expires_at":null,"last_miss_cause":{"causes":["tools_changed"]}}'
check "cache: cold with no expiry keeps the recorded cause" grep -qF '🗄️ cold·tools' "$T/pl"
# Warm again right after a miss: nothing is shown (no stale miss marker).
pcache "{\"warm\":true,\"ttl\":\"5m\",\"expires_at\":$((pnow + 290)),\"last_miss_cause\":{\"causes\":[\"tools_changed\"]}}"
if grep -q '🗄️' "$T/pl"; then fail "cache: warm after a miss stays hidden"; else pass; fi
pcache '{"warm":false,"last_miss_cause":{"causes":["ttl_expired_5m"]}}'
check "cache: cold, ttl cause" grep -qF '🗄️ cold·ttl' "$T/pl"
check "cache: cold is red" grep -q "${ESC}\[1;31mcold" "$T/out"
pcache '{"warm":false,"last_miss_cause":null,"recache_tokens_if_cold":812}'
check "cache: cold, no cause, recache cost" grep -qF '🗄️ cold ~812' "$T/pl"
# Just under a million rolls over to the next unit (F6), not "1000k".
pcache '{"warm":false,"recache_tokens_if_cold":999600}'
check "cache: 999,600 recache tokens read ~1.0m" grep -qF '🗄️ cold ~1.0m' "$T/pl"
pcache '{"warm":false,"recache_tokens_if_cold":999400}'
check "cache: 999,400 recache tokens read ~999k" grep -qF '🗄️ cold ~999k' "$T/pl"
# The layout measures the countdown at the width its warn window allows
# (F3): with AGENTLINE_CACHE_WARN=720 it prints "11m40s", one cell wider
# than the old "0m00s" guess. At one cell under line 1's real width, a
# line measured right wraps; one measured a cell short overflowed instead.
pcache "{\"warm\":true,\"ttl\":\"5m\",\"expires_at\":$(( TNOW + 700 ))}" AGENTLINE_CACHE_WARN=720
check "cache: a 12-minute window counts down in NNmSSs" grep -qE '🗄️ ↻11m[0-9]{2}s' "$T/pl"
row1w() {  # row1w <normalized> -> cells of its first row
  python3 -c '
import sys, unicodedata
s = open(sys.argv[1], encoding="utf-8").read().split("\n")[0]
print(sum(2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in s))
' "$1"
}
l1w=$(row1w "$T/pl")
render "$T/pcache.json" "$(( l1w - 1 ))" AGENTLINE_CACHE_WARN=720 AGENTLINE_DROP=
normalize "$T/out" "$T/pn"
check "cache: a wide countdown is measured at its printed width" [ "$(row1w "$T/pn")" -lt "$l1w" ]
pcache '{"warm":false,"last_miss_cause":{"causes":["model_changed"]}}'
check "cache: *_changed shortens to its subject" grep -qF '🗄️ cold·model' "$T/pl"
pcache '{"warm":false,"caching_observed":false}'
if grep -q '🗄️' "$T/pl"; then fail "cache: caching_observed false hides it"; else pass; fi
pcache '{"warm":"yes","expires_at":"soon"}'
if grep -q '🗄️' "$T/pl"; then fail "cache: a non-bool warm hides it"; else pass; fi
check "cache: garbage fields, exit 0 (got $rc)" [ "$rc" = 0 ]
pcache "{\"warm\":true,\"ttl\":\"5m\",\"expires_at\":$((pnow + 200)),\"hit_ratio\":0.2}" AGENTLINE_CACHE_VERBOSE=1
check "cache: verbose shows the hit ratio" grep -qF '🗄️ 20%' "$T/pl"
check "cache: a low hit ratio is red" grep -q "${ESC}\[1;31m20%" "$T/out"

# PR badge, worktree and OSC-8 links (C03). The golden (pr-worktree) holds
# the drawn text; the links are asserted here on the raw render.
prw() {  # prw <extra-json-fields> [VAR=val...] -> raw $T/out, line 2 in $T/l2
  local x="$1"; shift
  printf '{"session_id":"prw-0001","cwd":"%s","model":{"id":"claude-opus-5"}%s}\n' "$WORK" "$x" > "$T/prw.json"
  prepare minimal "$T/prw.json"
  seed_probes prw-0001 busy
  render "$T/prw.json" 300 ${1+"$@"}
  normalize "$T/out" "$T/pn"; sed -n 2p "$T/pn" > "$T/l2"
}
PRURL='https://github.com/o/r/pull/7'
prw ",\"pr\":{\"number\":7,\"url\":\"$PRURL\",\"review_state\":\"changes_requested\"}"
check "pr: exit 0 (got $rc)" [ "$rc" = 0 ]
check "pr: stderr empty" [ ! -s "$T/err" ]
check "pr: badge after the branch, state first" grep -qF 'agentline@main │ 🔀 🔴 #7' "$T/l2"
check "pr: number is an OSC-8 link" grep -qF "${ESC}]8;;${PRURL}${BEL}#7${ESC}]8;;${BEL}" "$T/out"
check "pr: repo is an OSC-8 link" grep -qF "${ESC}]8;;https://github.com/OFCode-dev/agentline${BEL}OFCode-dev/agentline${ESC}]8;;${BEL}" "$T/out"
for st in draft:📝 pending:👀 approved:✅; do
  prw ",\"pr\":{\"number\":7,\"review_state\":\"${st%%:*}\"}"
  check "pr: ${st%%:*} glyph" grep -qF "🔀 ${st#*:} #7" "$T/l2"
done
prw ',"pr":{"number":7,"review_state":"commented"}'
check "pr: an undocumented state shows the number alone" grep -qF '🔀 #7 ' "$T/l2"
prw ',"pr":{"number":42,"kind":"mr","url":"https://gitlab.com/o/r/-/merge_requests/42"}'
check "pr: a GitLab MR is !N" grep -qF '🔀 !42' "$T/l2"
# Links stay off under a multiplexer and with AGENTLINE_LINKS=0; the text
# stays.
for envv in TMUX=/tmp/tmux-1/default,1,0 STY=1.pts-0.h ZELLIJ=0 AGENTLINE_LINKS=0; do
  prw ",\"pr\":{\"number\":7,\"url\":\"$PRURL\"}" "$envv"
  if grep -qF "${ESC}]8;;" "$T/out"; then fail "pr: no OSC-8 with $envv"; else pass; fi
  check "pr: text kept with $envv" grep -qF '🔀 #7' "$T/l2"
done
# Hostile or non-https URLs, a non-integer number: no link, or no badge.
prw ',"pr":{"number":7,"url":"javascript:alert(1)"}'
if grep -qF "${ESC}]8;;javascript" "$T/out"; then fail "pr: a javascript: URL is no link"; else pass; fi
prw ',"pr":{"number":7,"url":"https://x/\u0007\u001b]8;;evil"}'
check "pr: control bytes in the URL, exit 0 (got $rc)" [ "$rc" = 0 ]
if grep -qF 'evil' "$T/out" && ! grep -qF "${ESC}]8;;https://x/]8;;evil${BEL}" "$T/out"; then
  fail "pr: a URL with control bytes is cleaned before it is linked"
else
  pass
fi
prw ',"pr":{"number":"7; rm -rf /","url":"https://x/y"}'
if grep -q '🔀' "$T/l2"; then fail "pr: a non-integer number shows no badge"; else pass; fi
prw ',"pr":{"number":0}'
if grep -q '🔀' "$T/l2"; then fail "pr: number 0 shows no badge"; else pass; fi
# Worktree: workspace.git_worktree first, worktree.name as the fallback,
# nothing in the main clone; a path shows its last component.
prw ',"workspace":{"git_worktree":"wt-a"},"worktree":{"name":"wt-b"}'
check "worktree: git_worktree wins" grep -qF '🌳 wt-a' "$T/l2"
prw ',"worktree":{"name":"wt-b"}'
check "worktree: worktree.name as fallback" grep -qF '🌳 wt-b' "$T/l2"
prw ',"workspace":{"git_worktree":"/home/u/repo-wt/feat-x/"}'
check "worktree: a path shows its last component" grep -qF '🌳 feat-x' "$T/l2"
prw ',"workspace":{"current_dir":"/x"}'
if grep -q '🌳' "$T/l2"; then fail "worktree: hidden in the main clone"; else pass; fi
prw ',"workspace":{"git_worktree":{"x":1}}'
if grep -q '🌳' "$T/l2"; then fail "worktree: a non-string is no name"; else pass; fi
# The layout measures a linked segment by its text: at 80 columns line 2
# still fits the same way with links on and off.
prw ",\"pr\":{\"number\":7,\"url\":\"$PRURL\"},\"workspace\":{\"git_worktree\":\"wt-a\"},\"version\":\"3.0.24\""
render "$T/prw.json" - COLUMNS=60
normalize "$T/out" "$T/lk1"
render "$T/prw.json" - COLUMNS=60 AGENTLINE_LINKS=0
normalize "$T/out" "$T/lk0"
check "links: layout identical with links on and off" cmp -s "$T/lk1" "$T/lk0"

# Compaction counter (C05): compact_boundary lines in the transcript, read
# incrementally through ${CACHE_DIR}/compact.<sid>. The transcript is a
# scratch copy the tests grow, truncate and replace.
TR="$T/transcript.jsonl"
BND='{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"auto","preTokens":190000,"postTokens":@P@}}'
bnd() { printf '%s\n' "${BND/@P@/$1}"; }  # bnd <postTokens> -> one boundary line
filler() { printf '{"type":"assistant","message":{"content":"x%s"}}\n' "$1"; }
cmp_render() {  # cmp_render [used_pct-json] -> raw $T/out, line 1 in $T/l1
  printf '{"session_id":"cmp-0001","cwd":"%s","transcript_path":"%s","model":{"id":"claude-opus-5"},"context_window":{"used_percentage":%s,"context_window_size":200000}}\n' \
    "$WORK" "$TR" "${1:-null}" > "$T/cmp.json"
  # The payload stays the same while the transcript changes: no render cache.
  rm -f "$(cbase cmp-0001).render" "$(cbase cmp-0001).payload"
  render "$T/cmp.json" 300
  normalize "$T/out" "$T/cn"; head -n 1 "$T/cn" > "$T/l1"
}
CCACHE="$CACHE_DIR/compact.cmp-0001"
# 0 boundaries: no segment, no estimate.
filler 1 > "$TR"
printf '{"session_id":"cmp-0001"}\n' > "$T/cmp.json"
prepare minimal "$T/cmp.json"
cmp_render
check "compact: exit 0 (got $rc)" [ "$rc" = 0 ]
check "compact: stderr empty" [ ! -s "$T/err" ]
if grep -qE '🔄|📊' "$T/l1"; then fail "compact: no boundary, no segment"; else pass; fi
check "compact: cache written" [ -f "$CCACHE" ]
# 1 boundary, appended: counted from the new bytes; estimate from postTokens.
bnd 20000 >> "$TR"
cmp_render
check "compact: one boundary shows 🔄 1" grep -qF '🔄 1' "$T/l1"
check "compact: null used% shows the dim estimate ~10%" grep -qF '📊 ~10% │ 🔄 1' "$T/l1"
check "compact: the estimate is dim" grep -q "${ESC}\[2m📊 ~10%" "$T/out"
# Growth to 3: only the appended bytes are read; the latest postTokens wins.
{ filler 2; bnd 30000; filler 3; bnd 41000; } >> "$TR"
cmp_render
check "compact: three boundaries show 🔄 3" grep -qF '🔄 3' "$T/l1"
check "compact: latest postTokens drives the estimate (~21%)" grep -qF '📊 ~21%' "$T/l1"
# Same size: served from the cache, the file is not read. Blank the
# boundaries in place, same length; the count must not move.
LC_ALL=C sed 's/compact_boundary/compact_xxxxxxxx/' "$TR" > "$TR.same"; cat "$TR.same" > "$TR"
cmp_render
check "compact: same size is not re-read" grep -qF '🔄 3' "$T/l1"
# A real figure replaces the estimate; the counter stays.
bnd 5000 > "$TR.new"; mv "$TR.new" "$TR"
cmp_render 47
check "compact: real used% wins over the estimate" grep -qF '📊 47% │ 🔄 1' "$T/l1"
# Replaced (new inode, here also smaller): a full rescan, not an addition.
check "compact: a replaced transcript is rescanned (🔄 1, not 4)" grep -qF '🔄 1' "$T/l1"
# Truncated in place (same inode, smaller): rescanned too.
filler 5 > "$TR"
cmp_render
if grep -q '🔄' "$T/l1"; then fail "compact: truncated in place rescans to 0"; else pass; fi
# Missing transcript, or garbage in the cache: no segment, no error.
rm -f "$TR"
cmp_render
check "compact: missing transcript, exit 0 (got $rc)" [ "$rc" = 0 ]
check "compact: missing transcript, stderr empty" [ ! -s "$T/err" ]
if grep -q '🔄' "$T/l1"; then fail "compact: missing transcript shows nothing"; else pass; fi
bnd 9000 > "$TR"; printf 'x y $(touch %s) z\n' "$T/cmp-pwned" > "$CCACHE"
cmp_render
check "compact: a garbage cache is rebuilt" grep -qF '🔄 1' "$T/l1"
check "compact: cache contents never run" [ ! -e "$T/cmp-pwned" ]
# An absurd postTokens (> window) gives no estimate, only the counter.
bnd 999999 > "$TR.new"; mv "$TR.new" "$TR"
cmp_render
if grep -q '📊' "$T/l1"; then fail "compact: estimate over 100% is dropped"; else pass; fi

# Git ahead/behind and dirty counts (C14), against a real repository: the
# probe runs because the payload cwd is not the seeded one. main is one
# commit ahead of origin/main and one behind, mid-merge with one conflicted
# file, one changed tracked file and two untracked ones.
if ! command -v git >/dev/null 2>&1; then
  skip "git status: no git"
elif ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
  # Without a timeout binary the call is skipped by design (branch only).
  skip "git status: no timeout/gtimeout, the counts are off by design"
else
  gq() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main \
           -c commit.gpgsign=false -c advice.detachedHead=false "$@" >/dev/null 2>&1; }
  GB="$T/git-bare.git"; GS="$T/git-seed"; GR="$T/git-repo"; GO="$T/git-other"
  gq init --bare "$GB"; gq init "$GS"
  printf 'a\n' > "$GS/f"; printf 'b\n' > "$GS/t"
  gq -C "$GS" add f t; gq -C "$GS" commit -m base; gq -C "$GS" push "$GB" HEAD:main
  gq clone "$GB" "$GR"; gq clone "$GB" "$GO"
  printf 'o\n' > "$GO/o"; gq -C "$GO" add o; gq -C "$GO" commit -m other; gq -C "$GO" push origin main
  gq -C "$GR" fetch
  gq -C "$GR" checkout -b side; printf 'x\n' > "$GR/f"; gq -C "$GR" commit -am side
  gq -C "$GR" checkout main; printf 'y\n' > "$GR/f"; gq -C "$GR" commit -am mine
  gq -C "$GR" merge side
  printf 'z\n' > "$GR/t"; : > "$GR/new1"; : > "$GR/new2"
  gst() {  # gst <repo> [VAR=val...] -> line 2 in $T/g2
    local r="$1"; shift
    printf '{"session_id":"gst-0001","cwd":"%s","model":{"id":"claude-opus-5"}}\n' "$r" > "$T/gst.json"
    prepare minimal "$T/gst.json"; rm -f "$(cbase gst-0001).probes"
    render "$T/gst.json" 300 ${1+"$@"}
    normalize "$T/out" "$T/gn"; sed -n 2p "$T/gn" > "$T/g2"
  }
  gst "$GR"
  check "git status: exit 0 (got $rc)" [ "$rc" = 0 ]
  check "git status: stderr empty" [ ! -s "$T/err" ]
  check "git status: ↑1↓1 ±1 ?2 ✖1 after the branch" grep -qF '@main ↑1↓1 ±1 ?2 ✖1' "$T/g2"
  check "git status: dirty counts are dim" grep -q "${ESC}\[2m±1 ?2 ✖1" "$T/out"
  gst "$GR" AGENTLINE_GIT_UNTRACKED=0
  check "git status: AGENTLINE_GIT_UNTRACKED=0 skips untracked" grep -qF '@main ↑1↓1 ±1 ✖1' "$T/g2"
  gst "$GR" AGENTLINE_GIT_STATUS=0
  check "git status: AGENTLINE_GIT_STATUS=0 leaves the branch alone" grep -qE '@main( │|$)' "$T/g2"
  gst "$GO"
  check "git status: a clean, even repo shows the branch alone" grep -qE '@main( │|$)' "$T/g2"
  # The counts ride the probe cache: a third untracked file appears, and a
  # second render in the same cwd within the TTL still shows the cached ?2.
  gst "$GR"
  : > "$GR/new3"
  rm -f "$(cbase gst-0001).render" "$(cbase gst-0001).payload"
  render "$T/gst.json" 300
  normalize "$T/out" "$T/gn"
  check "git status: replayed from the probe cache" grep -qF '@main ↑1↓1 ±1 ?2 ✖1' "$T/gn"

  # A repository's own .git/config must not get to run code (H0): an
  # unpacked tarball with core.fsmonitor or a clean filter ran both on every
  # probe. Each hostile repo is first proven hostile — a plain `git status`
  # in it does touch the marker — and then rendered: the marker must stay
  # absent and the branch still show.
  GM="$T/gm"; GMARK="$T/git-pwned"
  printf '#!/bin/sh\necho "fsmonitor $*" >> %s\nexit 1\n' "$GMARK" > "$T/fsmon.sh"; chmod +x "$T/fsmon.sh"
  hostile() {  # hostile <name> <label> — render repo $GM/<name>, which must be hostile
    rm -f "$GMARK"; touch "$GM/$1/f"
    git -C "$GM/$1" status --porcelain >/dev/null 2>&1
    if [ -e "$GMARK" ]; then pass; else fail "git hostile $2: control, plain git status ran nothing"; fi
    rm -f "$GMARK"; touch "$GM/$1/f"
    gst "$GM/$1"
    if [ -e "$GMARK" ]; then fail "git hostile $2: render ran $(tr '\n' ' ' < "$GMARK")"; rm -f "$GMARK"; else pass; fi
    check "git hostile $2: branch still shown" grep -qE '@main( │|$)' "$T/g2"
  }
  mkrepo() {  # mkrepo <name> — a clone one commit ahead of origin
    gq clone "$GB" "$GM/$1"; printf 'f\n' > "$GM/$1/f"
    gq -C "$GM/$1" add f; gq -C "$GM/$1" commit -m f
  }
  mkdir -p "$GM"
  mkrepo fsmon; git -C "$GM/fsmon" config core.fsmonitor "$T/fsmon.sh"
  hostile fsmon "core.fsmonitor"
  mkrepo filter
  printf 'f filter=pwn\n' > "$GM/filter/.git/info/attributes"
  printf '[Filter "pwn"]\n\tclean = "echo clean >> %s; cat"\n' "$GMARK" >> "$GM/filter/.git/config"
  hostile filter "clean filter"
  mkrepo include
  printf '[core]\n\tfsmonitor = %s\n' "$T/fsmon.sh" > "$GM/include/.git/evil.cfg"
  printf '[Include]\n\tpath = evil.cfg\n' >> "$GM/include/.git/config"
  hostile include "include.path"
  # A linked worktree reads the main repository's config through commondir.
  gq -C "$GM/filter" worktree add "$GM/filter-wt" -b wt
  rm -f "$GMARK"; touch "$GM/filter-wt/f"; gst "$GM/filter-wt"
  if [ -e "$GMARK" ]; then fail "git hostile worktree: render ran the common config's filter"; rm -f "$GMARK"; else pass; fi
  check "git hostile worktree: branch still shown" grep -qF '@wt' "$T/g2"
  # A submodule's own config is never read: no child git is started in it.
  # The superproject is benign, so its counts still show.
  mkrepo super
  gq -c protocol.file.allow=always -C "$GM/super" submodule add "$GB" sm
  gq -C "$GM/super" commit -m sm
  printf 'f filter=pwn\n' > "$GM/super/sm/.gitattributes"
  printf 'x\n' > "$GM/super/sm/f"
  git -C "$GM/super/sm" config filter.pwn.clean "echo sub >> $GMARK; cat"
  rm -f "$GMARK"; : > "$GM/super/new"; gst "$GM/super"
  if [ -e "$GMARK" ]; then fail "git hostile submodule: render ran the submodule's filter"; rm -f "$GMARK"; else pass; fi
  check "git submodule: the superproject's counts still show" grep -qF '@main ↑2 ?1' "$T/g2"
  # A benign config with unrelated keys keeps its counts, whatever the case.
  mkrepo benign
  printf '[Core]\n\tFileMode = true\n[remote "x"]\n\tpartialclonefilter = blob:none\n' >> "$GM/benign/.git/config"
  : > "$GM/benign/new"; gst "$GM/benign"
  check "git benign config: counts shown" grep -qF '@main ↑1 ?1' "$T/g2"
  # Past 64 KB of status output one awk counts, not the read loop (H0b):
  # 1,600 untracked files with long names are ~74 KB, counted exactly.
  mkrepo big
  i=0; while [ "$i" -lt 1600 ]; do : > "$GM/big/untracked-file-with-a-rather-long-name-$i"; i=$((i + 1)); done
  printf 'z\n' > "$GM/big/f"
  gst "$GM/big"
  check "git status: a >64 KB status is counted in full" grep -qF '@main ↑1 ±1 ?1600' "$T/g2"
fi

# Breadcrumb (C14): project_dir differing from cwd leads the path, dim.
printf '{"session_id":"crumb-0001","cwd":"%s","workspace":{"project_dir":"/src/launch/"}}\n' "$WORK" > "$T/crumb.json"
prepare minimal "$T/crumb.json"
render "$T/crumb.json" 300; normalize "$T/out" "$T/cr"
check "breadcrumb: launch folder leads the path" grep -qF '↖ launch ~/work' "$T/cr"
check "breadcrumb: dim" grep -q "${ESC}\[2m↖ launch" "$T/out"
printf '{"session_id":"crumb-0001","cwd":"%s","workspace":{"project_dir":"%s/"}}\n' "$WORK" "$WORK" > "$T/crumb.json"
render "$T/crumb.json" 300; normalize "$T/out" "$T/cr"
if grep -q '↖' "$T/cr"; then fail "breadcrumb: same dir (trailing slash) shows none"; else pass; fi

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
# The cache files are read a line at a time (bash 3.2 reads byte by byte
# with -d ''). A file with more after its first line never matches: an extra
# line after the payload key, or a second line in the body.
prepare full "$p"; render "$p" 120
printf '\nextra' >> "$(cbase "$sid").payload"
printf '%s\n%s' "$(date +%s)" "CACHED $CLOCK_TOK" > "$render_file"
render "$p" 120
check "payload key with a trailing line is no match" grep -q 'Opus 5' "$T/out"
printf '%s\n%s\n%s' "$(date +%s)" "CACHED $CLOCK_TOK" "MORE" > "$render_file"
render "$p" 120
check "render body with a second line is not served" sh -c "! grep -q 'CACHED' '$T/out' && grep -q 'Opus 5' '$T/out'"
# A pretty-printed (multi-line) payload keeps the verbatim read, and hits.
python3 -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1])), indent=2))' "$p" > "$T/pretty.json"
prepare full "$T/pretty.json"; render "$T/pretty.json" 120
printf '%s\n%s' "$(date +%s)" "CACHED $CLOCK_TOK" > "$render_file"
render "$T/pretty.json" 120
check "multi-line payload: tick serves the cached body" grep -Eq '^CACHED [0-9]{2}:[0-9]{2}:[0-9]{2}$' "$T/out"
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
  # Reads are buffered on every bash: ~1,700 read(2) calls a tick on bash 3.2
  # when the cache files were read with -d ''.
  ( cd "$WORK" && run_env AGENTLINE_WIDTH=120 strace -f -qq -o "$T/st-read" -e trace=read \
      "$TEST_BASH" "$ROOT/agentline.sh" < "$p" > /dev/null 2>&1 )
  n_reads=$(grep -c 'read(' "$T/st-read")
  check "fast path: buffered reads, got $n_reads read(2) calls" [ "$n_reads" -lt 200 ]
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
# The pinned clock (H3): time passing between the fixture and the render
# changes nothing, and AGENTLINE_NOW is what the countdown is worked out
# from — full.json resets at TNOW + 7230, an hour on from TNOW it is 1h0m.
# A value that is not all digits is ignored.
prepare full "$p"; sleep 2; render "$p" 120; normalize "$T/out" "$T/got"
check "clock: a render 2 s after the fixture still matches the golden" cmp -s "$T/got" "$GOLD/full.w120.txt"
prepare full "$p"; render "$p" 120 AGENTLINE_NOW=$(( TNOW + 3600 )); normalize "$T/out" "$T/got"
check "clock: AGENTLINE_NOW drives the countdown" grep -qF '↻1h0m' "$T/got"
prepare full "$p"; render "$p" 120 AGENTLINE_NOW="$(( TNOW + 3600 ))x"; normalize "$T/out" "$T/got"
if grep -qF '↻1h0m' "$T/got"; then fail "clock: a non-numeric AGENTLINE_NOW is ignored"; else pass; fi

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
# When dropping cannot make a line fit one row, the line wraps anyway, and
# the segments dropped on the way come back as long as the row count stays
# the same (they used to stay lost, with the wrapped rows half empty).
# COLUMNS=80: line 1 takes two rows either way, so the second row gets the
# duration, output tokens, lines and host readings back.
prepare full "$p"; render "$p" - COLUMNS=80; normalize "$T/out" "$T/got"
check "layout: COLUMNS=80 line 1 is two rows" sh -c "sed -n 2p '$T/got' | grep -q '^💰'"
for want in '⏱️' '📤' '📝' '🔥' '💽'; do
  check "layout: COLUMNS=80 wrapped line 1 re-gains $want" sh -c "sed -n 2p '$T/got' | grep -qF '$want'"
done
if msg=$(rows_fit "$T/got" 78 2>&1); then pass; else fail "layout: COLUMNS=80 re-insert: $msg"; fi
# COLUMNS=100: a git branch too long for line 2 to fit one row (patched into
# the seeded probe cache). Version, e-mail and date were dropped and the
# line wrapped all the same, its second row 60 cells short.
long_branch="feature/an-unusually-long-branch-name-for-narrow-x"
prepare full "$p"
check "probe cache seeded as valid UTF-8 in any harness locale" \
  python3 -c 'import sys; open(sys.argv[1], "rb").read().decode("utf-8")' "$(cbase "$(sid_of "$p")").probes"
# LC_ALL=C: a cache file is bytes, and BSD sed rejects a byte that is not
# UTF-8 under a UTF-8 locale instead of copying it.
LC_ALL=C sed "s#^git_branch=.*#git_branch=$long_branch#" "$(cbase "$(sid_of "$p")").probes" > "$T/probes.tmp"
cat "$T/probes.tmp" > "$(cbase "$(sid_of "$p")").probes"
render "$p" - COLUMNS=100; normalize "$T/out" "$T/got"
check "layout: COLUMNS=100 long branch shown" has "$T/got" "$long_branch"
for want in 'v3.0.24' '🤖 o*****t@e*****e.com' 'DD/MM/YYYY Day'; do
  check "layout: COLUMNS=100 wrapped line 2 re-gains $want" has "$T/got" "$want"
done
check "layout: COLUMNS=100 line 2 still two rows" \
  [ "$(grep -c -e "$long_branch" -e 'v3.0.24' -e 'DD/MM' -e 'golden-full' "$T/got")" = 2 ]
if msg=$(rows_fit "$T/got" 98 2>&1); then pass; else fail "layout: COLUMNS=100 re-insert: $msg"; fi
# A segment in its warning state is never dropped: a 95% disk at a narrow
# width used to lose its red ⚠️ silently.
for cols in 100 62; do
  prepare full "$p"
  LC_ALL=C sed 's#^disk_pct=.*#disk_pct=95#' "$(cbase "$(sid_of "$p")").probes" > "$T/probes.tmp"
  cat "$T/probes.tmp" > "$(cbase "$(sid_of "$p")").probes"
  render "$p" - COLUMNS=$cols; normalize "$T/out" "$T/got"
  check "layout: COLUMNS=$cols keeps a disk warning" has "$T/got" '⚠️ 💽 95%'
done
# Likewise a cold prompt cache, the last name in the default drop list.
printf '{"session_id":"warn-0001","cwd":"%s","model":{"id":"claude-opus-5"},"context_window":{"used_percentage":12},"cost":{"total_cost_usd":1.5,"total_duration_ms":600000},"prompt_cache":{"warm":false,"last_miss_cause":"ttl"}}\n' \
  "$WORK" > "$T/warn.json"
prepare minimal "$T/warn.json"; render "$T/warn.json" - COLUMNS=30; normalize "$T/out" "$T/got"
check "layout: COLUMNS=30 keeps a cold cache" has "$T/got" '🗄️ cold'
# A busy session at COLUMNS=122: once the default drop list ran out, line 1
# still overflowed by a few cells and wrapped the host readings onto a row
# of their own. cpu, mem and disk now close the list (host info, the least
# a line about the session needs), so line 1 fits one row.
printf '{"session_id":"cols-0001","cwd":"%s","model":{"id":"claude-fable-5-1"},"effort":{"level":"xhigh"},"thinking":{"enabled":true},"fast_mode":true,"exceeds_200k_tokens":true,"context_window":{"used_percentage":25,"context_window_size":1000000,"total_input_tokens":250000},"rate_limits":{"five_hour":{"used_percentage":71,"resets_at":%s},"seven_day":{"used_percentage":58,"resets_at":1790208000},"seven_day_overage_included":{"used_percentage":30}},"cost":{"total_cost_usd":123.468,"total_duration_ms":600000}}\n' \
  "$WORK" "$(( TNOW + 7230 ))" > "$T/cols.json"
prepare minimal "$T/cols.json"; seed_probes cols-0001 busy
render "$T/cols.json" - COLUMNS=122; normalize "$T/out" "$T/got"
check "layout: busy session at COLUMNS=122 keeps line 1 on one row" sh -c "sed -n 2p '$T/got' | grep -q '~/work'"
check "layout: COLUMNS=122 line 1 keeps model, context, limits and cost" \
  sh -c "head -n 1 '$T/got' | grep -q 'Fable 5.1.*xhigh.*25% >200k.*S:71%.*W:58% F:30%.*123.47'"
if grep -q '🔥' "$T/got"; then fail "layout: COLUMNS=122 kept cpu, first of the host readings to go"; else pass; fi
if msg=$(rows_fit "$T/got" 120 2>&1); then pass; else fail "layout: busy COLUMNS=122: $msg"; fi
# With room to spare the host readings stay: they are dropped last, not always.
prepare minimal "$T/cols.json"; seed_probes cols-0001 busy
render "$T/cols.json" - COLUMNS=202; normalize "$T/out" "$T/got"
check "layout: COLUMNS=202 keeps the host readings" sh -c "head -n 1 '$T/got' | grep -q '🔥 37% │ 💾 6.2G │ 💽 41%'"
# AGENTLINE_WIDTH is an explicit override and wins over COLUMNS.
prepare full "$p"; render "$p" 200 COLUMNS=62; normalize "$T/out" "$T/got"
check "layout: AGENTLINE_WIDTH wins over COLUMNS" has "$T/got" '📥 8.4m'
# The protected four stay even when AGENTLINE_DROP names them.
prepare full "$p"; render "$p" 20 AGENTLINE_DROP="model,ctx,5h,week,cost"; normalize "$T/out" "$T/got"
for want in 'Opus 5' '📊 42%' 'S:71%' 'W:58%'; do
  check "layout: AGENTLINE_DROP cannot drop $want" has "$T/got" "$want"
done
# cost goes where bringing it back would cost a row: a layout of just the
# protected four and cost, so the result does not hang on how the other
# segments of line 1 happen to pack at this width.
prepare full "$p"; render "$p" 20 AGENTLINE_DROP="model,ctx,5h,week,cost" AGENTLINE_LAYOUT="model,ctx,5h,week,cost"
normalize "$T/out" "$T/got"
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
check "layout: custom second line" grep -q '^📊 42% │ ♻️ claude --resume full-0001$' "$T/got"
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

# The layout pass gets the segments on stdin (one argv string is capped at
# 128 KB), and if it fails anyway bash joins each line itself instead of
# printing nothing. A python3 shim fails the layout pass alone.
LSHIM="$T/layoutshim"; mkdir -p "$LSHIM"
cat > "$LSHIM/python3" <<EOF
#!/bin/sh
case "\$*" in *"def fit("*) exit 1 ;; esac
exec "$(command -v python3)" "\$@"
EOF
chmod +x "$LSHIM/python3"
prepare full "$p"; render "$p" 120 PATH="$LSHIM:$PATH_F"; normalize "$T/out" "$T/got"
check "layout fallback: exit 0 (got $rc)" [ "$rc" = 0 ]
check "layout fallback: line 1 joined" grep -q '^Opus 5 🧠 │ .*📊 42% │ S:71%' "$T/got"
check "layout fallback: line 2 joined" grep -q '^v3.0.24 │ ~/work │ ' "$T/got"
check "layout fallback: resume line" grep -qF 'claude --resume full-0001' "$T/got"
fill "$FIX/payloads/fable-max.json" "$PAY/fable-max.json"
prepare fable-max "$PAY/fable-max.json"; render "$PAY/fable-max.json" 120 PATH="$LSHIM:$PATH_F"
check "layout fallback: Fable name shown plain" grep -qF '✦ Fable 5.1' "$T/out"
if grep -q 'AGENTLINE_GRAD' "$T/out"; then fail "layout fallback: gradient marker leaked"; else pass; fi
# A 7000-character model name reaches the layout pass whole.
huge=$(printf '%07000d' 0 | tr 0 M)
printf '{"session_id":"huge-0001","cwd":"%s","model":{"id":"x-custom","display_name":"%s"},"context_window":{"used_percentage":12}}\n' \
  "$WORK" "$huge" > "$T/huge.json"
prepare minimal "$T/huge.json"; render "$T/huge.json" 120
check "7000-char model name: exit 0 (got $rc)" [ "$rc" = 0 ]
check "7000-char model name: shown whole" grep -qF "$huge" "$T/out"
check "7000-char model name: the other lines survive" grep -q '📊 12%' "$T/out"
# Segments past the 128 KB argv cap (host data: a dev-port list patched into
# the probe cache) used to fail the pass with E2BIG and blank every line.
prepare full "$p"
python3 - "$(cbase "$(sid_of "$p")").probes" <<'PYEOF'
import sys
path = sys.argv[1]
lines = open(path, 'rb').read().split(b'\n')
lines = [b'dev_ports=' + b'node\\(3000\\)\\ ' * 13000 if l.startswith(b'dev_ports=') else l for l in lines]
open(path, 'wb').write(b'\n'.join(lines))
PYEOF
render "$p" 120; normalize "$T/out" "$T/got"
check "140 KB of segments: exit 0 (got $rc)" [ "$rc" = 0 ]
check "140 KB of segments: line 1 still laid out" grep -q '^Opus 5 🧠 │ ' "$T/got"
check "140 KB of segments: the long segment shown" grep -qF 'node(3000) node(3000)' "$T/got"

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
# The python fallback reads the unmasked address on stdin: argv is visible
# to every local user through ps. A shim logs each python3's arguments.
cat > "$PYSHIM/python3" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/py-argv"
exec "$REAL_PY" "\$@"
EOF
printf '{"session_id":"mask-0002","cwd":"%s","account":{"email":"şule@örnek.com"}}\n' "$WORK" > "$T/mask.json"
prepare minimal "$T/mask.json"; rm -f "$T/py-argv"
render "$T/mask.json" 120 AGENTLINE_LAYOUT=email PATH="$PYSHIM:$PATH_F"; normalize "$T/out" "$T/got"
check "e-mail mask: python fallback still masks" grep -qxF '🤖 ş**e@ö***k.com' "$T/got"
check "e-mail mask: python fallback ran" [ -s "$T/py-argv" ]
if grep -qF 'örnek' "$T/py-argv" 2>/dev/null; then fail "e-mail mask: unmasked address in python argv"; else pass; fi

# ===========================================================================
# 3c. Host probes: services panel, dev ports
# ===========================================================================
# The probes run for real here (AGENTLINE_PROBE_TTL=0), with shims in front
# of the two whose answers the checks depend on. The systemctl shim answers
# `show` the way systemd 255 does: one block per unit in argument order,
# properties in its own order (not the order asked for), LoadState=not-found
# for an unknown unit, and an abort at the first invalid name.
HSHIM="$T/hostshim"; mkdir -p "$HSHIM"
cat > "$HSHIM/systemctl" <<EOF
#!/bin/sh
echo "\$*" >> "$T/systemctl-calls"
[ "\$1" = show ] || exit 1
while [ \$# -gt 0 ] && [ "\$1" != -- ]; do shift; done; shift
first=1
for u in "\$@"; do
  case "\$u" in *' '*) echo "Invalid unit name \$u" >&2; exit 1 ;; esac
  case "\$u" in
    web) l=loaded a=active ;; db) l=loaded a=failed ;; masked) l=masked a=inactive ;;
    reload) l=loaded a=reloading ;; slow) exec sleep 5 ;; *) l=not-found a=inactive ;;
  esac
  [ \$first = 1 ] || echo; first=0
  printf 'ActiveState=%s\nLoadState=%s\n' "\$a" "\$l"
done
EOF
cat > "$HSHIM/ss" <<'EOF'
#!/bin/sh
cat <<'X'
State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
LISTEN 0      511    0.0.0.0:3000      0.0.0.0:*    users:(("node",pid=11,fd=20))
LISTEN 0      511    [::]:5173         [::]:*       users:(("(vite)",pid=12,fd=21))
LISTEN 0      128    0.0.0.0:22        0.0.0.0:*    users:(("sshd",pid=1,fd=3))
X
EOF
chmod +x "$HSHIM/systemctl" "$HSHIM/ss"
p="$PAY/minimal.json"
hrender() {  # hrender <services-conf> [VAR=val...] -> normalized $T/got
  local conf="$1"; shift
  prepare minimal "$p"; rm -f "$T/systemctl-calls"
  render "$p" 120 PATH="$HSHIM:$PATH_F" AGENTLINE_PROBE_TTL=0 AGENTLINE_SERVICES="$conf" ${1+"$@"}
  normalize "$T/out" "$T/got"
}
n_calls() { if [ -f "$T/systemctl-calls" ]; then wc -l < "$T/systemctl-calls" | tr -d ' '; else echo 0; fi; }
printf 'web:Web\ndb:DB\ngone:Gone\n# note\n\nmasked:Masked\nreload:Reload\n' > "$T/svc.conf"
hrender "$T/svc.conf" AGENTLINE_LAYOUT=services
check "services: one systemctl call for five units (got $(n_calls))" [ "$(n_calls)" = 1 ]
check "services: states read by name, missing unit skipped" grep -qxF '🛡️ Web ✓ · DB ✗ · Masked ✗ · Reload ✓' "$T/got"
check "services: probe exit 0 (got $rc)" [ "$rc" = 0 ]
check "services: probe stderr empty" [ ! -s "$T/err" ]
# An invalid name aborts the batch; each unit is then asked on its own, and
# only the bad line is lost.
printf 'web:Web\nbad name:Bad\ndb:DB\n' > "$T/svc.conf"
hrender "$T/svc.conf" AGENTLINE_LAYOUT=services
check "services: invalid name re-asked per unit (got $(n_calls) calls)" [ "$(n_calls)" = 4 ]
check "services: invalid name skipped, the rest shown" grep -qxF '🛡️ Web ✓ · DB ✗' "$T/got"
# Globs never reach systemctl (show would expand them and shift the states
# onto the wrong labels), and a template shows ✗ without being asked (show
# rejects it as a bad name, which re-asked every unit on every probe).
printf 'web:Web\nssh*:Glob\nno?match:Q\nx[ab]:B\ngetty@.service:Getty\ndb:DB\n' > "$T/svc.conf"
hrender "$T/svc.conf" AGENTLINE_LAYOUT=services
check "services: globs skipped, template shown failed" grep -qxF '🛡️ Web ✓ · Getty ✗ · DB ✗' "$T/got"
check "services: one systemctl call (got $(n_calls))" [ "$(n_calls)" = 1 ]
if grep -qE '[*?[]|@\.' "$T/systemctl-calls"; then fail "services: a glob or template was asked: $(cat "$T/systemctl-calls")"; else pass; fi
# A config of templates alone asks nothing.
printf 'getty@.service:Getty\n' > "$T/svc.conf"
hrender "$T/svc.conf" AGENTLINE_LAYOUT=services
check "services: templates only, no systemctl call (got $(n_calls))" [ "$(n_calls)" = 0 ]
check "services: templates only, still shown" grep -qxF '🛡️ Getty ✗' "$T/got"
# A systemd that does not answer is cut off, not waited for.
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  printf 'web:Web\nslow:Slow\n' > "$T/svc.conf"
  t0=$SECONDS; hrender "$T/svc.conf" AGENTLINE_LAYOUT=services,ports; dt=$(( SECONDS - t0 ))
  check "services: hung systemctl cut off (render took ${dt}s)" [ "$dt" -lt 5 ]
  check "services: hung systemctl not re-asked (got $(n_calls) calls)" [ "$(n_calls)" = 1 ]
  check "services: hung systemctl hides the panel only" grep -qF 'node(3000)' "$T/got"
else
  skip "services: no timeout/gtimeout for the hang guard"
fi
# Dev ports: labelled by the ss awk itself, parentheses round a process name
# trimmed, system ports (< 3000) left out.
hrender /nonexistent AGENTLINE_LAYOUT=ports
check "dev ports: node(3000) labelled" grep -qF 'node(3000)' "$T/got"
check "dev ports: (vite) trimmed to vite(5173)" grep -qF 'vite(5173)' "$T/got"
if grep -q 'sshd' "$T/got"; then fail "dev ports: a port below 3000 shown"; else pass; fi

# Git: the branch is read from HEAD, git runs only for the origin URL (and for
# the layouts a file read cannot settle), under --no-optional-locks and a
# timeout. The git shim logs each call and hands it to the real git, or with
# GIT_SHIM_HANG=1 hangs the way a git on a dead NFS mount does.
if REAL_GIT=$(command -v git); then
  cat > "$HSHIM/git" <<EOF
#!/bin/sh
echo "\$*" >> "$T/git-calls"
[ -n "\$GIT_SHIM_HANG" ] && exec sleep 5
[ -n "\$GIT_SHIM_STATUS_HANG" ] && case "\$*" in *" status "*) exec sleep 5 ;; esac
exec "$REAL_GIT" "\$@"
EOF
  chmod +x "$HSHIM/git"
  G="$T/gitfx"; rm -rf "$G"; mkdir -p "$G/plain" "$G/wt" "$G/det/.git" "$G/rt/.git"
  gx() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$REAL_GIT" "$@" >/dev/null 2>&1; }
  gx init -q "$G/repo"; gx -C "$G/repo" symbolic-ref HEAD refs/heads/feat/x
  gx -C "$G/repo" remote add origin git@github.com:octo/repo.git
  mkdir -p "$G/repo/sub/deep" "$G/repo/.git/worktrees/w"
  # A linked worktree, spelled by hand: a relative gitdir: file.
  printf 'ref: refs/heads/wt-branch\n' > "$G/repo/.git/worktrees/w/HEAD"
  printf 'gitdir: ../repo/.git/worktrees/w\n' > "$G/wt/.git"
  printf '0123456789abcdef0123456789abcdef01234567\n' > "$G/det/.git/HEAD"
  printf 'ref: refs/heads/.invalid\n' > "$G/rt/.git/HEAD"
  grender() {  # grender <cwd> [VAR=val...] -> normalized $T/got, $T/git-calls
    local c="$1"; shift
    printf '{"session_id":"git-0001","cwd":"%s"}\n' "$c" > "$T/git.json"
    prepare minimal "$T/git.json"; rm -f "$T/git-calls"
    # The status call (C14) is off here: these tests count the calls the
    # branch and remote reads make; it has checks of its own below.
    render "$T/git.json" 120 PATH="$HSHIM:$PATH_F" AGENTLINE_PROBE_TTL=0 AGENTLINE_LAYOUT=git \
      AGENTLINE_GIT_STATUS=0 ${1+"$@"}
    normalize "$T/out" "$T/got"
  }
  git_calls() { if [ -f "$T/git-calls" ]; then wc -l < "$T/git-calls" | tr -d ' '; else echo 0; fi; }
  for c in repo repo/sub/deep; do
    grender "$G/$c"
    check "git [$c]: branch from HEAD, repo from origin" grep -qxF '🌿 octo/repo@feat/x' "$T/got"
    check "git [$c]: one git call, for the origin URL (got $(git_calls))" [ "$(git_calls)" = 1 ]
  done
  check "git: runs with --no-optional-locks" grep -q -- '--no-optional-locks .*remote get-url origin' "$T/git-calls"
  # With the status call on: one more git, lock-free, and none outside a
  # repo or on a detached HEAD.
  if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    grender "$G/repo" AGENTLINE_GIT_STATUS=1
    check "git status: one call beside the origin URL (got $(git_calls))" [ "$(git_calls)" = 2 ]
    check "git status: runs with --no-optional-locks" grep -q -- '--no-optional-locks .*status --porcelain=v2 --branch' "$T/git-calls"
    grender "$G/det" AGENTLINE_GIT_STATUS=1
    check "git status: detached HEAD, no call (got $(git_calls))" [ "$(git_calls)" = 0 ]
    grender "$G/plain" AGENTLINE_GIT_STATUS=1
    check "git status: not a repo, no call (got $(git_calls))" [ "$(git_calls)" = 0 ]
    # A status that times out is remembered: the next probe misses in that
    # directory skip it (only the origin URL is asked) until the back-off
    # runs out; the branch shows throughout (H0b).
    GS_FILE="$(cbase git-0001).gitslow"
    grender "$G/repo" AGENTLINE_GIT_STATUS=1 GIT_SHIM_STATUS_HANG=1
    check "git status: a timed-out status keeps the branch" grep -qxF '🌿 octo/repo@feat/x' "$T/got"
    check "git status: a timeout is remembered" [ -f "$GS_FILE" ]
    grerender() {  # grerender — the same payload again, the session's caches kept but the render's
      rm -f "$T/git-calls" "$(cbase git-0001).render" "$(cbase git-0001).payload"
      render "$T/git.json" 120 PATH="$HSHIM:$PATH_F" AGENTLINE_PROBE_TTL=0 AGENTLINE_LAYOUT=git \
        AGENTLINE_GIT_STATUS=1 GIT_SHIM_STATUS_HANG=1
      normalize "$T/out" "$T/got"
    }
    grerender
    check "git status: backed off, origin URL only (got $(git_calls) calls)" [ "$(git_calls)" = 1 ]
    check "git status: backed off, branch kept" grep -qxF '🌿 octo/repo@feat/x' "$T/got"
    { printf '1\n'; sed -n 2p "$GS_FILE"; } > "$T/gs.tmp"; cat "$T/gs.tmp" > "$GS_FILE"
    grerender
    check "git status: asked again once the back-off ran out (got $(git_calls) calls)" [ "$(git_calls)" = 2 ]
    printf '%s\n%s' 9999999999 /some/other/dir > "$GS_FILE"
    grerender
    check "git status: a back-off for another cwd does not apply (got $(git_calls) calls)" [ "$(git_calls)" = 2 ]
  fi
  grender "$G/wt"
  check "git [worktree]: gitdir: file followed" grep -qF 'wt-branch' "$T/got"
  grender "$G/det"
  check "git [detached]: no branch" [ ! -s "$T/got" ]
  check "git [detached]: no git call (got $(git_calls))" [ "$(git_calls)" = 0 ]
  grender "$G/plain"
  check "git [not a repo]: no git call (got $(git_calls))" [ "$(git_calls)" = 0 ]
  grender "$G/rt"
  check "git [reftable HEAD]: asks git" grep -q 'branch --show-current' "$T/git-calls"
  grender "$G/plain" GIT_DIR="$G/repo/.git"
  check "git [\$GIT_DIR]: asks git" grep -qF 'feat/x' "$T/got"
  # A tilde in the repo name survives the probe cache. bash 3.2's %q left
  # `~` bare, so the replayed assignment expanded "~root/x" to "/root/x".
  gx -C "$G/repo" remote set-url origin https://git.sr.ht/~root/x
  grender "$G/repo"
  check "git [tilde]: probed repo name" grep -qxF '🌿 ~root/x@feat/x' "$T/got"
  rm -f "$(cbase git-0001).render" "$(cbase git-0001).payload"
  render "$T/git.json" 120 PATH="$HSHIM:$PATH_F" AGENTLINE_LAYOUT=git
  normalize "$T/out" "$T/got"
  check "git [tilde]: replayed from the probe cache unexpanded" grep -qxF '🌿 ~root/x@feat/x' "$T/got"
  gx -C "$G/repo" remote set-url origin git@github.com:octo/repo.git
  if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    t0=$SECONDS; grender "$G/plain" GIT_DIR="$G/repo/.git" GIT_SHIM_HANG=1; dt=$(( SECONDS - t0 ))
    check "git: a hung git is cut off (render took ${dt}s)" [ "$dt" -lt 4 ]
    check "git: a hung git still exits 0 (got $rc)" [ "$rc" = 0 ]
    check "git: a hung git hides the branch" [ ! -s "$T/got" ]
  else
    skip "git: no timeout/gtimeout for the hang guard"
  fi
  # HEAD is only read when it is a regular file this user owns, and for at
  # most 1024 characters. These renders run under an outer timeout of their
  # own: before, a FIFO HEAD blocked the read forever and a HEAD symlinked
  # to /dev/zero spun forever, and a regression would hang the suite.
  OUTER_TO=$(command -v timeout || command -v gtimeout)
  gtrender() {  # gtrender <cwd> -> as grender, killed after 10 s
    printf '{"session_id":"git-0001","cwd":"%s"}\n' "$1" > "$T/git.json"
    prepare minimal "$T/git.json"; rm -f "$T/git-calls"
    ( cd "$WORK" && run_env AGENTLINE_WIDTH=120 PATH="$HSHIM:$PATH_F" AGENTLINE_PROBE_TTL=0 AGENTLINE_LAYOUT=git \
        "$OUTER_TO" 10 "$TEST_BASH" "$ROOT/agentline.sh" < "$T/git.json" > "$T/out" 2> "$T/err" )
    rc=$?; normalize "$T/out" "$T/got"
  }
  if [ -n "$OUTER_TO" ] && command -v mkfifo >/dev/null 2>&1; then
    mkdir -p "$G/fifo/.git" "$G/zero/.git" "$G/fifogit"
    mkfifo "$G/fifo/.git/HEAD" "$G/fifogit/.git"
    ln -s /dev/zero "$G/zero/.git/HEAD"
    for c in fifo zero fifogit; do
      gtrender "$G/$c"
      check "git [$c HEAD]: render finishes (rc $rc)" [ "$rc" = 0 ]
      check "git [$c HEAD]: no branch" [ ! -s "$T/got" ]
      check "git [$c HEAD]: no git call (got $(git_calls))" [ "$(git_calls)" = 0 ]
    done
  else
    skip "git: no timeout/gtimeout or mkfifo for the FIFO HEAD tests"
  fi
  # A symlinked HEAD (core.preferSymlinkRefs) is resolved by git: read as a
  # file it held the branch's hash, and showed no branch at all.
  gx init -q "$G/symhead"
  gx -C "$G/symhead" -c user.name=t -c user.email=t@t commit -q --allow-empty -m x
  gx -C "$G/symhead" branch -m sym-branch
  rm -f "$G/symhead/.git/HEAD"; ln -s refs/heads/sym-branch "$G/symhead/.git/HEAD"
  grender "$G/symhead"
  check "git [symlinked HEAD]: branch shown" grep -qF 'sym-branch' "$T/got"
  check "git [symlinked HEAD]: asks git" grep -q 'branch --show-current' "$T/git-calls"
  # The walk follows the physical path. A symlink to a repo subdirectory
  # used to find no .git, and a symlink inside one repo into another found
  # the outer repo's branch.
  ln -s "$G/repo/sub/deep" "$G/to-deep"
  mkdir -p "$G/symhead/inner"; ln -s "$G/symhead/inner" "$G/repo/sub/to-other"
  grender "$G/to-deep"
  check "git [symlink into a repo]: branch shown" grep -qxF '🌿 octo/repo@feat/x' "$T/got"
  grender "$G/repo/sub/to-other"
  check "git [symlink into another repo]: that repo's branch" grep -qxF '🌿 sym-branch' "$T/got"
  # A HEAD that is not in git's canonical spelling is git's to read: without
  # the space after "ref:" it showed no branch, and trailing spaces stayed
  # in the name. git accepts the first and trims the second.
  gx init -q "$G/nosp"; printf 'ref:refs/heads/nosp\n' > "$G/nosp/.git/HEAD"
  grender "$G/nosp"
  check "git [ref: without space]: branch shown via git" grep -qxF '🌿 nosp' "$T/got"
  gx init -q "$G/trail"; printf 'ref: refs/heads/trail  \n' > "$G/trail/.git/HEAD"
  grender "$G/trail"
  check "git [trailing spaces]: trimmed branch" grep -qxF '🌿 trail' "$T/got"
  check "git [trailing spaces]: asks git" grep -q 'branch --show-current' "$T/git-calls"
  # An uppercase or short "hash" is no detached HEAD git wrote: ask git.
  mkdir -p "$G/badhash/.git"; printf 'ABCDEF\n' > "$G/badhash/.git/HEAD"
  grender "$G/badhash"
  check "git [not a hash]: asks git" grep -q 'branch --show-current' "$T/git-calls"
  # A 2 MB HEAD is not shown whole: past the cap, git is asked instead.
  mkdir -p "$G/huge/.git"
  { printf 'ref: refs/heads/'; printf '%02000000d' 0; echo; } > "$G/huge/.git/HEAD"
  grender "$G/huge"
  check "git [2 MB HEAD]: asks git" grep -q 'branch --show-current' "$T/git-calls"
  check "git [2 MB HEAD]: not displayed (got $(wc -c < "$T/got") bytes)" [ "$(wc -c < "$T/got")" -lt 2000 ]
  # An unreadable .git gitfile: no "Permission denied" on stderr.
  mkdir -p "$G/unr"; printf 'gitdir: ../repo/.git\n' > "$G/unr/.git"; chmod 000 "$G/unr/.git"
  if [ -r "$G/unr/.git" ]; then
    skip "git: running as root, an unreadable gitfile cannot be made"
  else
    grender "$G/unr"
    check "git [unreadable gitfile]: exit 0 (got $rc)" [ "$rc" = 0 ]
    check "git [unreadable gitfile]: stderr empty" [ ! -s "$T/err" ]
  fi
  chmod 600 "$G/unr/.git"
else
  skip "git: git not installed"
fi

# ===========================================================================
# 3d. Opt-in /usage fetch: claim file, detached refresh
# ===========================================================================
# No network beyond loopback: fake credentials plus a fake /usage server on
# 127.0.0.1, reached through AGENTLINE_USAGE_URL (honoured for loopback only).
# The fetch runs as `python3 -I`, which ignores PYTHONPATH, so the former
# sitecustomize seam is closed; the server is the seam now. It logs every
# request that carries the fake token to $T/fetches and answers after
# ?delay=<s> seconds with a canned reply.
cat > "$T/fakeusage.py" <<'EOF'
import http.server, json, os, socketserver, sys, time, urllib.parse
log, portfile = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(log + '.all', 'a') as f:
            f.write('GET %s auth=%s\n' % (self.path, self.headers.get('Authorization') is not None))
        if self.headers.get('Authorization') == 'Bearer fake-token':
            with open(log, 'a') as f:
                f.write('fetch\n')
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        time.sleep(float(q.get('delay', ['0'])[0]))
        body = json.dumps({'limits': [{'kind': 'weekly_scoped',
            'scope': {'model': {'display_name': 'Fable'}}, 'percent': 63}]}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    # Also the https proxy of the loopback-only test: a CONNECT is the real
    # endpoint being asked for, and is logged and refused.
    def do_CONNECT(self):
        with open(log + '.connect', 'a') as f:
            f.write(self.path + '\n')
        self.send_error(502)
    def log_message(self, *a):
        pass
class S(http.server.ThreadingHTTPServer):
    # HTTPServer.server_bind calls socket.getfqdn(), a reverse DNS lookup
    # that stalls for seconds on macOS runners; the port file came too late.
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = '127.0.0.1', self.server_address[1]
srv = S(('127.0.0.1', 0), H)
with open(portfile + '.tmp', 'w') as f:
    f.write(str(srv.server_address[1]))
os.rename(portfile + '.tmp', portfile)
srv.serve_forever()
EOF
# Started from a subshell, so it is not a job of this shell: the registry
# tests below use a bare `wait`, which would otherwise wait on it forever.
USRV=$( python3 "$T/fakeusage.py" "$T/fetches" "$T/usage-port" > "$T/fakeusage.err" 2>&1 < /dev/null & echo $! )
trap 'kill "$USRV" 2>/dev/null; rm -rf "$T"' EXIT
# The server skips HTTPServer's reverse DNS lookup of its own address, which
# on macOS runners outlasted the old 5 s wait, and the wait is generous now
# too (a cold python start on a CI runner can take seconds). Should the
# server never come up,
# UURL points at a dead loopback port rather than at nothing: an empty port
# fails the loopback check, and the fetch would then go to the real endpoint.
n=300; while [ "$n" -gt 0 ] && [ ! -s "$T/usage-port" ]; do sleep 0.1; n=$((n - 1)); done
uport=$(cat "$T/usage-port" 2>/dev/null)
case "$uport" in ''|*[!0-9]*) uport=9 ;; esac
UURL="http://127.0.0.1:$uport/usage"
# The harness asks the server itself, so a failure below says whether the
# server or the fetch is at fault. udiag prints what CI needs to tell.
uprobe() {
  python3 -I -c 'import sys, urllib.request as u
try:
    print(u.build_opener(u.ProxyHandler({})).open(sys.argv[1], timeout=5).read().decode()[:80])
except Exception as e:
    print("probe failed: %r" % e)' "$UURL"
}
udiag() {
  echo "    usage diag: UURL=$UURL server pid=$USRV alive=$(kill -0 "$USRV" 2>/dev/null && echo yes || echo no)"
  echo "    usage diag: probe: $(uprobe)"
  echo "    usage diag: server stderr: $(head -c 600 "$T/fakeusage.err" 2>/dev/null)"
  echo "    usage diag: requests seen: $(tr '\n' ' ' < "$T/fetches.all" 2>/dev/null)"
  echo "    usage diag: cache=[$(cat "${UCACHE-}" 2>/dev/null)] claim=$([ -e "${UCLAIM-}" ] && echo present || echo none)"
}
ucheck() {  # check, plus the usage diagnostics on failure
  local name="$1"; shift
  if "$@"; then pass; else fail "$name"; udiag; fi
}
case "$(uprobe)" in
  *weekly_scoped*) pass ;;
  *) fail "usage: fake /usage server answers"; udiag ;;
esac
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
urender() {  # urender [delay] [VAR=val...]
  local d="${1:-0}"; [ $# -gt 0 ] && shift
  # The real clock: the cache ages (mtime) and claims here are wall time.
  render "$p" 120 AGENTLINE_NOW= AGENTLINE_USAGE_API=1 AGENTLINE_USAGE_TTL=300 AGENTLINE_USAGE_URL="$UURL?delay=$d" ${1+"$@"}
}

# Expired cache, no claim: the previous figure is shown while a detached
# fetch runs; the render does not wait for it, and it lands afterwards.
prepare minimal "$p"; rm -f "$UCLAIM" "$T/fetches"
printf 37 > "$UCACHE"; age_file "$UCACHE" 310
urender 2
ucheck "usage:stale figure shown during the refresh" grep -q 'F:37%' "$T/out"
ucheck "usage:render did not wait for the fetch" cache_is 37
ucheck "usage:claim recorded in its own file" [ -f "$UCLAIM" ]
ucheck "usage:detached fetch lands after the render" wait_for 8 cache_is 63
ucheck "usage:claim dropped after the fetch" wait_for 2 [ ! -e "$UCLAIM" ]
prepare minimal "$p"
urender
ucheck "usage:fresh result rendered" grep -q 'F:63%' "$T/out"

# The URL override is honoured for loopback only: the request carries the
# OAuth token. Both proxies point at the fake server, so an honoured
# non-loopback override would arrive there as a plain GET with the token,
# and a refused one leaves the real endpoint, which arrives as a CONNECT.
prepare minimal "$p"; rm -f "$UCLAIM" "$T/fetches" "$T/fetches.connect"
printf 37 > "$UCACHE"; age_file "$UCACHE" 310
render "$p" 120 AGENTLINE_NOW= AGENTLINE_USAGE_API=1 AGENTLINE_USAGE_URL="http://usage.example/usage" \
  http_proxy="${UURL%/usage}" https_proxy="${UURL%/usage}"
ucheck "usage:non-loopback override refused" wait_for 8 grep -qs '^api.anthropic.com:443$' "$T/fetches.connect"
ucheck "usage:token not sent to a non-loopback override" [ ! -e "$T/fetches" ]
wait_for 5 [ ! -e "$UCLAIM" ]
# The loopback override is plain http and goes direct, never through a proxy
# (one would see the token in the clear): a dead proxy does not stop it.
prepare minimal "$p"; rm -f "$UCLAIM" "$T/fetches"
printf 37 > "$UCACHE"; age_file "$UCACHE" 310
urender 0 http_proxy=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9
ucheck "usage:loopback override bypasses http_proxy" wait_for 8 cache_is 63
wait_for 5 [ ! -e "$UCLAIM" ]

# A live claim (another session is fetching) serves the old value and
# starts no second fetch.
prepare minimal "$p"
printf 41 > "$UCACHE"; age_file "$UCACHE" 310
date +%s > "$UCLAIM"
urender
ucheck "usage:live claim serves the old value" grep -q 'F:41%' "$T/out"
sleep 1
ucheck "usage:live claim starts no second fetch" cache_is 41
# An abandoned claim (render killed before it could fetch) ages out.
echo $(( $(date +%s) - 60 )) > "$UCLAIM"
prepare minimal "$p"
urender
ucheck "usage:abandoned claim is retaken" wait_for 8 cache_is 63

# A result that cannot be written keeps its claim, so the renders after it
# do not each fetch again (8 fetches in 8 renders before the fix). The cache
# path is a non-empty directory, so renaming the result onto it fails the
# way a full disk does — EISDIR here, ENOSPC there, both an OSError.
prepare minimal "$p"; rm -f "$UCLAIM" "$UCACHE" "$T/fetches"
mkdir "$UCACHE"; : > "$UCACHE/x"
for i in 1 2 3 4 5; do
  prepare minimal "$p"
  urender
  [ "$i" = 1 ] && wait_for 5 [ -s "$T/fetches" ]
done
sleep 1
n_fetch=$(cat "$T/fetches" 2>/dev/null | wc -l | tr -d ' ')
ucheck "usage: failed cache write, one fetch not $n_fetch" [ "$n_fetch" = 1 ]
ucheck "usage:failed cache write keeps the claim" [ -f "$UCLAIM" ]
ucheck "usage:failed cache write leaves no temp file" sh -c "! ls '$UCACHE'.[0-9]* >/dev/null 2>&1"
rm -rf "$UCACHE"
# A claim that cannot be written starts no fetch at all.
rm -f "$UCLAIM" "$T/fetches"; mkdir "$UCLAIM"
prepare minimal "$p"
urender
sleep 1
ucheck "usage:unwritable claim starts no fetch" [ ! -e "$T/fetches" ]
ucheck "usage:unwritable claim, stderr quiet" [ ! -s "$T/err" ]
rmdir "$UCLAIM"

# Past TTL + 60 s grace an unconfirmed figure is hidden.
prepare minimal "$p"
printf 55 > "$UCACHE"; age_file "$UCACHE" 420
date +%s > "$UCLAIM"
urender
ucheck "usage:figure past the grace is hidden" sh -c "! grep -q 'F:' '$T/out'"

# Claude Code cancels an in-flight render; killing the render's whole
# process group must not abort the fetch (it runs in its own session).
if command -v setsid >/dev/null 2>&1; then
  prepare minimal "$p"; rm -f "$UCLAIM"
  printf 37 > "$UCACHE"; age_file "$UCACHE" 310
  ( cd "$WORK" && exec setsid env -i PATH="$PATH_F" HOME="$HOME_F" TMPDIR="$TMP_F" AGENTLINE_TMP="$SIDE" \
      TZ=UTC LC_ALL=C AGENTLINE_PROBE_TTL=3600 AGENTLINE_WIDTH=120 AGENTLINE_USAGE_API=1 \
      AGENTLINE_USAGE_URL="$UURL?delay=2" "$TEST_BASH" "$ROOT/agentline.sh" \
      < "$p" > /dev/null 2>&1 ) &
  rpid=$!
  wait "$rpid"
  kill -TERM -- "-$rpid" 2>/dev/null
  ucheck "usage:fetch survives a kill of the render's process group" wait_for 8 cache_is 63
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
# The real clock: the hook stamped the row with the wall time.
render "$PAY/minimal.json" 120 AGENTLINE_NOW= CLAUDE_AGENTS_FILE="$T/custom-agents.txt"
check "reader honours CLAUDE_AGENTS_FILE" grep -q 'relocated' "$T/out"

# --- Subagent lifecycle (hook_event_name dispatch) ---------------------------
# PreToolUse queues the dispatch's description, SubagentStart binds it to the
# agent id, SubagentStop removes that agent alone and leaves a ✓ row, Stop
# clears what the session still owns. The old hook read any payload without
# tool_name as the Stop, so a SubagentStop would have wiped every sibling.
AF="$SIDE/claude_agents.txt"
hook() { printf '%s' "$1" | hook_env "$TEST_BASH" "$ROOT/hooks/agent-tracker-hook.sh"; }
rows() { sed 's/^[0-9]* //' "$AF" 2>/dev/null; }
row_is() { rows | grep -qxF -- "$1"; }
rm -f "$SIDE"/claude_*
hook_env "$TEST_BASH" "$AGENT" add "external run"
hook '{"hook_event_name":"PreToolUse","tool_name":"Agent","session_id":"s2","tool_input":{"description":"explore repo","subagent_type":"Explore"}}'
check "lifecycle: dispatch row appears at once" row_is "explore repo"
hook '{"hook_event_name":"PreToolUse","tool_name":"Agent","session_id":"s2","tool_input":{"description":"review diff"}}'
hook '{"hook_event_name":"SubagentStart","session_id":"s2","agent_id":"abcdef123","agent_type":"Explore"}'
check "lifecycle: start re-labels the oldest dispatch" row_is "explore repo #abcdef"
check "lifecycle: bare dispatch row replaced" sh -c "! sed 's/^[0-9]* //' '$AF' | grep -qx 'explore repo'"
hook '{"hook_event_name":"SubagentStart","session_id":"s2","agent_id":"zzz999x","agent_type":"general-purpose"}'
check "lifecycle: second start takes the second label" row_is "review diff #zzz999"
hook '{"hook_event_name":"SubagentStart","session_id":"s2","agent_id":"nolabel1","agent_type":"fork"}'
check "lifecycle: start with nothing queued uses agent_type" row_is "fork #nolabe"
cp "$AF" "$T/af.before"
hook '{"hook_event_name":"SubagentStart","session_id":"s2","agent_id":"internal1","agent_type":""}'
check "lifecycle: internal agent (empty type) ignored" cmp -s "$AF" "$T/af.before"
hook '{"hook_event_name":"SubagentStop","session_id":"s2","agent_id":"abcdef123","agent_type":"Explore","last_assistant_message":"done"}'
check "lifecycle: stop removes that agent" sh -c "! grep -q 'explore repo #abcdef' '$AF'"
check "lifecycle: stop leaves a done row" row_is "✓explore repo"
check "lifecycle: stop keeps the sibling" row_is "review diff #zzz999"
check "lifecycle: stop keeps the external agent" row_is "external run"
cp "$AF" "$T/af.before"
hook '{"hook_event_name":"SubagentStop","session_id":"s2","agent_id":"abcdef123","agent_type":"Explore","stop_hook_active":true}'
check "lifecycle: repeated stop is a no-op" cmp -s "$AF" "$T/af.before"
hook '{"hook_event_name":"SubagentStop","session_id":"s2","agent_id":"stranger","agent_type":""}'
check "lifecycle: unknown agent_id ignored" cmp -s "$AF" "$T/af.before"
hook '{"hook_event_name":"Stop","session_id":"s2","stop_hook_active":false}'
check "lifecycle: Stop clears the running ones" sh -c "! grep -q -e 'review diff' -e 'fork #' '$AF'"
check "lifecycle: Stop keeps the done flash" row_is "✓explore repo"
check "lifecycle: Stop keeps the external agent" row_is "external run"
check "lifecycle: Stop drops the session sidecars" sh -c "! ls '$AF'.pending.s2* '$AF'.ids.s2* '$AF'.owned.s2 >/dev/null 2>&1"
check "lifecycle: no temp file left" sh -c "! ls '$AF'.[0-9]* '$AF'.*.s2.[0-9]* >/dev/null 2>&1"
# Garbage and other events do nothing.
cp "$AF" "$T/af.before"
hook 'not json'
hook '[1,2]'
hook '{"hook_event_name":"PostToolUse","tool_name":"Bash","session_id":"s2"}'
hook '{"hook_event_name":"PreToolUse","tool_name":"Bash","session_id":"s2","tool_input":{"description":"x"}}'
check "lifecycle: garbage and other events ignored" cmp -s "$AF" "$T/af.before"

# Parallel starts never pop the same queued label: 6 dispatches, 6 starts at
# once, 6 distinct labels bound.
rm -f "$SIDE"/claude_*
for i in 1 2 3 4 5 6; do
  hook "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Agent\",\"session_id\":\"par\",\"tool_input\":{\"description\":\"job $i\"}}"
done
for i in 1 2 3 4 5 6; do
  hook "{\"hook_event_name\":\"SubagentStart\",\"session_id\":\"par\",\"agent_id\":\"agent${i}xx\",\"agent_type\":\"general-purpose\"}" &
done
wait
check "lifecycle: parallel starts bind 6 distinct labels" \
  [ "$(rows | grep -E '^job [1-6] #agent' | sed 's/ #.*//' | sort -u | wc -l | tr -d ' ')" = 6 ]
check "lifecycle: parallel starts leave no bare dispatch row" sh -c "! sed 's/^[0-9]* //' '$AF' | grep -qx 'job [1-6]'"

# The registry keeps finished rows for a minute and evicts them before any
# running one when the cap is reached.
rm -f "$AF"
now=$(date +%s)
printf '%s\n' "$now live one" "$now ✓finished" "$now live two" "$(( now - 90 )) ✓long gone" > "$AF"
hook_env AGENTLINE_AGENT_CAP=3 "$TEST_BASH" "$AGENT" add "live three"
check "cap: a done row goes first" sh -c "! grep -q '✓finished' '$AF'"
check "cap: every running row kept" [ "$(grep -c 'live ' "$AF")" = 3 ]
check "registry: a done row past a minute is pruned" sh -c "! grep -q 'long gone' '$AF'"

# The reader: the first AGENTLINE_AGENT_SHOW running rows, oldest first, then
# "+N"; done rows only while younger than 10 s. (prepare wipes the side
# files, so the registry is written after it.)
agents_rows() {
  now=$TNOW
  for i in 1 2 3 4 5 6; do printf '%s run%s\n' "$now" "$i"; done > "$AF"
  printf '%s\n' "$now ✓fresh" "$(( now - 30 )) ✓stale" "$(( now - 400 )) old" >> "$AF"
}
prepare minimal "$PAY/minimal.json"; agents_rows
render "$PAY/minimal.json" 200; normalize "$T/out" "$T/got"
check "reader: first four, then +2, then the done flash" grep -qF '🤖 run1 · run2 · run3 · run4 · +2 · ✓fresh' "$T/got"
check "reader: stale done row hidden" sh -c "! grep -q stale '$T/got'"
check "reader: aged row hidden" sh -c "! grep -q ' old' '$T/got'"
check "reader: done flash is green" grep -q "${ESC}\[1;32m✓fresh" "$T/out"
prepare minimal "$PAY/minimal.json"; agents_rows
render "$PAY/minimal.json" 200 AGENTLINE_AGENT_SHOW=0
normalize "$T/out" "$T/got"
check "reader: AGENTLINE_AGENT_SHOW=0 counts only" grep -qF '🤖 +6 · ✓fresh' "$T/got"
prepare minimal "$PAY/minimal.json"; agents_rows
render "$PAY/minimal.json" 200 AGENTLINE_AGENT_SHOW=junk
normalize "$T/out" "$T/got"
check "reader: bad AGENTLINE_AGENT_SHOW falls back to 4" grep -qF '· +2 ·' "$T/got"
rm -f "$AF"

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

# --- --doctor -----------------------------------------------------------------
# A report instead of the status line: phases timed, every segment shown or
# hidden with its source, cache and hook state. It must bypass both caches —
# a warm render cache would otherwise be replayed as the "report" — and must
# not block when stdin is a terminal.
doctor() {  # doctor <payload-file> [VAR=val...] -> $T/dout (ANSI stripped), $rc
  local p="$1"; shift
  ( cd "$WORK" && run_env ${1+"$@"} "$TEST_BASH" "$ROOT/agentline.sh" --doctor < "$p" > "$T/dout.raw" 2> "$T/derr" )
  rc=$?
  LC_ALL=C sed "s/${ESC}\[[0-9;]*m//g" "$T/dout.raw" > "$T/dout"
}
dhas() { grep -qE -- "$1" "$T/dout"; }
printf '%s' '{"session_id":"doc-1","cwd":"'"$WORK"'","model":{"id":"claude-opus-5"},"version":"2.1.100","context_window":{"used_percentage":12}}' > "$T/doc.json"
prepare minimal "$PAY/minimal.json"
render "$T/doc.json" 120  # a normal render first: the caches are now warm
ls -l "$CACHE_DIR" > "$T/cache.before"
cp "$(cbase doc-1).render" "$T/render.before"
doctor "$T/doc.json"
check "doctor: exit 0 (got $rc)" [ "$rc" = 0 ]
check "doctor: stderr empty" [ ! -s "$T/derr" ]
check "doctor: a report, not the cached line" dhas '^agentline doctor$'
check "doctor: phases timed" dhas '^  parse +[0-9]+\.[0-9]$'
check "doctor: total timed" dhas '^  total +[0-9]+\.[0-9]$'
check "doctor: payload read from stdin" dhas '^  payload +stdin, [0-9]+ bytes$'
check "doctor: version reported" dhas '^  claude code +2\.1\.100$'
check "doctor: shown segment" dhas '^  model +shown +payload model\.id'
check "doctor: hidden segment says absent" dhas '^  cost +hidden +absent: cost\.total_cost_usd$'
check "doctor: prompt_cache version gate" dhas 'cache +hidden +absent: prompt_cache: needs Claude Code >= 2\.1\.251, this is 2\.1\.100'
# The probes ran live (the seeded probe cache is bypassed too), so only the
# row is asserted, not its value.
check "doctor: host probe values listed" dhas '^  cpu_usage( |$)'
check "doctor: cache dir trusted" dhas 'trusted: caching on'
check "doctor: no settings.json reported" dhas '\(no .*/\.claude/settings\.json\)'
check "doctor: render included" dhas '^Opus 5 │ 📊 12%'
check "doctor: caches not written" cmp -s "$(cbase doc-1).render" "$T/render.before"
ls -l "$CACHE_DIR" > "$T/cache.after"
check "doctor: cache dir listing unchanged" cmp -s "$T/cache.before" "$T/cache.after"
# A newer Claude Code with no prompt_cache object is no version problem.
printf '%s' '{"session_id":"doc-2","model":{"id":"claude-opus-5"},"version":"2.1.300"}' > "$T/doc2.json"
doctor "$T/doc2.json"
check "doctor: prompt_cache absent on a new version" dhas 'absent: prompt_cache: absent \(no API response yet'
doctor "$T/doc2.json" AGENTLINE_LAYOUT="model,cost"
check "doctor: segment not in AGENTLINE_LAYOUT" dhas '^  clock +shown +always \[not in AGENTLINE_LAYOUT\]$'
# Hooks: which events agentline's hooks are wired for.
mkdir -p "$HOME_F/.claude"
printf '%s\n' '{"statusLine":{"type":"command","command":"/x/agentline.sh","refreshInterval":1},' \
  '"hooks":{"PreToolUse":[{"matcher":"Agent|Task","hooks":[{"type":"command","command":"/x/agent-tracker-hook.sh"}]}],' \
  '"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/agent-tracker-hook.sh"}]}]}}' > "$HOME_F/.claude/settings.json"
doctor "$T/doc2.json"
check "doctor: statusLine reported" dhas '^  statusLine +/x/agentline\.sh$'
check "doctor: hook events wired / missing" dhas 'agent-tracker-hook\.sh PreToolUse yes, SubagentStart NO, SubagentStop NO, Stop yes'
check "doctor: wordcount hook missing" dhas 'wordcount-hook\.sh +PostToolUse NO, Stop NO'
rm -f "$HOME_F/.claude/settings.json"
# An untrusted cache dir (a symlink) is reported as such.
mkdir -p "$T/dtmp/real"; ln -s "$T/dtmp/real" "$T/dtmp/agentline-${EUID:-0}"
doctor "$T/doc2.json" TMPDIR="$T/dtmp"
check "doctor: untrusted cache dir reported" dhas 'FAILED the owner/symlink check'
check "doctor: nothing written into it" [ -z "$(ls -A "$T/dtmp/real")" ]
rm -rf "$T/dtmp"
# stdin a terminal: the built-in sample, never a hang.
python3 - "$T/dpty" "$WORK" "$PATH_F" "$HOME_F" "$TMP_F" "$SIDE" "$TEST_BASH" "$ROOT/agentline.sh" <<'PYEOF'
import os, pty, select, sys
out_path, cwd, path, home, tmp, side, bash, script = sys.argv[1:9]
pid, fd = pty.fork()
if pid == 0:
    os.chdir(cwd)
    os.execve(bash, [bash, script, '--doctor'], {'PATH': path, 'HOME': home, 'TMPDIR': tmp,
              'AGENTLINE_TMP': side, 'TZ': 'UTC', 'LC_ALL': 'C'})
out, hung = b'', False
while True:
    r, _, _ = select.select([fd], [], [], 30)
    if not r:
        hung = True
        os.kill(pid, 9)
        break
    try:
        chunk = os.read(fd, 65536)
    except OSError:
        chunk = b''
    if not chunk:
        break
    out += chunk
_, st = os.waitpid(pid, 0)
status = 'timeout' if hung else 'exit %d' % (os.WEXITSTATUS(st) if os.WIFEXITED(st) else -1)
open(out_path, 'wb').write(out + ('\n%s\n' % status).encode())
PYEOF
check "doctor on a tty: no hang, exit 0" grep -qx 'exit 0' "$T/dpty"
check "doctor on a tty: built-in sample" grep -q 'built-in sample' "$T/dpty"
# The normal path ignores anything but --doctor, and --doctor never leaks
# into a normal render.
render "$T/doc2.json" 120
check "no --doctor: the status line" sh -c "! grep -q 'agentline doctor' '$T/out'"

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
jcheck "hooks: SubagentStart tracker x1" "$S" "($COUNT)('SubagentStart', 'agent-tracker-hook.sh')" 1
jcheck "hooks: SubagentStop tracker x1" "$S" "($COUNT)('SubagentStop', 'agent-tracker-hook.sh')" 1
jcheck "hooks: subagent events unmatched" "$S" "[g['matcher'] for e in ('SubagentStart', 'SubagentStop') for g in d['hooks'][e]]" '["", ""]'
jcheck "hooks: user's own Stop hook kept" "$S" "($COUNT)('Stop', 'my-own-hook.sh')" 1
# An install wired by an earlier release (PreToolUse + Stop only) gains the
# two subagent events on the next --with-hooks, and nothing is doubled.
python3 - "$S" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
for e in ('SubagentStart', 'SubagentStop'):
    d['hooks'].pop(e, None)
json.dump(d, open(sys.argv[1], 'w'), indent=2)
PYEOF
install_run --with-hooks
check "hooks upgrade: exit 0" [ "$irc" = 0 ]
check "hooks upgrade: says wired" grep -q 'Hooks wired' "$T/iout"
jcheck "hooks upgrade: SubagentStart added" "$S" "($COUNT)('SubagentStart', 'agent-tracker-hook.sh')" 1
jcheck "hooks upgrade: SubagentStop added" "$S" "($COUNT)('SubagentStop', 'agent-tracker-hook.sh')" 1
jcheck "hooks upgrade: PreToolUse not doubled" "$S" "($COUNT)('PreToolUse', 'agent-tracker-hook.sh')" 1
jcheck "hooks upgrade: Stop not doubled" "$S" "($COUNT)('Stop', 'agent-tracker-hook.sh')" 1

# --theme / --glyphs land in the env block, beside what the user had there.
install_run --theme light --glyphs=ascii
check "theme: exit 0" [ "$irc" = 0 ]
jcheck "theme: env written, user's kept" "$S" "d['env']" '{"AGENTLINE_TZ":"Europe/Istanbul","AGENTLINE_THEME":"light","AGENTLINE_GLYPHS":"ascii"}'
cp "$S" "$T/themed.json"
install_run --theme=light --glyphs ascii
check "theme twice: exit 0" [ "$irc" = 0 ]
check "theme twice: settings.json byte-identical" cmp -s "$S" "$T/themed.json"
check "theme twice: says already" grep -q 'AGENTLINE_THEME already light' "$T/iout"
install_run --theme mono
jcheck "theme: changed, glyphs kept" "$S" "[d['env']['AGENTLINE_THEME'], d['env']['AGENTLINE_GLYPHS']]" '["mono","ascii"]'
check "theme: says what it was" grep -q 'was: light' "$T/iout"
cp "$S" "$T/themed.json"
for bad in "--theme bogus" "--glyphs nerd" "--theme"; do
  # shellcheck disable=SC2086
  install_run $bad
  check "theme: '$bad' is exit 2 (got $irc)" [ "$irc" = 2 ]
  check "theme: '$bad' changes nothing" cmp -s "$S" "$T/themed.json"
done
# COLORFGBG is only a hint: printed, never written.
INST_ENV="COLORFGBG=0;15"
install_run
INST_ENV=""
check "theme: COLORFGBG light background hinted" grep -q 'reports a light background' "$T/iout"
check "theme: the hint writes nothing" cmp -s "$S" "$T/themed.json"
inst_home envbad
printf '{"env": ["not", "an", "object"]}\n' > "$S"; cp "$S" "$T/orig.json"
install_run --theme light
check "theme: env not an object is refused" [ "$irc" = 1 ]
check "theme: refused before any write" cmp -s "$S" "$T/orig.json"
check "theme: refused before the copy" [ ! -e "$H/.claude/agentline/agentline.sh" ]

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
# The installer runs `python3 -I`, which ignores PYTHONPATH, so a python3
# shim ahead on PATH drops the -I for this one run (the test seam lives here,
# not in install.sh).
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
mkdir -p "$T/pyhook/bin"
cat > "$T/pyhook/bin/python3" <<EOF
#!/bin/sh
for a do shift; [ "\$a" = -I ] || set -- "\$@" "\$a"; done
exec "$REAL_PY" "\$@"
EOF
chmod +x "$T/pyhook/bin/python3"
ino_before=$(ls -i "$S" | awk '{print $1}')
INST_ENV="PATH=$T/pyhook/bin:$PATH_F PYTHONPATH=$T/pyhook"
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
# 6. Isolated interpreters: the project directory is not on sys.path
# ===========================================================================
# Everything here runs in Claude Code's project directory, and `python3 -c` /
# `python3 -` put the cwd first on sys.path: a repository holding a json.py
# had it executed on every render. Each script starts python3 -I. The
# directory below shadows every module the programs import, and a package
# for urllib; any one of them imported from it leaves a marker.
EVIL="$T/evil"; PWNED="$T/pwned"; mkdir -p "$EVIL/urllib"
for m in json re shlex math subprocess signal unicodedata errno stat shutil tempfile \
         fcntl time glob http urllib/__init__ urllib/request; do
  printf 'open(%s, "a").write("%s\\n")\n' "'$PWNED'" "$m" > "$EVIL/$m.py"
done
# PYTHONPATH and PYTHONSTARTUP are the other doors -I closes.
printf 'open(%s, "a").write("startup\\n")\n' "'$PWNED'" > "$T/evil-startup.py"
EVIL_ENV="PYTHONPATH=$EVIL PYTHONSTARTUP=$T/evil-startup.py"
erun() {  # erun <stdin-file> <command...> — in $EVIL, hermetic env plus EVIL_ENV
  local in="$1"; shift
  # shellcheck disable=SC2086
  ( cd "$EVIL" && run_env $EVIL_ENV "$@" < "$in" > "$T/out" 2> "$T/err" )
  rc=$?
}
pwned() { if [ -e "$PWNED" ]; then fail "$1: ran $(tr '\n' ' ' < "$PWNED")"; rm -f "$PWNED"; else pass; fi; }
rm -f "$PWNED"
# Full render with every python path live: probes (MCP), the CLI e-mail
# lookup (no payload address, no cached one), the detached /usage fetch.
printf '{"session_id":"evil-0001","cwd":"%s"}\n' "$EVIL" > "$T/evil.json"
rm -f "$CACHE_DIR"/render_* "$CACHE_DIR"/email.* "$CACHE_DIR"/usage.*
erun "$T/evil.json" AGENTLINE_PROBE_TTL=0 AGENTLINE_USAGE_API=1 AGENTLINE_USAGE_URL="$UURL" \
  AGENTLINE_WIDTH=120 "$TEST_BASH" "$ROOT/agentline.sh"
check "isolated: full render exit 0 (got $rc)" [ "$rc" = 0 ]
check "isolated: full render printed" [ -s "$T/out" ]
wait_for 5 sh -c "! ls '$CACHE_DIR'/usage.*.claim >/dev/null 2>&1"
pwned "isolated: full render"
# The python e-mail mask (a non-ASCII address).
printf '{"session_id":"evil-0002","cwd":"%s","account":{"email":"şule@örnek.com"}}\n' "$EVIL" > "$T/evil.json"
erun "$T/evil.json" AGENTLINE_WIDTH=120 "$TEST_BASH" "$ROOT/agentline.sh"
check "isolated: e-mail mask still masks" grep -qF 'ş**e@ö***k.com' "$T/out"
pwned "isolated: e-mail mask"
# The hooks, and the registry helper on its own.
printf '{"transcript_path":"%s"}' "$T/transcript.jsonl" > "$T/evil.json"
erun "$T/evil.json" AGENTLINE_TMP="$SIDE" "$TEST_BASH" "$ROOT/hooks/wordcount-hook.sh"
check "isolated: wordcount hook still counts" [ "$(cat "$SIDE/claude_wordcount.txt" 2>/dev/null)" = "3 2" ]
pwned "isolated: wordcount hook"
echo '{"tool_name":"Agent","session_id":"s9","tool_input":{"description":"evil sub"}}' > "$T/evil.json"
erun "$T/evil.json" AGENTLINE_TMP="$SIDE" "$TEST_BASH" "$ROOT/hooks/agent-tracker-hook.sh"
check "isolated: tracker still registers" grep -q 'evil sub' "$SIDE/claude_agents.txt"
pwned "isolated: tracker hook"
erun /dev/null AGENTLINE_TMP="$SIDE" "$TEST_BASH" "$ROOT/hooks/agentline-agent.sh" remove "evil sub"
pwned "isolated: agentline-agent.sh"
# The installer.
inst_home evil
erun /dev/null HOME="$H" "$TEST_BASH" "$ROOT/install.sh"
check "isolated: install exit 0 (got $rc)" [ "$rc" = 0 ]
pwned "isolated: install.sh"
# And no interpreter start in the shipped scripts goes without -I.
if grep -nE '(^|[^-A-Za-z_])python3( |$)' "$ROOT/agentline.sh" "$ROOT/install.sh" "$ROOT"/hooks/*.sh \
     | grep -vE ':[0-9]+: *#|command -v python3|python3 -I( |$)|python3 not found' > "$T/nonisolated"; then
  fail "isolated: python3 without -I: $(cat "$T/nonisolated")"
else
  pass
fi

# ===========================================================================
# 7. Locales: the suite renders under LC_ALL=C, users mostly do not
# ===========================================================================
# A UTF-8 locale as the host names it (C.utf8 on Linux, en_US.UTF-8 on macOS).
UTF8_LC=$(locale -a 2>/dev/null | LC_ALL=C grep -iE '^(c|en_us)\.utf-?8$' | head -n 1)
if [ -z "$UTF8_LC" ]; then
  skip "locale: no UTF-8 locale installed"
else
  # The full render is the same in a UTF-8 locale (refilled: its reset
  # countdowns are relative to the fill time).
  fill "$FIX/payloads/full.json" "$PAY/full.json"
  prepare full "$PAY/full.json"; render "$PAY/full.json" 120; normalize "$T/out" "$T/want"
  prepare full "$PAY/full.json"; render "$PAY/full.json" 120 LC_ALL="$UTF8_LC"; normalize "$T/out" "$T/got"
  check "locale: $UTF8_LC render = C render" cmp -s "$T/got" "$T/want"
  check "locale: $UTF8_LC stderr empty" [ ! -s "$T/err" ]
  # An invalid byte on the marker line itself, read in a UTF-8 locale: the
  # grep that finds the marker must still find it (GNU grep suppresses an
  # output line holding an encoding error, BSD grep may reject the input).
  printf '{"type":"user","message":{"content":"caf\351"}}\n{"type":"attachment","attachment":{"type":"ultra_effort_enter"},"note":"caf\351"}\n' > "$T/badbyte.jsonl"
  printf '{"session_id":"lc-0001","cwd":"%s","transcript_path":"%s","model":{"id":"claude-opus-5"},"effort":{"level":"xhigh"}}\n' \
    "$WORK" "$T/badbyte.jsonl" > "$T/lc.json"
  prepare minimal "$T/lc.json"; render "$T/lc.json" 120 LC_ALL="$UTF8_LC"; normalize "$T/out" "$T/got"
  check "locale: an invalid transcript byte still finds ultracode" grep -q 'ultracode' "$T/got"
fi
# The session name is shortened by characters, not bytes: under LC_ALL=C
# bash cut the 27th byte, halfway through a two-byte "ç".
sn=$(printf '%040d' 0 | sed 's/0/ç/g')
printf '{"session_id":"lc-0002","cwd":"%s","session_name":"%s","model":{"id":"claude-opus-5"}}\n' "$WORK" "$sn" > "$T/lc.json"
prepare minimal "$T/lc.json"; render "$T/lc.json" 120
check "locale: long session name cut at 27 characters" grep -qF "🏷️ $(printf '%027d' 0 | sed 's/0/ç/g')..." "$T/out"
check "locale: long session name output is valid UTF-8" \
  python3 -c 'import sys; open(sys.argv[1], "rb").read().decode("utf-8")' "$T/out"

# ===========================================================================
echo "agentline tests (bash $TEST_BASH_MAJOR): $n_pass passed, $n_fail failed, $n_skip skipped"
[ "$n_fail" = 0 ]
