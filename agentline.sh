#!/bin/bash
# agentline — a four-line, zero-dependency status bar for Claude Code.
# https://github.com/OFCode-dev/agentline
#
# Claude Code pipes its statusLine JSON payload to stdin; this script renders
# up to four lines: session stats, environment, Claude layer, system layer.
# Every segment degrades gracefully — anything it cannot measure disappears
# instead of erroring.
#
# Owner-only for everything this script creates. The caches below already
# live in a 0700 directory, so this is defence in depth: a cache file copied
# out, or a directory that loses its mode, still does not expose session JSON
# or account data. `umask` is a builtin, so the fast path stays fork-free.
umask 077

# === Doctor ===
# `agentline.sh --doctor` prints a diagnostic report instead of the status
# line: how long each phase of a render took, which segments rendered and why
# the others did not, the effective width and layout, the cache directory's
# state, and whether the hooks are wired. "Why is my status line slow" and
# "why is X missing" are otherwise answered by reading 2000 lines of bash.
#
# It is decided before stdin is read: run from a terminal, `input=$(cat)`
# would wait forever for a payload nobody sends. From a terminal it renders a
# built-in sample payload (the host layer is real, the payload layer mostly
# empty); `... | agentline.sh --doctor` diagnoses a saved or live payload.
# Doctor mode bypasses both caches, reading and writing: a warm cache would
# report every probe at ~0 ms, and a sample render must never be replayed as
# the real one. On the normal path this costs one `case` and, further down, a
# handful of `[ -n ]` tests: builtins, no fork.
_AL_DOCTOR=""
_dt_sample=""
case "${1:-}" in --doctor) _AL_DOCTOR=1 ;; esac
if [ -n "$_AL_DOCTOR" ] && [ -t 0 ]; then
  _dt_sample=1
  input='{"session_id":"agentline-doctor","model":{"id":"claude-sonnet-5","display_name":"Sonnet 5"}}'
else
  input=$(cat)
fi
# Phase timer, doctor mode only: microseconds from $EPOCHREALTIME on bash >=
# 5 (its decimal point follows the locale, so either separator is dropped;
# it always has six decimals), else from python3, which is already a
# dependency — BSD date has no %N, so `date +%s%N` is no fallback on macOS.
_dt_log=""
_dt_mark() {  # _dt_mark <phase> — record the time a phase ended
  local t
  if [ "${BASH_VERSINFO[0]:-0}" -ge 5 ]; then t="${EPOCHREALTIME//[.,]/}"
  else t=$(python3 -I -c 'import time; print(int(time.time() * 1e6))' 2>/dev/null)
  fi
  _dt_log="${_dt_log}$1 ${t}"$'\n'
}
[ -n "$_AL_DOCTOR" ] && _dt_mark start

# === Live clock fast path ===
# Claude Code re-invokes this script every `statusLine.refreshInterval`
# seconds (install.sh sets 1), which is what makes the HH:MM:SS clock on
# line 2 tick in real time instead of freezing between conversation events.
# A full render costs ~20 subprocesses — far too much to pay once a second —
# so the finished output is cached with the clock replaced by a placeholder.
# While the payload (and the terminal width and layout settings, see the
# cache key below) is byte-identical and the cache is younger than
# $AGENTLINE_CACHE_TTL, a tick only substitutes the current time and prints:
# zero subprocesses on bash >= 5.0. Any real event (token counts, cost, cwd,
# model) changes the payload and invalidates the cache on the spot, so no
# segment is ever shown stale across a state change.
#
# Each placeholder carries a C0 byte (\x02). Every displayed string has its
# control characters stripped (see "Display sanitization"), so no session
# name, branch or label can contain one — and a session named
# "@@AGENTLINE_CLOCK@@" can no longer have the clock, or the animated effort
# gradients, substituted into it. \x02 rather than \x01: bash uses \x01 (and
# \x7f) as internal quoting markers, and old versions mishandle them in
# pattern substitution.
_AL_TOK=$'\x02'
CLOCK_TOKEN="@@${_AL_TOK}AGENTLINE_CLOCK@@"
ANIM_MAX_TOKEN="@@${_AL_TOK}AGENTLINE_ANIM_MAX@@"
ANIM_ULTRA_TOKEN="@@${_AL_TOK}AGENTLINE_ANIM_ULTRA@@"
# The prompt-cache countdown carries its own expiry: "${PCEXP_TOKEN}<epoch>@@".
# A fixed token would need the epoch stored beside the cached body, i.e. a
# cache format change and another read per tick; inside the token it is one
# parameter expansion away.
PCEXP_TOKEN="@@${_AL_TOK}AGENTLINE_PCEXP:"
CACHE_TTL="${AGENTLINE_CACHE_TTL:-5}"
# ASCII unit and record separators: segment builders emit name<US>text<RS>
# records for the layout pass (see "Layout"). Like the \x02 above, no cleaned
# display string can contain them.
_US=$'\x1f'; _RS=$'\x1e'
# And the group separator: between the rows of the agent list, one segment
# the layout pass prints as a column or one row per entry (see "Layout").
_GS=$'\x1d'

# The UTF-8 encoding of a C1 control (U+0080-U+009F) is the byte C2 followed
# by 80-9F. Spelled as byte variables once here so the display sanitizer
# (see "Display sanitization") can strip it in any locale, with a plain
# pattern that needs no $'...' inside ${...} (extquote) on bash 3.2.
_C1_LEAD=$'\xc2'; _C1_LO=$'\x80'; _C1_HI=$'\x9f'

# Display timezone: system-local by default. Set $AGENTLINE_TZ (for example
# "Europe/Istanbul") to pin the clock to home time on remote UTC servers.
# Resolved before the fast path so cached ticks honour it too.
[ -n "$AGENTLINE_TZ" ] && export TZ="$AGENTLINE_TZ"

# bash >= 5.0 has $EPOCHSECONDS and printf's %(fmt)T, so a tick needs no
# `date` at all. Older bash (macOS ships 3.2) pays two forks instead — still
# an order of magnitude cheaper than a full render.
if [ "${BASH_VERSINFO[0]:-0}" -ge 5 ]; then _fast_time=1; else _fast_time=0; fi
_tick_now() {  # -> $_now_epoch, $_now_clock, without forking where possible
  if [ "$_fast_time" = 1 ]; then
    _now_epoch=$EPOCHSECONDS
    printf -v _now_clock '%(%H:%M:%S)T' -1
  else
    _now_epoch=$(date +%s)
    _now_clock=$(date +%H:%M:%S)
  fi
  # Test seam: AGENTLINE_NOW, when it is all digits, is the epoch every
  # countdown, pace arrow and cache age is worked out from. tests/run.sh pins
  # it to the moment its fixtures were stamped, so a render a minute later
  # on a slow host still reads "↻2h0m ⇡12%", not "↻1h59m ⇡11%". The printed
  # clock stays live (the tests mask it). Anything else is ignored; a case,
  # no fork.
  case "${AGENTLINE_NOW-}" in ''|*[!0-9]*|?????????????*) ;; *) _now_epoch=$(( 10#$AGENTLINE_NOW )) ;; esac
}

# The cache is keyed by session so concurrent Claude Code windows never trade
# renders. The id is pulled straight out of the raw JSON with parameter
# expansion — the python parse below has not run yet, and forking for it here
# would defeat the point.
_sid=default
case "$input" in
  *'"session_id"'*)
    _sid="${input#*\"session_id\"}"
    _sid="${_sid#*\"}"
    _sid="${_sid%%\"*}"
    case "$_sid" in ''|*[!a-zA-Z0-9_-]*) _sid=default ;; esac
    ;;
esac
# The cache lives in a per-user, owner-only directory, never directly in the
# shared temp dir: a predictable path under a world-writable /tmp lets a
# co-tenant pre-plant a symlink and redirect the writes below onto any file
# this user can write, and it would also leave the payload (the full session
# JSON) world-readable under the usual 022 umask. The directory is created
# 0700 atomically on the slow path and re-verified here on every render — a
# real directory, not a symlink, owned by us. Anything else disables caching
# rather than writing somewhere untrusted. $EUID is a bash builtin, so this
# costs no fork.
# `mkdir -m 700` sets the mode atomically at creation — a mkdir/chmod pair
# would leave a window where the directory is world-writable. It runs only
# when the directory is missing (once per boot), so the steady-state fast path
# stays fork-free. Not -p: the parent temp dir already exists, and refusing to
# create intermediate levels keeps the write path shallow and predictable.
CACHE_DIR="${TMPDIR:-/tmp}/agentline-${EUID:-0}"
CACHE_BASE=""
[ -d "$CACHE_DIR" ] || [ -n "$_AL_DOCTOR" ] || mkdir -m 700 "$CACHE_DIR" 2>/dev/null
# CACHE_FORMAT is part of every cache name, and is bumped whenever what the
# caches hold changes meaning, so a render right after an upgrade never
# replays a body written by the old release. Format 2: placeholders carry a
# C0 byte (an old body would print "@@AGENTLINE_CLOCK@@" literally for up to
# $AGENTLINE_CACHE_TTL), the probe cache stores its cwd %q-quoted, and
# svc_panel labels are cleaned before they are cached (an old probe cache
# replayed uncleaned ones for up to $AGENTLINE_PROBE_TTL). Old-format files
# are simply never read again and fall to the daily prune.
CACHE_FORMAT=2
if [ -d "$CACHE_DIR" ] && [ ! -L "$CACHE_DIR" ] && [ -O "$CACHE_DIR" ]; then
  CACHE_BASE="${CACHE_DIR}/render_${_sid}.v${CACHE_FORMAT}"
fi
# Doctor mode reports whether the directory passed, then renders without it
# (see "Doctor"): with CACHE_BASE empty nothing is read from or written to
# any cache, the probe, compaction, e-mail and usage caches included.
_dt_cache_ok=0
[ -n "$CACHE_BASE" ] && _dt_cache_ok=1
[ -n "$_AL_DOCTOR" ] && CACHE_BASE=""

# === Animated effort gradients ===
# The /effort picker animates "max" and ultracode live; a statusline can't
# run a render loop, but it is already re-invoked every refreshInterval
# second for the clock above, so the same zero-fork tick can rotate a fixed
# color wheel instead of freezing on one frame. Each wheel is a closed loop
# (the violet one folds back on itself) so the ripple has no visible seam.
# Defined this early, ahead of the fast-path exit below, so a cache hit can
# advance the animation without paying for a full render.
#
# A terminal has no position between one cell and the next, so a step of less
# than a whole letter cannot read as movement: it only re-tints every letter
# where it stands, which the eye takes for flicker. A tick therefore advances
# the pattern exactly one letter — the wheel stride and the letter stride are
# the same number — so each letter inherits the colour its neighbour just had
# and the eye reads the whole pattern as travelling.
#
# That also buys the palette its saturation back. A chase only permutes a
# fixed set of colours, so the bar's total brightness is identical frame to
# frame and the wheel can be as chromatic as the gamut allows; it was the
# re-tinting, not the vividness, that strobed. Generated in OkLCh at
# lightness 0.70, taking the most chroma each hue can hold there.
#
# 37 entries, not 36: three letters a third of the wheel apart come back in
# three ticks one step short of where they started, so the hues precess a
# full turn every ~111 s instead of cycling the same three colours forever.
_RAINBOW_WHEEL=(
  "255 87 153" "255 92 131" "255 97 108" "255 100 83" "255 103 48" "248 113 0"
  "232 127 0" "220 137 0" "208 145 0" "196 151 0" "184 158 0" "170 164 0"
  "153 170 0" "129 177 0" "89 185 0" "0 191 61" "0 188 111" "0 186 136"
  "0 184 154" "0 183 168" "0 181 181" "0 179 193" "0 177 205" "0 175 218"
  "0 172 234" "0 167 255" "75 161 255" "104 155 255" "126 149 255" "144 142 255"
  "162 134 255" "181 124 255" "202 109 255" "228 79 255" "255 23 244" "255 63 207"
  "255 78 178"
)
# The shipped endpoints, rgb(62,22,118) -> rgb(140,80,240), interpolated in
# OkLab and folded back on itself: 17 out, 15 home, a seamless 32-step loop.
_VIOLET_WHEEL=(
  "62 22 118" "67 26 125" "71 29 132" "76 33 140" "80 36 147" "85 40 154"
  "90 43 162" "95 47 169" "100 50 177" "105 54 185" "109 58 192" "114 61 200"
  "119 65 208" "125 69 216" "130 72 224" "135 76 232" "140 80 240" "135 76 232"
  "130 72 224" "125 69 216" "119 65 208" "114 61 200" "109 58 192" "105 54 185"
  "100 50 177" "95 47 169" "90 43 162" "85 40 154" "80 36 147" "76 33 140"
  "71 29 132" "67 26 125"
)
# === Theme ===
# AGENTLINE_THEME=dark (default) | light | mono. Most colours here are ANSI-16
# roles (green, yellow, red, dim, ...) that the terminal's own theme already
# maps to something readable on its background, so a theme leaves them
# alone. Re-picking them as fixed truecolour would override a well-tuned
# terminal palette and make contrast worse, not better. What a theme does
# swap is the handful of colours that are fixed values: the Fable gradient
# endpoints, GOLD/ORANGE (256-colour 220/208) and the max rainbow wheel.
# Against a white background those read at about 1.4-3:1.
#   light  the same hues darkened to about 4-7:1 on white (see "Colors" and
#          _RAINBOW_WHEEL below). The ultracode pill is left as it is: it is
#          white text on a violet ground, readable on either background.
#   mono   no colour at all: every SGR sequence is stripped from the finished
#          render, and the animated effort words are printed plain, because an
#          animation is nothing but colour. NO_COLOR (https://no-color.org),
#          when set and not empty, selects it too.
# Resolved here, ahead of the fast path, because a cached tick animates the
# wheels. There is no runtime background detection: that needs an OSC 11
# round trip on /dev/tty, which can hang and which a status line has no
# terminal for. `install.sh --theme light` writes the choice into
# settings.json instead.
case "${AGENTLINE_THEME-}" in
  light|mono) _AL_THEME="$AGENTLINE_THEME" ;;
  *)          _AL_THEME=dark ;;
esac
[ -n "${NO_COLOR-}" ] && _AL_THEME=mono
# The same 37 hues as the dark wheel, at OkLCh lightness 0.50 instead of 0.70
# with the most chroma each hue holds there: 5.6-7.1:1 on white, where the
# dark wheel manages 2.5-3.1:1.
if [ "$_AL_THEME" = light ]; then
  _RAINBOW_WHEEL=(
    "181 0 95" "184 0 74" "186 0 48" "188 0 1" "170 54 0" "158 69 0"
    "148 79 0" "139 85 0" "132 90 0" "124 94 0" "116 99 0" "107 103 0"
    "96 107 0" "80 111 0" "54 117 0" "0 121 35" "0 119 68" "0 118 85"
    "0 116 97" "0 115 105" "0 114 114" "0 113 122" "0 112 130" "0 110 138"
    "0 108 149" "0 105 163" "0 99 183" "0 78 234" "63 48 255" "93 16 255"
    "114 0 240" "131 0 220" "144 0 199" "155 0 178" "164 0 157" "171 0 136"
    "176 0 115"
  )
fi

# -> $_anim_out. $1 is the word to color, $2 the wheel array's name (bash 3.2
# has no namerefs, so the wheel is selected once here rather than passed in).
_anim_frame() {
  local word="$1" n step i idx rgb frame=""
  case "$2" in
    # Three letters a third of the wheel apart; the set chases round in 3 s.
    rainbow) n=${#_RAINBOW_WHEEL[@]}; step=12 ;;
    # Nine letters across half the fold — the dark-to-light sweep the static
    # gradient had — with the crest travelling a letter a tick, home in 16 s.
    violet)  n=${#_VIOLET_WHEEL[@]};  step=2  ;;
  esac
  for (( i=0; i<${#word}; i++ )); do
    # Letter i now shows what letter i+1 showed a tick ago: one letter of
    # travel per tick, because the epoch and the letter index share a stride.
    idx=$(( ((_now_epoch + i) * step) % n ))
    case "$2" in
      rainbow)
        rgb="${_RAINBOW_WHEEL[$idx]}"
        frame="${frame}\033[1;38;2;${rgb// /;}m${word:$i:1}" ;;
      # Bold white on the violet, as the picker draws it: violet as foreground
      # alone sits too close to a dark terminal ground to read as lit.
      violet)
        rgb="${_VIOLET_WHEEL[$idx]}"
        frame="${frame}\033[1;38;2;255;255;255;48;2;${rgb// /;}m${word:$i:1}" ;;
    esac
  done
  _anim_out="${frame}\033[0m"
}

# -> $_pc_out: $1 with the prompt-cache countdown filled in as "1m05s" /
# "45s" from $_now_epoch. Pure parameter expansion and arithmetic, like the
# clock, so a cached tick counts the cache down without a fork. Past the
# expiry it holds at 0s: Claude Code re-runs the status line itself when a
# warm cache reaches expires_at, and that new payload says cold.
#
# A row with the agent column beside it (see "Layout") also holds
# "${PCEXP_TOKEN}<epoch>:<cells>@@" in the padding before the column: it
# becomes the spaces the countdown's widest form (<cells>) has over what it
# prints now, so the column stays where it is while the countdown shortens.
_pc_fill() {
  local s="$1" e rem sec w pad=""
  _pc_out="$s"
  e="${s#*"$PCEXP_TOKEN"}"; e="${e%%@@*}"
  case "$e" in ''|*[!0-9]*) return ;; esac
  rem=$(( e - _now_epoch )); [ "$rem" -lt 0 ] && rem=0
  sec=$(( rem % 60 )); [ "$sec" -lt 10 ] && sec="0$sec"
  if [ "$rem" -ge 60 ]; then rem="$(( rem / 60 ))m${sec}s"; else rem="${rem}s"; fi
  _pc_out="${s//"${PCEXP_TOKEN}${e}@@"/$rem}"
  case "$_pc_out" in
    *"${PCEXP_TOKEN}${e}:"*)
      w="${_pc_out#*"${PCEXP_TOKEN}${e}:"}"; w="${w%%@@*}"
      case "$w" in [0-9]|[0-9][0-9]) while [ "${#pad}" -lt $(( 10#$w - ${#rem} )) ]; do pad="$pad "; done ;; esac
      _pc_out="${_pc_out//"${PCEXP_TOKEN}${e}:${w}@@"/$pad}" ;;
  esac
}

_tick_now
# The cache key is the payload plus every setting the layout reads from the
# environment. COLUMNS is the one that changes under a running session — a
# terminal resize — and it is not in the payload, so without it a resize kept
# serving the old width's render until the TTL ran out. `+set:` tells an
# empty AGENTLINE_DROP (drop nothing) from an unset one (the default list).
# The theme, glyph set, colour overrides, the opt-in >200k tag and
# AGENTLINE_AGENTS (which rows the agent list shows) change the
# render too, and so
# does a multiplexer: under tmux, screen or zellij the OSC-8 links are left
# out (see "Hyperlinks"), and without their presence in the key a render
# made outside one was replayed, links and all, inside one for up to
# $AGENTLINE_CACHE_TTL. Only presence counts, as it does there.
_cache_key="${input}${_US}${COLUMNS-}|${AGENTLINE_WIDTH-}|${AGENTLINE_LAYOUT-}|${AGENTLINE_DROP+set:}${AGENTLINE_DROP-}|${AGENTLINE_LINKS-}|${_AL_THEME}|${AGENTLINE_GLYPHS-}|${AGENTLINE_COLOR_FABLE_FROM-}|${AGENTLINE_COLOR_FABLE_TO-}|${AGENTLINE_COLOR_GOLD-}|${AGENTLINE_COLOR_ORANGE-}|${TMUX:+t}${STY:+s}${ZELLIJ:+z}|${AGENTLINE_TAG_200K-}|${AGENTLINE_AGENTS-}"
# The cache files are read with the `read` builtin, not `$(<file)`: bash 5
# serves `$(<file)` in-process, but bash 3.2 (macOS) forks a subshell for
# each, which cost this path two forks a second.
#
# They are read a line at a time, not with `read -d ''`: with any delimiter
# but newline, bash 3.2 reads one byte per syscall (some 1,700 reads a tick
# for a typical payload), while a newline-delimited read of a regular file is
# buffered on every bash. Both files are written without a trailing newline,
# so a whole single-line file makes `read` hit end of file and return 1; a
# return of 0 means a newline came first and there is more, which is treated
# as no match. The payload key holds a newline only for a pretty-printed
# payload, and for that one the byte-wise verbatim read is kept. The render
# body never holds one: a render with a real newline is not cached (below).
_prev_payload=""
_cached_body=""
if [ -n "$CACHE_BASE" ] && [ -f "${CACHE_BASE}.payload" ]; then
  case "$_cache_key" in
    *$'\n'*) IFS= read -r -d '' _prev_payload < "${CACHE_BASE}.payload" ;;
    *) IFS= read -r _prev_payload < "${CACHE_BASE}.payload" && _prev_payload="" ;;
  esac
fi
if [ -n "$_prev_payload" ] && [ "$_prev_payload" = "$_cache_key" ] && [ -f "${CACHE_BASE}.render" ]; then
  _cached_ts=""
  { IFS= read -r _cached_ts; IFS= read -r _cached_body && _cached_body=""; } < "${CACHE_BASE}.render"
  case "$_cached_ts" in
    ''|*[!0-9]*) ;;
    *)
      if [ -n "$_cached_body" ] && [ $(( _now_epoch - _cached_ts )) -lt "$CACHE_TTL" ]; then
        _tick_out="${_cached_body//$CLOCK_TOKEN/$_now_clock}"
        case "$_tick_out" in
          *"$ANIM_MAX_TOKEN"*)
            _anim_frame max rainbow
            _tick_out="${_tick_out//$ANIM_MAX_TOKEN/$_anim_out}" ;;
        esac
        case "$_tick_out" in
          *"$ANIM_ULTRA_TOKEN"*)
            _anim_frame ultracode violet
            _tick_out="${_tick_out//$ANIM_ULTRA_TOKEN/$_anim_out}" ;;
        esac
        case "$_tick_out" in
          *"$PCEXP_TOKEN"*) _pc_fill "$_tick_out"; _tick_out="$_pc_out" ;;
        esac
        printf "%b" "$_tick_out"
        exit 0
      fi
      ;;
  esac
fi

# === JSON Parsing ===
# One python3 pass extracts every payload field as shell-quoted assignments;
# the former per-field helper spawned 20+ interpreters per render, and this is
# the hottest path in the script. shlex.quote makes the eval safe for any
# payload value (quotes, spaces, newlines).
#
# The program is read into a variable at top level and run with `python3 -c`,
# never written as a heredoc inside `$(...)`: bash 3.2 (the macOS /bin/bash)
# parses a heredoc body nested in a command substitution as shell text, so a
# single apostrophe in a python comment opened a quote and every full render
# died with a syntax error. Every python program in this file follows the
# same pattern; tests/run.sh guards it. `IFS=` keeps the indentation, and
# read's non-zero status at end of input is expected.
#
# Every interpreter in this file (and in install.sh and the hooks) starts as
# `python3 -I`. The status line runs in Claude Code's project directory, and
# `python3 -c` / `python3 -` put the current directory first on sys.path: a
# repository holding a json.py, re.py or shlex.py had that file executed on
# every render, before a single payload field was read. Isolated mode leaves
# the cwd and the script directory off sys.path and ignores the PYTHON*
# variables (PYTHONPATH, PYTHONSTARTUP), which a project could also set.
IFS= read -r -d '' _AL_PARSER <<'PYEOF'
import json, math, os, re, shlex, sys
# The decode is its own step so a broken payload is reported, not just
# survived: before, any failure became {} and the model and context segments
# vanished with nothing on screen to say why. payload_err drives a dim
# "⚠ payload" marker on line 1; everything that does not come from the
# payload (host, git, clock) still renders. Empty stdin is not an error --
# that is a manual run (`bash agentline.sh </dev/null`), not a broken
# upstream -- and neither is valid JSON that simply lacks fields.
raw = os.environ.get('PAYLOAD', '')
payload_err = ''
# Python 3.11+ refuses to convert an integer literal of more than 4300 digits
# (ValueError), and json.loads raised it for the whole payload: one absurd
# token count cost every field and showed "⚠ payload". A literal that long is
# decoded as infinity instead, which num() then drops like any other number
# that does not fit.
def _int(s):
    return int(s) if len(s) < 4000 else float('inf')
try:
    d = json.loads(raw, parse_int=_int) if raw.strip() else {}
except Exception:
    d, payload_err = {}, '1'
if not isinstance(d, dict):
    d, payload_err = {}, '1'

def g(*keys):
    v = d
    for k in keys:
        v = v.get(k) if isinstance(v, dict) else None
    return '' if v is None else v

# Every numeric field reaches awk and `printf %.0f`, which print "0" and
# complain on stderr for anything else. A number, or a string that is one,
# passes through unchanged (str(83) and str(83.5) as before); anything else
# -- a bool, an object, garbage -- becomes '' and the segment disappears.
# Digits are ASCII only: `\d` also matched "٣٠" (Arabic-Indic 30), which
# printf rejects ("invalid number", then a red "⚠️ 0%"). A value that does
# not fit a double is garbage too: math.isfinite() raised OverflowError on
# an int past ~1e308, which lost the whole parse. str() of an int with more
# than 4300 digits raises ValueError on Python 3.11+. And a finite but absurd
# value (1e300 ms, a 300-digit token count) printed as a 300-digit segment
# or wrapped round in bash arithmetic, so anything from 1e15 up is dropped:
# no percentage, cost, duration or token count comes near that.
NUM_MAX = 1e15
def num(v):
    if isinstance(v, bool) or not isinstance(v, (int, float, str)):
        return ''
    try:
        s = str(v)
        if isinstance(v, str) and not re.fullmatch(r'-?[0-9]+(\.[0-9]+)?', s):
            return ''
        f = float(s)
        return s if math.isfinite(f) and abs(f) < NUM_MAX else ''
    except (OverflowError, ValueError):
        return ''

# The final output goes through `printf %b`, which expands backslash escapes,
# and the terminal interprets any raw control byte. A session name, model name
# or version carrying "\033]0;..." or a literal ESC could therefore retitle
# the window, move the cursor or forge the line. Every displayed payload
# string is cleaned here: C0 controls, DEL, C1 controls (U+0080-U+009F, which
# some terminals honour as CSI/OSC) and the backslash itself. Host-derived
# strings get the same treatment in bash, after the probes.
#
# Lone surrogates (U+D800-U+DFFF) go too. JSON may spell one ("\ud800"), and
# a raw invalid byte in the payload arrives as one (\udc80-\udcff, the
# surrogateescape decoding of the environment). The first made the encode
# of the output raise, which lost the whole parse. The second was written
# back as the raw byte: "\udc9b" became a bare 0x9B, the 8-bit CSI.
def clean(v):
    return re.sub(r'[\x00-\x1f\x7f-\x9f\\\ud800-\udfff]', '', str(v))

# A display string that must be a JSON string: an object or a number where
# a name belongs is garbage, and str() of it would be shown as "{...}".
def text(*keys):
    v = g(*keys)
    return clean(v) if isinstance(v, str) else ''

# The model field has been both an object {id, display_name} and a bare id
# string across Claude Code versions (other status lines crashed on the flip,
# CCometixLine#118); accept either. Model ids carry variant and build
# suffixes: "claude-opus-5[1m]" (1M context window) and dated builds like
# "claude-haiku-4-5-20251001". The match is therefore left-anchored only --
# anchoring the tail made the [1m] variant fall through and print the raw id.
# Falls back to the payload's display_name, then to the raw id.
mobj = d.get('model')
if isinstance(mobj, str):
    mid, disp = mobj, ''
elif isinstance(mobj, dict):
    mid, disp = str(mobj.get('id') or ''), str(mobj.get('display_name') or '')
else:
    mid, disp = '', ''
m = re.match(r'claude-([a-z]+)-(\d+)(?:-(\d+))?', mid)
if m:
    ver = m.group(2) if m.group(3) is None else f'{m.group(2)}.{m.group(3)}'
    model = f'{m.group(1).capitalize()} {ver}'
else:
    model = disp or mid

# Whether the opt-in ">200k" tag may show (AGENTLINE_TAG_200K=1, see the
# context segment), decided here rather than by comparing the window size in
# bash: `[ -gt ]` fails with "integer expression expected" on a size past 64
# bits ("9999999999999999999999999"), and python compares any size.
# exceeds_200k_tokens is Claude Code's own fixed-threshold flag (input +
# output of the last response > 200k, whatever the window); only a strict
# JSON true counts, and only on a window larger than 200k — on a 200k window
# it just means "about 100%" again.
#
# The size is compared here without the 1e15 cap of num(): an absurd window is
# still larger than 200k.
def over(v, limit):
    if isinstance(v, bool) or not isinstance(v, (int, float, str)):
        return False
    if isinstance(v, str) and not re.fullmatch(r'-?[0-9]+(\.[0-9]+)?', v):
        return False
    try:
        return float(v) > limit
    except OverflowError:
        return v > 0  # an int too large for a double
    except ValueError:
        return False
size = g('context_window', 'context_window_size')
warn_200k = '1' if d.get('exceeds_200k_tokens') is True and over(size, 200000) else ''

# Prompt cache (Claude Code 2.1.251+; last_miss_cause 2.1.260+). The object
# is absent until the first API response, and caching_observed false means
# the provider reports no caching at all -- both hide the segment. There is
# no fallback for older versions: transcript mtime + 5 min guesses the TTL
# (it can be 1h) and moves on tool results, not just on API responses.
#
# expires_at is reduced to epoch seconds here, whatever its spelling -- epoch
# seconds, epoch milliseconds or an ISO 8601 time with a zone -- so bash only
# ever sees digits. A zoneless ISO time is ambiguous and dropped.
def epoch(v):
    if isinstance(v, bool):
        return ''
    if isinstance(v, str):
        s = v.strip()
        if not re.fullmatch(r'[0-9]+(\.[0-9]+)?', s):
            # Imported here: this parse runs on every full render, and only
            # an ISO spelling needs datetime.
            from datetime import datetime
            try:
                t = datetime.fromisoformat(s.replace('Z', '+00:00'))
            except ValueError:
                return ''
            return str(int(t.timestamp())) if t.tzinfo else ''
        v = s
    if not isinstance(v, (int, float, str)):
        return ''
    try:
        f = float(v)
    except (OverflowError, ValueError):
        return ''
    if not math.isfinite(f) or f <= 0:
        return ''
    if f > 1e11:
        f /= 1000  # milliseconds: 1e11 s is the year 5138
    return str(int(f)) if f < 1e12 else ''

# The miss cause is an object, {"causes": [...], "tools_added", ...}, with
# snake_case names; the first cause is shown, shortened the way ailine does
# it: ttl_expired_5m -> ttl, tools_changed -> tools, model_changed -> model.
# An unknown name passes through (cleaned, capped), a null cause is none.
CAUSES = {'system_prompt_changed': 'prompt', 'likely_server_side': 'server'}
def cause(v):
    cs = v.get('causes') if isinstance(v, dict) else None
    if not isinstance(cs, list) or not cs or not isinstance(cs[0], str):
        return ''
    c = cs[0]
    if c.startswith('ttl_expired'):
        return 'ttl'
    c = CAUSES.get(c, c[:-8] if c.endswith('_changed') and len(c) > 8 else c)
    return clean(c)[:16]

pc = d.get('prompt_cache')
pc_state = pc_exp = pc_ttl = pc_hit = pc_recache = pc_cause = ''
if isinstance(pc, dict) and pc.get('caching_observed') is not False:
    # Only a strict JSON bool is a state; anything else hides the segment.
    w = pc.get('warm')
    pc_state = 'warm' if w is True else 'cold' if w is False else ''
    pc_exp = epoch(pc.get('expires_at'))
    pc_ttl = pc.get('ttl') if pc.get('ttl') in ('5m', '1h') else ''
    # hit_ratio is the session-wide ratio, 0-1; a value past 1 is taken as
    # a percentage already. Shown only with AGENTLINE_CACHE_VERBOSE=1.
    h = num(pc.get('hit_ratio'))
    if h != '' and float(h) >= 0:
        h = float(h)
        pc_hit = str(int(round(h * 100 if h <= 1 else min(h, 100))))
    # What going cold costs: the tokens the next turn re-writes to the cache.
    # The unit is chosen on the rounded value: 999,600 tokens is "1.0m", not
    # the "1000k" that deciding on the raw count printed. Lower-case m, as
    # the token counters on line 1 spell a million.
    r = num(pc.get('recache_tokens_if_cold'))
    if r != '' and float(r) > 0:
        r = float(r)
        pc_recache = (str(int(r)) if r < 1000 else f'{r / 1000:.0f}k'
                      if round(r / 1000) < 1000 else f'{r / 1e6:.1f}m')
    pc_cause = cause(pc.get('last_miss_cause'))

# Pull request (pr.*, mirroring the footer's PR badge; pr.kind "mr" for a
# GitLab merge request needs Claude Code 2.1.234+). The number must be a
# positive integer, the review state one of the four documented values (an
# unknown one shows the number alone), and the URL plain https -- it ends up
# inside an OSC-8 hyperlink, so anything else (javascript:, file:, a URL with
# a space or a quote) is no link at all.
#
# The raw value is judged, before clean(), against the same rules git_url
# follows: a host of letters, digits, dots and dashes (an optional port), a
# path from a spelled-out URL charset, and no user-info, query or fragment.
# Cleaning first let "…/1\x07\x1b]8;;https://evil" through as a link to
# "…/1]8;;https://evil" -- the controls went, the forged sequence stayed --
# and "https://user:TOKEN@host/…" or "?token=…" went into the link as is,
# where git_url strips them. A URL that fails is no link; the number stays.
pr = d.get('pr') if isinstance(d.get('pr'), dict) else {}
pr_number = num(pr.get('number'))
pr_number = pr_number if re.fullmatch(r'[1-9][0-9]{0,11}', pr_number) else ''
pr_url = pr.get('url') if isinstance(pr.get('url'), str) else ''
pr_url = clean(pr_url) if (len(pr_url) <= 2048 and re.fullmatch(
    r'https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~:/%+=-]*)?', pr_url)) else ''
pr_state = pr.get('review_state') if pr.get('review_state') in ('approved', 'pending', 'changes_requested', 'draft') else ''
pr_kind = 'mr' if pr.get('kind') == 'mr' else ''

# The session name is shortened here, by characters. bash used to do it
# with a substring expansion, which counts bytes under C/POSIX (common on
# servers) and cut a multibyte character in half at byte 27.
sname = clean(g('session_name'))

# The worktree segment and the breadcrumb show only a last path component,
# cut here by characters like the session name (bash would cut bytes). A
# 60-character branch-named worktree took most of line 2 at 80 columns.
def last(v, cap=24):
    v = v.rstrip('/').rsplit('/', 1)[-1]
    return v if len(v) <= cap else v[:cap - 3] + '...'

fields = {
    # cwd stays raw: it is a filesystem path (git, the probe-cache key, the
    # transcript lookup). Its displayed form, $folder, is built from this
    # cleaned copy: a raw invalid byte in the payload cwd comes back out of
    # surrogateescape as that byte (a bare 0x9B CSI), which _clean in bash
    # cannot tell from a UTF-8 continuation byte.
    'cwd': g('cwd'),
    'cwd_disp': clean(g('cwd')),
    'model_raw': mid,
    'model': clean(model),
    'used_pct': num(g('context_window', 'used_percentage')),
    # For the post-compaction estimate only (see "Compaction").
    'ctx_size': num(size),
    'warn_200k': warn_200k,
    'payload_err': payload_err,
    'five_hour': num(g('rate_limits', 'five_hour', 'used_percentage')),
    'seven_day': num(g('rate_limits', 'seven_day', 'used_percentage')),
    # Per-model weekly bucket. Claude Code forwards the whole rate_limits
    # object verbatim (`...(D.five_hour||D.seven_day)&&{rate_limits:D}`), but
    # it builds that object from four response-header buckets only (2.1.x:
    # five_hour, seven_day, seven_day_overage_included, overage). Its own label
    # map names `seven_day_overage_included` the "Fable 5 limit" and
    # `seven_day_opus` the "Opus limit" -- and `seven_day_opus` is not among
    # the forwarded buckets, so it is kept only as a fallback for other builds.
    # Accounts whose responses carry neither key can opt into the /usage
    # endpoint (AGENTLINE_USAGE_API=1, see the weekly segment below).
    'seven_day_top': (lambda a, b: a if a != '' else b)(
        num(g('rate_limits', 'seven_day_overage_included', 'used_percentage')),
        num(g('rate_limits', 'seven_day_opus', 'used_percentage'))),
    'five_hour_reset': g('rate_limits', 'five_hour', 'resets_at'),
    'seven_day_reset': g('rate_limits', 'seven_day', 'resets_at'),
    'effort_raw': clean(g('effort', 'level')),
    'cost': num(g('cost', 'total_cost_usd')),
    'duration_ms': num(g('cost', 'total_duration_ms')),
    'lines_added': num(g('cost', 'total_lines_added')),
    'lines_removed': num(g('cost', 'total_lines_removed')),
    'tokens_in': num(g('context_window', 'total_input_tokens')),
    'tokens_out': num(g('context_window', 'total_output_tokens')),
    'thinking': g('thinking', 'enabled'),
    'session_name': sname,
    'session_name_fmt': sname if len(sname) <= 30 else sname[:27] + '...',
    # session_id is also a path component (the transcript fallback), so it
    # stays raw; the resume command shows a cleaned copy.
    'session_id': g('session_id'),
    'fast': g('fast_mode'),
    'version': clean(g('version')),
    'payload_email': clean(g('account', 'email')),
    'payload_transcript': g('transcript_path'),
    'pc_state': pc_state,
    'pc_exp': pc_exp,
    'pc_ttl': pc_ttl,
    'pc_hit': pc_hit,
    'pc_recache': pc_recache,
    'pc_cause': pc_cause,
    'pr_number': pr_number,
    'pr_url': pr_url,
    'pr_state': pr_state,
    'pr_kind': pr_kind,
    # A linked worktree: workspace.git_worktree is set for any `git worktree
    # add` checkout (absent in the main clone), worktree.name only in Claude
    # Code's own worktree sessions, so the first is preferred.
    'wt_disp': last(text('workspace', 'git_worktree') or text('worktree', 'name')),
    # Where the session was launched; differs from cwd once it has cd'd
    # away. Only its last component is shown (the breadcrumb on line 2).
    'project_dir': text('workspace', 'project_dir'),
    'crumb': last(text('workspace', 'project_dir')),
}
# Encoded here, not by print(): stdout's encoding follows the locale, and any
# surrogate left in a raw field would make print() raise and take every field
# down with it. Displayed fields are clean() already. Of the raw ones, the two
# paths keep their exact bytes (surrogateescape) so a non-UTF-8 directory
# still resolves. Everything else, and a path that cannot round-trip, gets
# '?' for what cannot be encoded.
RAW_PATHS = ('cwd', 'payload_transcript')
def line(k, v):
    s = f'{k}={shlex.quote(str(v))}'
    if k in RAW_PATHS:
        try:
            return s.encode('utf-8', 'surrogateescape')
        except UnicodeEncodeError:
            pass
    return s.encode('utf-8', 'replace')
sys.stdout.buffer.write(b'\n'.join(line(k, v) for k, v in fields.items()))
PYEOF
eval "$(PAYLOAD="$input" python3 -I -c "$_AL_PARSER")"
[ -n "$_AL_DOCTOR" ] && _dt_mark parse
# Only a pwd fallback may seed the displayed path from the raw one (it is
# host data, cleaned with the other host strings via $folder). A payload cwd
# whose cleaned form is empty — nothing but control bytes, say "\x9b\x1b" —
# stays empty on screen: falling back to the raw value there put a bare 0x9B
# (the 8-bit CSI) straight onto line 2, and the folder segment just vanishes.
[ -z "$cwd" ] && { cwd="$PWD"; cwd_disp="$cwd"; }

# === Platform detection ===
# One source tree runs on macOS laptops and Linux servers. Resolve the
# platform once here; never probe per call site. $OSTYPE is bash's own
# ("linux-gnu", "darwin23"), so the two common cases cost no `uname` fork;
# anything else asks uname, whose answer the rest of the script compares to.
case "${OSTYPE-}" in
  linux*)  OS=Linux ;;
  darwin*) OS=Darwin ;;
  *)       OS="$(uname -s)" ;;
esac

# ($AGENTLINE_TZ is applied up in the fast path, before any clock is read.)

# Epoch -> formatted date. GNU date wants `-d @<ts>`, BSD date wants `-r <ts>`.
# Which one is asked on the first call, not at definition time: the probe was
# a `date` fork on every full render, and most renders need no fmt_epoch at
# all (bash >= 4.2 formats the dates it needs with printf %()T, see "Format
# Helpers"). A call inside $(...) cannot keep the answer, so there the probe
# rides along with the date it guards: two forks where one used to be paid
# by every render.
_date_flavour=""
fmt_epoch() {
  if [ -z "$_date_flavour" ]; then
    if date -r 0 >/dev/null 2>&1; then _date_flavour=bsd; else _date_flavour=gnu; fi
  fi
  if [ "$_date_flavour" = bsd ]; then
    date -r "$1" "+$2" 2>/dev/null     # BSD / macOS
  else
    date -d "@$1" "+$2" 2>/dev/null    # GNU / Linux
  fi
}

# Reverse a file: GNU has tac, BSD/macOS has tail -r.
if command -v tac >/dev/null 2>&1; then
  revcat() { tac "$1" 2>/dev/null; }
else
  revcat() { tail -r "$1" 2>/dev/null; }
fi

# Hang guard for probes that can block: a git on NFS or behind a held lock,
# a systemd that does not answer. `_run_to <secs> cmd...` kills the command
# after <secs>, and its segment simply stays empty. Linux has coreutils
# `timeout`; macOS only has it as `gtimeout` from Homebrew coreutils, and
# without either the command runs unguarded as before. `command -v` is a
# builtin, so resolving it costs nothing.
if command -v timeout >/dev/null 2>&1; then _TIMEOUT=timeout
elif command -v gtimeout >/dev/null 2>&1; then _TIMEOUT=gtimeout
else _TIMEOUT=""
fi
_run_to() {
  local secs="$1"; shift
  if [ -n "$_TIMEOUT" ]; then "$_TIMEOUT" "$secs" "$@"; else "$@"; fi
}

# Every sed, grep and tr in this file runs under LC_ALL=C (tests/run.sh
# lints it). Their input is often someone else's bytes — a remote URL, a
# transcript, a label — and under a UTF-8 locale BSD sed and tr stop at the
# first invalid sequence ("illegal byte sequence", empty output), and GNU
# grep treats such input as binary and holds back a matching line that holds
# one (older releases printed "Binary file matches" instead). The patterns
# are ASCII, so the C locale matches exactly what they mean. awk is left in the user's
# locale: no awk aborts on invalid bytes, and length()/substr() count
# characters there instead of bytes (the agent-label truncation).

# === Host probe cache ===
# The clock ticks once a second, but CPU, RAM, disk, ports, services, MCP and
# git do not change at that rate — and re-running `top -bn1`, `df`, `ss`,
# `crontab`, `who` and a `systemctl is-active` per unit once a second is most
# of a full render's cost, spent on numbers that barely move. These probes
# therefore get their own, longer TTL, kept deliberately separate from the
# render cache: the render cache is invalidated by any payload change, which
# happens constantly during a turn, whereas host readings stay perfectly valid
# across one. The cwd is part of the validity check, so changing directory
# re-probes git immediately instead of showing the previous repo's branch.
# `active_agents` is excluded on purpose — it is one awk over a small file, and
# the live subagent list is the thing worth watching in real time.
PROBE_TTL="${AGENTLINE_PROBE_TTL:-15}"
PROBE_VARS="active_mcps cpu_usage cron_count dev_ports disk_pct git_ab git_branch git_dirty git_repo git_url mem_used_gb ssh_count svc_panel"
#
# The file is line-oriented and its body is eval'd, so nothing may reach it
# that could add a line. The cwd comes from the payload and used to be stored
# raw: a cwd of "/tmp/x<newline>active_mcps=$(cmd)" wrote an extra line, and
# the next render in /tmp/x within the TTL matched the first half and eval'd
# the rest — running cmd. The cwd is now stored and compared `printf %q`
# quoted (always one line), like every value in the body, and the body is
# only eval'd when it is exactly one `name=` line per PROBE_VARS entry, in
# order — the shape this script writes and nothing else.
printf -v _cwd_q '%q' "$cwd"
_probes_fresh=0
if [ -n "$CACHE_BASE" ] && [ -f "${CACHE_BASE}.probes" ]; then
  _pc=""
  IFS= read -r -d '' _pc < "${CACHE_BASE}.probes"
  _pc_ts="${_pc%%$'\n'*}";   _pc_rest="${_pc#*$'\n'}"
  _pc_cwd="${_pc_rest%%$'\n'*}"; _pc_body="${_pc_rest#*$'\n'}"
  _pc_ok=1; _pc_left="$_pc_body"
  for _v in $PROBE_VARS; do
    case "$_pc_left" in "$_v="*) ;; *) _pc_ok=0; break ;; esac
    case "$_pc_left" in *$'\n'*) _pc_left="${_pc_left#*$'\n'}" ;; *) _pc_left="" ;; esac
  done
  [ -n "$_pc_left" ] && _pc_ok=0
  case "$_pc_ts" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$_pc_ok" = 1 ] && [ "$_pc_cwd" = "$_cwd_q" ] && [ $(( _now_epoch - _pc_ts )) -lt "$PROBE_TTL" ]; then
        eval "$_pc_body"
        _probes_fresh=1
      fi
      ;;
  esac
fi

# === System Info ===
if [ "$_probes_fresh" != 1 ]; then
# CPU: BSD top has no `-b`, and Linux top has no "CPU usage:" idle line.
cpu_usage=""
if [ "$OS" = "Darwin" ]; then
  cpu_line=$(top -l 1 -n 0 2>/dev/null | LC_ALL=C grep "CPU usage")
  if [ -n "$cpu_line" ]; then
    idle=$(echo "$cpu_line" | awk -F',' '{print $3}' | LC_ALL=C grep -oE '[0-9]+(\.[0-9]+)?')
    [ -n "$idle" ] && cpu_usage=$(awk -v idle="$idle" 'BEGIN {printf "%d%%", 100 - idle}')
  fi
else
  idle=$(top -bn1 2>/dev/null | awk -F',' '/^%?Cpu/ {for (i=1;i<=NF;i++) if ($i ~ /id/) {gsub(/[^0-9.]/,"",$i); print $i; exit}}')
  [ -n "$idle" ] && cpu_usage=$(awk -v idle="$idle" 'BEGIN {printf "%d%%", 100 - idle}')
fi

# Memory: /proc/meminfo does not exist on macOS; derive used memory from vm_stat
# (active + wired + compressor pages) and hw.memsize, mirroring the Linux
# "MemTotal - MemAvailable" used-memory intent.
mem_used_gb=""
if [ "$OS" = "Darwin" ]; then
  page_size=$(pagesize 2>/dev/null)
  mem_total_bytes=$(sysctl -n hw.memsize 2>/dev/null)
  if [ -n "$page_size" ] && [ -n "$mem_total_bytes" ]; then
    vm=$(vm_stat 2>/dev/null)
    active=$(echo "$vm" | awk '/Pages active/ {gsub("\\.","",$3); print $3}')
    wired=$(echo "$vm" | awk '/Pages wired down/ {gsub("\\.","",$4); print $4}')
    compressed=$(echo "$vm" | awk '/Pages occupied by compressor/ {gsub("\\.","",$5); print $5}')
    if [ -n "$active" ] && [ -n "$wired" ]; then
      mem_used_gb=$(awk -v a="$active" -v w="$wired" -v c="${compressed:-0}" -v ps="$page_size" \
        'BEGIN {printf "%.1fG", (a+w+c)*ps/1024/1024/1024}')
    fi
  fi
else
  mem_total_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)
  mem_avail_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null)
  if [ -n "$mem_total_kb" ] && [ -n "$mem_avail_kb" ]; then
    mem_used_gb=$(awk -v total="$mem_total_kb" -v avail="$mem_avail_kb" \
      'BEGIN {printf "%.1fG", (total-avail)/1024/1024}')
  fi
fi

# Git branch. Read from HEAD with the `read` builtin: walk up from $cwd to
# the first .git, follow a `gitdir:` file (worktrees, submodules) to the real
# git dir, and take "ref: refs/heads/<branch>" from its HEAD. A detached HEAD
# holds a hash and shows no branch, which is what `git branch
# --show-current` printed. No git fork at all, in a repo or outside one.
#
# git itself still answers wherever the file layout is not the whole story:
# $GIT_DIR / $GIT_WORK_TREE / $GIT_CEILING_DIRECTORIES in the environment, a
# bare repository (HEAD, objects/ and refs/ in the directory itself), a
# reftable repository (its HEAD file reads "ref: refs/heads/.invalid"), or a
# HEAD that cannot be read. It runs with --no-optional-locks (a status line
# must never take or wait on the index lock) under a 1 s timeout, so a git
# stuck on NFS or a huge repo costs one second a probe, not the render.
#
# A file read is not guarded the way git is, so it is only trusted with a
# HEAD (and a `.git` gitfile) that is a regular file owned by this user, and
# for at most 1024 characters. The read used to take any HEAD: a FIFO blocked
# it forever and a symlink to /dev/zero spun forever, neither under the
# timeout; a 2 MB HEAD was shown whole; and another local user who planted
# /tmp/.git (the CVE-2022-24765 setup, which git's safe.directory refuses as
# "dubious ownership") chose the branch every repo-less session under /tmp
# showed, Claude scratchpads included. Now a HEAD someone else owns, or one
# the cap cuts short, goes to git, which applies safe.directory; a HEAD that
# is not a file at all (FIFO, device, directory) is no repository, and
# nothing is asked.
#
# _git_cfg_ok <file>: may `git status` run with this repo-local config file?
# (See the status call below for why.) An absent file is fine. Anything but
# a regular file of ours is not, nor one past 64 KB or with a line past 4 KB
# (the read is capped per line, and a word split across two chunks would be
# missed), nor one naming a key that can run a command which the command
# line cannot pin off: a filter section, an include (the file it names is
# not followed here), or a transport or credential command a lazy fetch in
# a partial clone would use. fsmonitor and hooksPath are pinned anyway and
# refused all the same. Section and key names are case-insensitive to git
# and whitespace inside a line is dropped before matching ("[ Filter
# "x" ]", "[include]path=..", "fsMonitor = ..."). A section counts by its
# header, a key by its name only (a URL ending in /fsmonitor is no such
# key). A refusal skips the counts; the branch stays.
# Builtins only: `read` and `case`, with nocasematch (bash 3.1+).
# A refusal leaves its reason in $_git_cfg_why, for --doctor: the key class
# (filter, include, ...), never the line itself, which may hold a secret.
_git_cfg_ok() {
  local f="$1" l total=0 rc=0 nc=0 _k
  [ -e "$f" ] || [ -L "$f" ] || return 0
  [ -f "$f" ] && [ -O "$f" ] && [ -r "$f" ] || {
    _git_cfg_why="${f##*/} is not a regular, readable file owned by you"; return 1; }
  shopt -q nocasematch && nc=1
  shopt -s nocasematch
  while IFS= read -r -n 4096 l || [ -n "$l" ]; do
    [ ${#l} -ge 4096 ] && { _git_cfg_why="oversized config: ${f##*/} has a line past 4 KB"; rc=1; break; }
    total=$(( total + ${#l} + 1 ))
    [ "$total" -gt 65536 ] && { _git_cfg_why="oversized config: ${f##*/} is past 64 KB"; rc=1; break; }
    l="${l//[[:space:]]/}"
    # Sections by their header; keys by their name, the part before "=" (a
    # bare name is a boolean true), after a header on the same line if there
    # is one. A key name inside a value — a remote URL ending in
    # /fsmonitor — used to count as that key.
    _k="${l#\[*\]}"; _k="${_k%%=*}"
    case "$l" in
      \[filter*)      _git_cfg_why=filter ;;
      \[include*)     _git_cfg_why=include ;;
      \[credential*)  _git_cfg_why=credential ;;
      *) case "$_k" in
           fsmonitor)    _git_cfg_why=fsmonitor ;;
           hookspath)    _git_cfg_why=hooksPath ;;
           sshcommand)   _git_cfg_why=sshCommand ;;
           askpass)      _git_cfg_why=askpass ;;
           gitproxy)     _git_cfg_why=gitProxy ;;
           uploadpack)   _git_cfg_why=uploadpack ;;
           receivepack)  _git_cfg_why=receivepack ;;
           *) continue ;;
         esac ;;
    esac
    _git_cfg_why="${f##*/} names a key that can run a command ($_git_cfg_why)"
    rc=1; break
  done 2>/dev/null < "$f"
  [ "$nc" = 1 ] || shopt -u nocasematch
  return "$rc"
}
git_branch=""
git_repo=""
git_url=""
git_ab=""
git_dirty=""
_git_why="not a repo"; _git_why_until=""
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
  _git_ask=0; _gd=""
  if [ -n "${GIT_DIR-}${GIT_WORK_TREE-}${GIT_CEILING_DIRECTORIES-}" ]; then
    _git_ask=1
  else
    # The walk follows the physical path, as git does. The payload's cwd is
    # logical: a symlink into a repo subdirectory found no .git above it
    # (no branch), and a symlink inside repo A pointing into repo B found
    # A's .git while `git -C` (physical) named B's origin — A's branch
    # beside B's repo. `cd -P` resolves it with builtins only; the caller's
    # directory is restored at once. One difference remains: git stops at
    # a filesystem boundary and this walk does not, since a device number
    # takes a stat fork (a $HOME dotfiles repo shows on a separate mount).
    _d="$cwd"; _opwd="$PWD"
    if CDPATH= cd -P -- "$cwd" 2>/dev/null; then
      _d="$PWD"; cd -- "$_opwd" 2>/dev/null
    fi
    while :; do
      if [ -e "$_d/.git" ]; then _gd="$_d/.git"; break; fi
      if [ -f "$_d/HEAD" ] && [ -d "$_d/objects" ] && [ -d "$_d/refs" ]; then _git_ask=1; break; fi
      case "$_d" in /|'') break ;; esac
      _up="${_d%/*}"; [ -z "$_up" ] && _up=/
      # A relative cwd has no "/" left to strip; stop rather than loop.
      [ "$_up" = "$_d" ] && break
      _d="$_up"
    done
  fi
  # A .git that is neither file nor directory (a FIFO, a device) is no
  # repository either, and git would block opening it as a gitfile.
  if [ -n "$_gd" ] && [ ! -f "$_gd" ] && [ ! -d "$_gd" ]; then _gd=""; _git_ask=0; fi
  if [ -n "$_gd" ] && [ -f "$_gd" ]; then
    # A worktree or submodule: "gitdir: <path>", relative to the .git file.
    _l=""
    # 2>/dev/null first: redirections apply in order, and the open error of
    # an unreadable file would otherwise reach stderr before it is silenced.
    [ -O "$_gd" ] && IFS= read -r -n 1024 _l 2>/dev/null < "$_gd"
    [ ${#_l} -ge 1024 ] && _l=""
    case "$_l" in
      "gitdir: "/*) _gd="${_l#gitdir: }" ;;
      "gitdir: "?*) _gd="$_d/${_l#gitdir: }" ;;
      *) _gd=""; _git_ask=1 ;;
    esac
  fi
  _git_head_why=""  # why there is no branch, when it is not a detached HEAD
  if [ -n "$_gd" ]; then
    _h=""
    if [ -e "$_gd/HEAD" ] && [ ! -f "$_gd/HEAD" ]; then
      _h="-"  # not a file: no branch, and no git asked to open it either
      _git_head_why="HEAD is not a regular file"
    elif [ -L "$_gd/HEAD" ]; then
      # A symlinked HEAD (core.preferSymlinkRefs, old git) reads as the
      # branch file's hash, i.e. detached; git resolves the link itself.
      _h=""
    elif [ -O "$_gd/HEAD" ]; then
      IFS= read -r -n 1024 _h 2>/dev/null < "$_gd/HEAD"
      [ ${#_h} -ge 1024 ] && _h=""
    elif [ -e "$_gd/HEAD" ]; then
      _git_head_why="HEAD not owned by you"
    fi
    # Only the two canonical shapes are settled here: exactly "ref:
    # refs/heads/<name>" (no whitespace: git refuses it in a ref name, so
    # "ref:refs/heads/x" or a trailing space is not a HEAD git wrote) and a
    # bare 40- or 64-digit hash, a detached HEAD, which shows no branch.
    # Anything else is git's to judge. The hex list is spelled out: bash
    # 3.2 matches a range by collation order, which can admit A-F.
    case "$_h" in
      -) ;;
      "ref: refs/heads/.invalid"|"ref: refs/heads/"*[[:space:]]*) _git_ask=1 ;;
      "ref: refs/heads/"?*) git_branch="${_h#ref: refs/heads/}" ;;
      *[!0123456789abcdef]*|'') _git_ask=1 ;;
      *) case "${#_h}" in 40|64) ;; *) _git_ask=1 ;; esac ;;
    esac
  fi
  if [ "$_git_ask" = 1 ]; then
    git_branch=$(_run_to 1 git --no-optional-locks -C "$cwd" branch --show-current 2>/dev/null)
  fi
  # owner/repo from the origin remote, shown to the left of the branch so it is
  # obvious which repository the branch belongs to. Handles both SSH and HTTPS
  # remotes; stays empty when there is no origin.
  #
  # An https remote also gives the repo's web address, which the git segment
  # links to (OSC 8, see "Hyperlinks"). Only https: an SSH remote names a
  # host whose web address is anyone's guess. The user-info part goes, so a
  # token in "https://x-access-token:TOKEN@github.com/..." never reaches the
  # terminal, even inside an escape sequence nobody sees. The remote is
  # captured once and cut with parameter expansion: the same forks as the
  # pipe it replaces (one git, one sed).
  if [ -n "$git_branch" ]; then
    _remote=$(_run_to 1 git --no-optional-locks -C "$cwd" remote get-url origin 2>/dev/null)
    if [ -n "$_remote" ]; then
      git_repo=$(printf '%s' "$_remote" \
        | LC_ALL=C sed -E 's#^git@[^:]+:#/#; s#^[a-z]+://[^/]+/#/#; s#\.git$##; s#^/##')
    fi
    case "$_remote" in
      https://?*/?*)
        _u="${_remote#https://}"; _h="${_u%%/*}"; _h="${_h##*@}"; _u="${_u#*/}"
        # Spelled out, not ranges: bash 3.2 matches [a-z] by collation order.
        case "$_h$_u" in
          *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._~:/%+@=-]*|'') ;;
          *) git_url="https://${_h}/${_u%.git}" ;;
        esac ;;
    esac
  fi
  # Ahead/behind and uncommitted work: "↑2↓1" and "±3 ?2 ✖1" (changed,
  # untracked, conflicted) beside the branch — the two git facts worth a
  # glance while an agent edits files. One `git status --porcelain=v2
  # --branch` answers both, parsed by a read loop (no awk, no fork). It
  # runs here, behind the probe cache, so once per AGENTLINE_PROBE_TTL at
  # most, never on the per-second tick; the counts can therefore trail an
  # edit by up to that long.
  #
  # Unlike the branch read above, this cannot be done from files, and on a
  # large repository the untracked scan alone can take seconds. So it only
  # runs under the 1 s timeout, and without a timeout binary (macOS with no
  # Homebrew coreutils) it does not run at all: the segment degrades to the
  # branch alone rather than risk a render that blocks. A timeout, or any
  # failure, discards the output — a half-written answer would under-count.
  # AGENTLINE_GIT_UNTRACKED=0 skips the untracked scan (-uno), and
  # AGENTLINE_GIT_STATUS=0 turns the call off. Detached HEAD shows no branch
  # segment, so it is not asked either.
  #
  # `git status` is also the one call here that can run commands the
  # repository itself names. `branch --show-current` and `remote get-url`
  # only read config and refs, but status refreshes the index: it starts
  # core.fsmonitor, runs the clean filter (filter.<x>.clean / .process,
  # chosen per file by .gitattributes) of every file whose stat changed,
  # recurses into submodules with their own configs, and in a partial clone
  # may fetch a missing blob through whatever transport the config names. A
  # repository unpacked from someone else's tarball carries its own
  # .git/config, and every render in it ran that code, once per probe — the
  # "git prompt" hole shell prompts had in 2022. The user's global config is
  # theirs and trusted (git-lfs is a clean filter); only the repo's is not.
  # So, before the call, _git_cfg_ok reads the repo-local config files with
  # the `read` builtin (no fork) and the call is skipped — branch alone, as
  # without a timeout binary — when one mentions a command-bearing key that
  # cannot be pinned off (a filter, an include it cannot follow, a transport
  # command), and when the git dir or its HEAD is not the user's (the rule
  # the HEAD reader applies). The rest is pinned on the command line, which
  # outranks every config file: core.fsmonitor=false, core.hooksPath=
  # /dev/null (a post-index-change hook, should the index ever be written),
  # --ignore-submodules=dirty (no child git under a submodule's own config;
  # a submodule moved to another commit still counts, edits inside one no
  # longer do) and GIT_NO_LAZY_FETCH=1 (git 2.44+; older git ignores it, and
  # the scan refuses the transport keys instead).
  #
  # Each way out leaves its reason in $_git_why, for --doctor ("why are my
  # counts missing?" has eight answers, none visible on the line). Plain
  # assignments: no fork, and it is never cached or shown.
  _git_st_ok=0
  if [ -z "$git_branch" ]; then
    { [ -n "$_gd" ] || [ "$_git_ask" = 1 ]; } && _git_why="no branch (${_git_head_why:-a detached HEAD}): no git segment"
  elif [ "${AGENTLINE_GIT_STATUS:-1}" = 0 ]; then
    _git_why="disabled (AGENTLINE_GIT_STATUS=0)"
  elif [ -z "$_TIMEOUT" ]; then
    _git_why="no timeout/gtimeout binary (stock macOS: brew install coreutils)"
  elif [ -z "$_gd" ] || [ ! -d "$_gd" ]; then
    _git_why="git dir not found by the file walk (GIT_DIR set, or a bare repo)"
  elif [ ! -O "$_gd" ] || [ ! -f "$_gd/HEAD" ] || [ ! -O "$_gd/HEAD" ]; then
    _git_why="git dir or HEAD not owned by you"
  elif ! _git_cfg_ok "$_gd/config" || ! _git_cfg_ok "$_gd/config.worktree"; then
    _git_why="$_git_cfg_why"
  else
    _git_st_ok=1
    # A linked worktree's git dir holds its HEAD and config.worktree; the
    # shared config sits in the common dir its `commondir` file names.
    if [ -e "$_gd/commondir" ]; then
      _l=""
      [ -f "$_gd/commondir" ] && [ -O "$_gd/commondir" ] && IFS= read -r -n 1024 _l 2>/dev/null < "$_gd/commondir"
      [ ${#_l} -ge 1024 ] && _l=""
      case "$_l" in
        '') _git_st_ok=0; _git_why="worktree commondir unreadable or not owned by you" ;;
        /*) ;;
        *)  _l="$_gd/$_l" ;;
      esac
      if [ "$_git_st_ok" = 1 ]; then
        if [ ! -d "$_l" ] || [ ! -O "$_l" ]; then
          _git_st_ok=0; _git_why="the worktree's common git dir is not owned by you"
        elif ! _git_cfg_ok "$_l/config" || ! _git_cfg_ok "$_l/config.worktree"; then
          _git_st_ok=0; _git_why="common dir: $_git_cfg_why"
        fi
      fi
    fi
  fi
  # A repository slow enough to hit the timeout would hit it on every probe
  # miss, a second each time, for nothing: the answer is thrown away. So a
  # timeout is remembered in ${CACHE_BASE}.gitslow ("<until-epoch>" and the
  # %q-quoted cwd, one line each), and the call sits out four probe TTLs (at
  # least a minute) in that directory; the branch still shows. Another cwd,
  # or the time passing, asks again. Read with builtins, like the caches.
  _gs_file=""
  [ -n "$CACHE_BASE" ] && _gs_file="${CACHE_BASE}.gitslow"
  # --doctor has no cache base (it writes nothing) but reads the back-off a
  # real render obeys, so its report says what the status line does.
  _gs_read="$_gs_file"
  [ -n "$_AL_DOCTOR" ] && [ "$_dt_cache_ok" = 1 ] && _gs_read="${CACHE_DIR}/render_${_sid}.v${CACHE_FORMAT}.gitslow"
  if [ "$_git_st_ok" = 1 ] && [ -n "$_gs_read" ] && [ -f "$_gs_read" ]; then
    _gs_until=""; _gs_cwd=""
    { IFS= read -r _gs_until; IFS= read -r _gs_cwd; } 2>/dev/null < "$_gs_read"
    case "$_gs_until" in
      ''|*[!0-9]*) ;;
      *) [ "$_gs_cwd" = "$_cwd_q" ] && [ "$_now_epoch" -lt "$_gs_until" ] \
           && { _git_st_ok=0; _git_why=back-off; _git_why_until="$_gs_until"; } ;;
    esac
  fi
  if [ "$_git_st_ok" = 1 ]; then
    _uflag="-unormal"; [ "${AGENTLINE_GIT_UNTRACKED:-1}" = 0 ] && _uflag="-uno"
    _st=$(GIT_NO_LAZY_FETCH=1 "$_TIMEOUT" 1 git --no-optional-locks -c core.fsmonitor=false \
            -c core.hooksPath=/dev/null -C "$cwd" status --porcelain=v2 --branch \
            --ignore-submodules=dirty "$_uflag" 2>/dev/null)
    _st_rc=$?
    if [ "$_st_rc" = 124 ] && [ -n "$_gs_file" ]; then
      _gs_for=60
      case "$PROBE_TTL" in ''|*[!0-9]*|??????*) ;; *) [ $(( 10#$PROBE_TTL * 4 )) -gt 60 ] && _gs_for=$(( 10#$PROBE_TTL * 4 )) ;; esac
      printf '%s\n%s' "$(( _now_epoch + _gs_for ))" "$_cwd_q" > "$_gs_file" 2>/dev/null
      _git_why=back-off; _git_why_until=$(( _now_epoch + _gs_for ))
    elif [ "$_st_rc" != 0 ]; then
      _git_why="git status failed (exit $_st_rc)"
      [ "$_st_rc" = 124 ] && _git_why="git status timed out (1 s)"
    fi
    if [ "$_st_rc" = 0 ]; then
      _ahead=0; _behind=0; _chg=0; _unt=0; _cfl=0
      # The read loop runs after the timeout, unguarded: 80,000 untracked
      # files took it 1.4 s on bash 5 and 3.4 s on bash 3.2. Past 64 KB of
      # output (~1,500 entries) one awk counts instead, in milliseconds.
      if [ ${#_st} -gt 65536 ]; then
        IFS=' ' read -r _ahead _behind _chg _unt _cfl <<< "$(printf '%s\n' "$_st" | awk '
          /^# branch\.ab / { a = $3; b = $4; sub(/^\+/, "", a); sub(/^-/, "", b) }
          /^[12] / { c++ }
          /^\? / { q++ }
          /^u / { u++ }
          END { printf "%d %d %d %d %d\n", a, b, c, q, u }')"
        case "$_chg$_unt$_cfl" in ''|*[!0-9]*) _chg=0; _unt=0; _cfl=0 ;; esac
      else
        while IFS= read -r _l; do
          case "$_l" in
            "# branch.ab +"*" -"*)
              _ahead="${_l#\# branch.ab +}"; _behind="${_ahead#* -}"; _ahead="${_ahead%% *}" ;;
            "1 "*|"2 "*) _chg=$(( _chg + 1 )) ;;
            "u "*) _cfl=$(( _cfl + 1 )) ;;
            "? "*) _unt=$(( _unt + 1 )) ;;
          esac
        done <<< "$_st"
      fi
      case "$_ahead$_behind" in ''|*[!0-9]*) _ahead=0; _behind=0 ;; esac
      [ "$_ahead" != 0 ] && git_ab="↑${_ahead}"
      [ "$_behind" != 0 ] && git_ab="${git_ab}↓${_behind}"
      [ "$_chg" -gt 0 ] && git_dirty="±${_chg}"
      [ "$_unt" -gt 0 ] && git_dirty="${git_dirty:+${git_dirty} }?${_unt}"
      [ "$_cfl" -gt 0 ] && git_dirty="${git_dirty:+${git_dirty} }✖${_cfl}"
      # porcelain v2 prints "# branch.upstream" when one is set, and
      # "# branch.ab" only when that upstream's ref exists: an upstream
      # whose branch was deleted (or never fetched) has the first line
      # without the second, and is not "in sync" with anything.
      case "$_st" in
        *"# branch.ab "*)
          if [ -z "$git_ab" ]; then _git_why="in sync with its upstream"
          else _git_why="ahead/behind its upstream"; fi ;;
        *"# branch.upstream "*) _git_why="upstream gone (no ahead/behind)" ;;
        *) _git_why="no upstream (no ahead/behind)" ;;
      esac
      [ -z "$git_dirty" ] && _git_why="$_git_why, clean tree"
    fi
  fi
fi

# Active MCP servers (from ~/.claude.json: global + this project; process check)
# (Program read first, run with -c: see the note at the payload parser.)
IFS= read -r -d '' _AL_PY <<'PYEOF'
import json, os, sys, subprocess
try:
    cwd = sys.argv[1]
    with open(os.path.expanduser('~/.claude.json')) as f:
        cfg = json.load(f)
    servers = dict(cfg.get('mcpServers', {}))
    servers.update(cfg.get('projects', {}).get(cwd, {}).get('mcpServers', {}))
    active = []
    for name, conf in servers.items():
        if conf.get('type') in ('http', 'sse') or conf.get('url'):
            active.append(name)  # remote server, no local process
            continue
        args = conf.get('args', [])
        search = args[0] if args else conf.get('command', '')
        if not search:
            continue
        try:
            r = subprocess.run(['pgrep', '-f', search], capture_output=True, text=True, timeout=1)
            if r.returncode == 0:
                active.append(name)
        except Exception:
            pass
    print(' · '.join(active))
except Exception:
    print('')
PYEOF
active_mcps=$(python3 -I -c "$_AL_PY" "$cwd")

fi  # end of throttled host probes (part 1)
[ -n "$_AL_DOCTOR" ] && _dt_mark probes:cpu,mem,git,mcp

# Side files written by the optional hooks (hooks/*.sh) live in one
# directory, $AGENTLINE_TMP when set. The hooks resolve it by the same rule,
# so reader and writers always agree. The agent registry also honours
# CLAUDE_AGENTS_FILE, the override agentline-agent.sh has always accepted.
#
# The default is private to the user: $XDG_RUNTIME_DIR/agentline when that
# directory is a real one of ours, else ${TMPDIR:-/tmp}/agentline-$EUID (the
# cache directory, made 0700 above). It used to be /tmp itself, where
# anyone on the host could read the registry — whose labels are Claude
# subagent descriptions and the names of external work — and the word
# counts. A default directory that fails the owner/symlink check is not
# read at all. The files the previous release wrote, /tmp/claude_*.txt, are
# still read for one release when they are ours, so an upgrade never blanks
# the bar while an older hook is still running; the writers remove them.
# All of it is tests and parameter expansion: no fork.
_side_legacy=""
if [ -z "${AGENTLINE_TMP-}" ]; then
  if [ -n "${XDG_RUNTIME_DIR-}" ] && [ -d "$XDG_RUNTIME_DIR" ] && [ ! -L "$XDG_RUNTIME_DIR" ] && [ -O "$XDG_RUNTIME_DIR" ]; then
    AGENTLINE_TMP="$XDG_RUNTIME_DIR/agentline"
  else
    AGENTLINE_TMP="${TMPDIR:-/tmp}/agentline-${EUID:-0}"
  fi
  [ -d "$AGENTLINE_TMP" ] && [ ! -L "$AGENTLINE_TMP" ] && [ -O "$AGENTLINE_TMP" ] || AGENTLINE_TMP=/nonexistent/agentline
  _side_legacy="${_AGENTLINE_LEGACY_TMP:-/tmp}"
fi
AGENTS_FILE="${CLAUDE_AGENTS_FILE:-$AGENTLINE_TMP/claude_agents.txt}"
# The legacy registry, only when no override is set and it is ours — and
# only from a directory where nobody else can swap it between this test and
# the read: one of ours, or a sticky one (/tmp), where a file of ours can be
# renamed or replaced by us alone. A world-writable /tmp without the sticky
# bit is skipped whole.
_agents_legacy=""
if [ -n "$_side_legacy" ] && [ -z "${CLAUDE_AGENTS_FILE-}" ] && [ -f "$_side_legacy/claude_agents.txt" ] \
   && [ ! -L "$_side_legacy/claude_agents.txt" ] && [ -O "$_side_legacy/claude_agents.txt" ] \
   && { [ -O "$_side_legacy" ] || [ -k "$_side_legacy" ]; }; then
  _agents_legacy="$_side_legacy/claude_agents.txt"
fi
WC_FILE="$AGENTLINE_TMP/claude_wordcount.txt"
if [ ! -f "$WC_FILE" ] && [ -n "$_side_legacy" ] && [ -f "$_side_legacy/claude_wordcount.txt" ] \
   && [ ! -L "$_side_legacy/claude_wordcount.txt" ] && [ -O "$_side_legacy/claude_wordcount.txt" ]; then
  WC_FILE="$_side_legacy/claude_wordcount.txt"
fi

# Active agents (from hook-written file) — never throttled, see PROBE_VARS.
# One awk does all of it, in the order the rows were registered (oldest
# first, so a label keeps its place from one second to the next):
#   - a running agent (fresher than 5 minutes) is shown up to
#     AGENTLINE_AGENT_SHOW (default 4) times; the rest are counted, "+3".
#     The registry used to evict the oldest past 16 rows, silently, and the
#     reader had no cap at all, so a big dispatch either hid work or ran the
#     line off the screen at 25 cells a label.
#   - a finished one ("✓<label>", written on SubagentStop) is shown for 10
#     seconds after it stopped, the newest two at most, so a finish reads as
#     a flash rather than as a row that vanished.
#   - a row the tracker hook wrote carries the mark of a Claude subagent
#     (\x1fc after the label, see agentline-agent.sh). With
#     AGENTLINE_AGENTS=external those rows are left out: Claude Code's
#     subagent panel (agentline-subagents.sh) already lists every one of
#     them, and the main line keeps the work the panel never shows, the
#     external workers agentline-run and other scripts register.
#     install.sh --with-subagents sets it. The default, all, shows both.
# It prints one entry per line, "<kind><text>": c a Claude subagent, e any
# other running row, n the "+N" count, d a finished one. The kind picks the
# colour (see "Agent rows" below), and the colours cannot ride inside the
# text (cleaning strips the escapes). The joins happen in awk: no sed (BSD
# sed aborted on a label with an invalid byte). The time is $_now_epoch, set
# at startup: the `date +%s` this used to run was a fork per full render for
# a number the script already had.
_ag_raw=""
case "${AGENTLINE_AGENT_SHOW-}" in ''|*[!0-9]*|???*) _ag_show=4 ;; *) _ag_show=$(( 10#$AGENTLINE_AGENT_SHOW )) ;; esac
case "${AGENTLINE_AGENTS-}" in external) _ag_ext=1 ;; *) _ag_ext=0 ;; esac
# Only a regular file of ours, not a symlink, like the legacy one: -f alone
# refuses a FIFO (which would hang awk's open, and so the render, every
# second) but follows a link to anyone's file, and a CLAUDE_AGENTS_FILE may
# sit in a directory others write to. The tests are builtins (no fork). awk
# reads at most 512 rows (the writers keep 32): a registry grown by someone
# else's hand costs no more than that.
_ag_files=()
[ -f "$AGENTS_FILE" ] && [ ! -L "$AGENTS_FILE" ] && [ -O "$AGENTS_FILE" ] && _ag_files=("$AGENTS_FILE")
[ -n "$_agents_legacy" ] && _ag_files[${#_ag_files[@]}]="$_agents_legacy"
if [ "${#_ag_files[@]}" -gt 0 ]; then
  _ag_raw=$(awk -v now="$_now_epoch" -v show="$_ag_show" -v ext="$_ag_ext" '
    function cut(s) { if (length(s) > 25) s = substr(s, 1, 22) "..."; return s }
    NR > 512 { exit }
    {
      age = now - $1
      if ($1 !~ /^[0-9]+$/ || age < 0) next
      label = substr($0, index($0, $2))
      # A key may carry a run id after a unit separator (agentline-run: one
      # row per run), or the mark of a Claude subagent; neither is shown,
      # and runs of one label count as one.
      claude = (label ~ /\037c$/)
      sub(/\037.*/, "", label)
      if (claude && ext) next
      if (index(label, "✓") == 1) {
        if (age < 10) done[nd++] = cut(substr(label, length("✓") + 1))
      } else if (age < 300 && label != "") {
        key = (claude ? "c" : "e") label
        if (!(key in cnt)) ord[n++] = key
        cnt[key]++
      }
    }
    END {
      for (i = 0; i < n && i < show; i++)
        printf "%s%s%s\n", substr(ord[i], 1, 1), cut(substr(ord[i], 2)), (cnt[ord[i]] > 1 ? " ×" cnt[ord[i]] : "")
      if (n > show) printf "n+%d\n", n - show
      for (i = (nd > 2 ? nd - 2 : 0); i < nd; i++) printf "d%s\n", done[i]
    }' "${_ag_files[@]}")
fi
[ -n "$_AL_DOCTOR" ] && _dt_mark agents

# Home-relative path (~/projects/agentline) rather than the bare folder name.
# Paths outside $HOME are shown absolute.
case "$cwd_disp" in
  "$HOME")   folder="~" ;;
  "$HOME"/*) folder="~${cwd_disp#"$HOME"}" ;;
  *)         folder="$cwd_disp" ;;
esac

if [ "$_probes_fresh" != 1 ]; then

# SSH sessions. Remote logins are `pts/N` on Linux but `ttysNNN` on macOS, which
# is indistinguishable from a local terminal by device name alone. Both platforms
# do append the origin host in parentheses for remote logins, so count those --
# excluding local X displays, which render as "(:0)".
ssh_count=$(who 2>/dev/null | awk '/\(([^:)][^)]*)\)/ {n++} END {print n+0}')

# User cron jobs (hidden when empty). Uses awk rather than `grep -cv '\s'`:
# \s is a GNU extension that BSD grep does not honour, so the old form counted
# comment lines on macOS.
cron_count=$(crontab -l 2>/dev/null | awk '!/^[[:space:]]*(#|$)/ {n++} END {print n+0}')

# Dev servers: user-owned listeners on ports 3000-9999 (excludes system/IDE noise).
# Socket enumeration is platform-specific -- `ss` on Linux, `lsof` on macOS --
# and each branch collects port -> process; the shared awk END below labels
# them "proc(port)", space-separated, with any parentheses round the process
# name trimmed. That labelling used to be a python3 and a sed of their own.
_dev_label='END {
  out = ""
  for (p in seen) {
    proc = seen[p]; gsub(/^[()]+/, "", proc); gsub(/[()]+$/, "", proc)
    out = out (out == "" ? "" : " ") proc "(" p ")"
  }
  printf "%s", out
}'
if command -v ss >/dev/null 2>&1; then
  dev_ports=$(ss -ltnp 2>/dev/null | awk '
    /users:\(\(/ {
      n = split($4, a, ":"); port = a[n]
      if (port ~ /^[0-9]+$/ && port >= 3000 && port <= 9999) {
        match($0, /users:\(\("[^"]+"/)
        seen[port] = substr($0, RSTART+9, RLENGTH-10)
      }
    }
    '"$_dev_label")
else
  dev_ports=$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {
      n = split($9, a, ":"); port = a[n]
      if (port ~ /^[0-9]+$/ && port >= 3000 && port <= 9999) {
        seen[port] = $1
      }
    }
    '"$_dev_label")
fi

# Disk usage (root fs). Some mounts report "-" instead of a percentage; the
# numeric guard hides the segment there rather than tripping the -ge test below.
disk_pct=$(df -P / 2>/dev/null | awk 'NR==2 {gsub("%","",$5); if ($5 ~ /^[0-9]+$/) print $5}')

# Service health mini-panel (name + status per service).
# Machine-local config, one "systemd-unit-name:Label" per line; # and blanks ignored.
# Kept out of the repo on purpose so each machine can list its own units.
SVC_CONFIG="${AGENTLINE_SERVICES:-$HOME/.claude/agentline-services.conf}"
svc_panel=""
# One `systemctl show` answers for every unit. It used to be two calls per
# unit (`systemctl cat` to skip units not defined here, then `is-active`),
# 2N forks for N units. `is-active` alone cannot replace the pair: it prints
# "inactive" for a unit that does not exist, which would turn "not on this
# machine" into a red ✗. `show` prints one block per unit, in argument
# order, blank-line separated, and LoadState=not-found is exactly the unit
# `cat` used to fail on (a masked unit is loaded as "masked", which `cat`
# accepted, so it still shows ✗). Healthy is what `is-active` accepted:
# active, reloading or refreshing. The properties are read by name, because
# --value prints them in systemd's order, not the order asked for.
#
# systemctl aborts at the first invalid unit name ("bad name!"), dropping
# every block after it. A short answer is therefore re-asked one unit at a
# time, which is the old cost, paid only by a config with a bad line. A
# timed-out answer (status 124) is not re-asked: a systemd that does not
# answer once would not answer N times either.
_svc_state() {  # _svc_state <systemctl show output> -> _svc_load[], _svc_act[]
  local l i=0
  _svc_load=(); _svc_act=()
  while IFS= read -r l; do
    case "$l" in
      '') i=$(( i + 1 )) ;;
      LoadState=*) _svc_load[$i]="${l#*=}" ;;
      ActiveState=*) _svc_act[$i]="${l#*=}" ;;
    esac
  done <<< "$1"
}
# systemd is Linux-only. On macOS the panel stays empty and line 4 degrades cleanly.
if command -v systemctl >/dev/null 2>&1 && [ -r "$SVC_CONFIG" ]; then
  # Two kinds of name never reach `show`. A glob (* ? [) is skipped, as
  # `systemctl cat` refused one: `show` expands it, so "ssh*" answered for
  # whatever it matched (or for nothing), and the blocks no longer lined up
  # with the labels. A template ("getty@.service") is no unit systemd can
  # report on — `show` rejects it as a bad name and so forced the per-unit
  # re-ask on every probe — but `cat` accepted it and `is-active` failed
  # it, so it showed ✗; it still does, without asking (unlike `cat`, even
  # when the template is not installed here). _svc_q holds the asked units,
  # _svc_tmpl[i] marks a template entry.
  _svc_units=(); _svc_labels=(); _svc_tmpl=(); _svc_q=()
  while IFS=: read -r svc label; do
    case "$svc" in ''|\#*|*[*?[]*) continue ;; esac
    [ -z "$label" ] && label="$svc"
    # The label sits between real escapes, so it is cleaned here rather
    # than with the other host strings below ($svc_panel keeps its colours).
    label="${label//[[:cntrl:]]/}"; label="${label//\\/}"
    label="${label//${_C1_LEAD}[${_C1_LO}-${_C1_HI}]/}"
    case "$svc" in
      *@.*) _svc_tmpl[${#_svc_units[@]}]=1 ;;
      *) _svc_q[${#_svc_q[@]}]="$svc" ;;
    esac
    _svc_units[${#_svc_units[@]}]="$svc"
    _svc_labels[${#_svc_labels[@]}]="$label"
  done < "$SVC_CONFIG"
  _svc_load=(); _svc_act=()
  if [ ${#_svc_q[@]} -gt 0 ]; then
    _svc_out=$(_run_to 2 systemctl show -p LoadState,ActiveState -- "${_svc_q[@]}" 2>/dev/null)
    _svc_rc=$?
    _svc_state "$_svc_out"
    if [ "$_svc_rc" != 124 ] && [ ${#_svc_load[@]} != ${#_svc_q[@]} ]; then
      _svc_l=(); _svc_a=()
      for (( _i = 0; _i < ${#_svc_q[@]}; _i++ )); do
        _svc_state "$(_run_to 1 systemctl show -p LoadState,ActiveState -- "${_svc_q[$_i]}" 2>/dev/null)"
        _svc_l[$_i]="${_svc_load[0]}"; _svc_a[$_i]="${_svc_act[0]}"
      done
      _svc_load=(); _svc_act=()
      for (( _i = 0; _i < ${#_svc_q[@]}; _i++ )); do
        _svc_load[$_i]="${_svc_l[$_i]}"; _svc_act[$_i]="${_svc_a[$_i]}"
      done
    fi
  fi
  _j=0  # index into the asked units' answers
  for (( _i = 0; _i < ${#_svc_units[@]}; _i++ )); do
    label="${_svc_labels[$_i]}"
    if [ -n "${_svc_tmpl[$_i]}" ]; then
      _sl=loaded; _sa=template
    else
      _sl="${_svc_load[$_j]}"; _sa="${_svc_act[$_j]}"; _j=$(( _j + 1 ))
    fi
    # No answer (invalid name, timeout) or not defined here: skip it.
    case "$_sl" in ''|not-found) continue ;; esac
    case "$_sa" in
      active|reloading|refreshing) entry="\033[2m${label} ✓\033[0m" ;;
      *) entry="\033[1;31m${label} ✗\033[0m" ;;
    esac
    svc_panel="${svc_panel:+${svc_panel} \033[2m·\033[0m }${entry}"
  done
fi

fi  # end of throttled host probes (part 2)
[ -n "$_AL_DOCTOR" ] && _dt_mark probes:ssh,cron,ports,disk,services

# Persist the probe results for the next $PROBE_TTL seconds. `printf -v %q` is
# a builtin, so quoting the values costs no fork, and it round-trips the ANSI
# escapes in $svc_panel through eval intact. Skipped when the probes came from
# the cache (nothing new to store) or when the cache directory failed its
# ownership check at stage 0.
#
# bash 3.2's %q leaves `~` unescaped, and the body is replayed as assignments,
# where a tilde at the start of the value or after a `:` or `=` is expanded:
# a remote like https://git.sr.ht/~root/x (git_repo "~root/x") came back as
# "/root/x" on every cached tick. Those tildes are escaped by hand, as bash 5
# does. Not inside $'...' (a value with control bytes), where `\~` would stay
# a literal backslash — and where tildes are never expanded anyway.
if [ "$_probes_fresh" != 1 ] && [ -n "$CACHE_BASE" ]; then
  _pc_out=""
  for _v in $PROBE_VARS; do
    printf -v _q '%q' "${!_v}"
    case "$_q" in
      \$\'*) ;;
      *) case "$_q" in '~'*) _q="\\$_q" ;; esac
         _q="${_q//:~/:\\~}"; _q="${_q//=~/=\\~}" ;;
    esac
    _pc_out="${_pc_out}${_v}=${_q}"$'\n'
  done
  printf '%s\n%s\n%s' "$_now_epoch" "$_cwd_q" "$_pc_out" > "${CACHE_BASE}.probes" 2>/dev/null
fi

# === Display sanitization ===
# Everything assembled below is printed with `printf %b`, which turns a
# backslash sequence into a real escape, and the terminal acts on any raw
# control byte. Host-derived text is not trustworthy: a remote URL, a
# directory name, a listening process's name, an agent label or an MCP
# server name is whatever someone else chose, and "\033]0;owned\a" in any of
# them would retitle the window or rewrite the line. Payload strings are
# cleaned in the parser; these are cleaned here, after the probe cache is
# loaded, so values read back from a cache written by an older release are
# covered too. [[:cntrl:]] is C0 + DEL, and under a UTF-8 locale also the
# C1 range — but only there: under C/POSIX or an unset LANG (common on
# servers, and what the test suite runs) a UTF-8 encoded C1 such as U+009B
# CSI (bytes C2 9B) is two ordinary bytes to bash and survived, although
# xterm-class terminals act on it (and git allows it in a branch name). So
# C2 80..C2 9F is also stripped byte-wise, which matches in every locale and
# cannot touch any other character: C2 is only ever a lead byte, and C2 A0+
# (NBSP, ©, …) is outside the range. A raw lone 0x80-0x9F byte is left: it
# cannot be told from a continuation byte (ş is C5 9F, 🚀 F0 9F 9A 80)
# without decoding, and a UTF-8 terminal does not treat it as C1 anyway.
# Pure parameter expansion: no fork, and this is the slow path.
_clean() {  # _clean <varname> -- strip control characters and backslashes
  local v="${!1}"
  v="${v//[[:cntrl:]]/}"
  v="${v//${_C1_LEAD}[${_C1_LO}-${_C1_HI}]/}"
  v="${v//\\/}"
  printf -v "$1" '%s' "$v"
}
for _v in git_branch git_repo git_url git_ab git_dirty folder active_mcps dev_ports; do
  _clean "$_v"
done

# === Colors ===
RESET="\033[0m"
# Faint in the terminal's own foreground, not a fixed white: 2;37 vanished on
# light themes. 90 (bright black) is no fix either — it is the background on
# Solarized-style dark themes.
DIM="\033[2m"
GREEN="\033[1;32m"
BLUE="\033[1;34m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
MAGENTA="\033[1;35m"
GOLD="\033[1;38;5;220m"
ORANGE="\033[1;38;5;208m"
# The Fable/Mythos gradient's endpoints, "r,g,b", painted by the layout pass.
FABLE_FROM="255,215,90"
FABLE_TO="255,125,25"
if [ "$_AL_THEME" = light ]; then
  # Darker amber to burnt orange, about 4-5:1 on white against 1.4-2.6:1.
  FABLE_FROM="180,110,0"
  FABLE_TO="190,70,0"
  GOLD="\033[1;38;5;136m"
  ORANGE="\033[1;38;5;166m"
fi
# Per-colour overrides, "r,g,b" each 0-255, only for the fixed colours above.
# They live in settings.json's env block, which survives an upgrade (install.sh
# replaces this script). A value that is not three numbers up to 255 is
# ignored rather than half-applied.
_rgb_val() {  # _rgb_val <r,g,b> -> $_rgb "r;g;b", status 1 when malformed
  local v="$1" r g b c
  _rgb=""
  case "$v" in *[!0-9,]*|*,*,*,*) return 1 ;; ?*,?*,?*) ;; *) return 1 ;; esac
  r="${v%%,*}"; b="${v##*,}"; g="${v#*,}"; g="${g%,*}"
  for c in "$r" "$g" "$b"; do
    case "$c" in ''|????*) return 1 ;; esac
    [ $(( 10#$c )) -le 255 ] || return 1
  done
  _rgb="$(( 10#$r ));$(( 10#$g ));$(( 10#$b ))"
}
_rgb_val "${AGENTLINE_COLOR_GOLD-}"       && GOLD="\033[1;38;2;${_rgb}m"
_rgb_val "${AGENTLINE_COLOR_ORANGE-}"     && ORANGE="\033[1;38;2;${_rgb}m"
_rgb_val "${AGENTLINE_COLOR_FABLE_FROM-}" && FABLE_FROM="${_rgb//;/,}"
_rgb_val "${AGENTLINE_COLOR_FABLE_TO-}"   && FABLE_TO="${_rgb//;/,}"

# === Glyphs ===
# AGENTLINE_GLYPHS=emoji (default) | ascii. Every icon comes from this one
# table, and each carries its own trailing space, so an icon that is empty in
# a set leaves no double space behind. That also retires the hand-tuned
# double spaces ("⚙️  ", "🏷️  ") the emoji with a variation selector used to
# get: the layout pass now measures an emoji + U+FE0F as the two cells it is
# drawn in (see vis() there), so one space is right everywhere. ascii prints
# nothing above U+007F, for terminals and fonts with no emoji or box
# drawing, and for logs; its icons become short words ("cpu:", "git:") or
# nothing where the value already says what it is ("$12.47", "ssh:2").
case "${AGENTLINE_GLYPHS-}" in ascii) _AL_GLYPHS=ascii ;; *) _AL_GLYPHS=emoji ;; esac
if [ "$_AL_GLYPHS" = ascii ]; then
  G_SEP="|";      G_DOT="/";       G_ALERT="! ";   G_WARN="!"
  G_LOW="";       G_MED="";        G_HIGH="";      G_XHIGH="";     G_EFFORT=""
  G_THINK="think"; G_FAST="";      G_FABLE="* "
  G_CTX="ctx:";   G_COMPACT="compact:"; G_RESET="~"; G_UP="+";     G_DOWN="-"
  G_CACHE="cache:"; G_COST="";     G_DUR="dur:";   G_IN="in:";     G_OUT="out:"
  G_WORDS="words:"; G_ARR_UP="^";  G_ARR_DN="v";   G_LINES=""
  G_CPU="cpu:";   G_MEM="mem:";    G_DISK="disk:"
  G_BACK="< ";    G_GIT="git:";    G_PR="pr:";     G_TREE="wt:";   G_SESSION="name:"
  G_PR_DRAFT="draft "; G_PR_PENDING="review "; G_PR_CHANGES="changes "; G_PR_OK="approved "
  G_EMAIL="";     G_MCP="mcp:";    G_AGENTS="agents:"; G_DONE="ok:"; G_RESUME=""
  G_SVC="svc:";   G_SSH="";        G_CRON="";      G_PORTS="ports:"
else
  G_SEP="│";      G_DOT="·";       G_ALERT="⚠ ";   G_WARN="⚠️ "
  G_LOW="🟢";     G_MED="🟡";      G_HIGH="🟠";    G_XHIGH="🔴";   G_EFFORT="⚙️ "
  G_THINK="🧠";   G_FAST="⚡";     G_FABLE="✦ "
  G_CTX="📊 ";    G_COMPACT="🔄 "; G_RESET="↻";    G_UP="⇡";       G_DOWN="⇣"
  G_CACHE="🗄️ ";  G_COST="💰 ";    G_DUR="⏱️ ";    G_IN="📥 ";     G_OUT="📤 "
  G_WORDS="🔤 ";  G_ARR_UP="↑";    G_ARR_DN="↓";   G_LINES="📝 "
  G_CPU="🔥 ";    G_MEM="💾 ";     G_DISK="💽 "
  G_BACK="↖ ";    G_GIT="🌿 ";     G_PR="🔀 ";     G_TREE="🌳 ";   G_SESSION="🏷️ "
  G_PR_DRAFT="📝 "; G_PR_PENDING="👀 "; G_PR_CHANGES="🔴 "; G_PR_OK="✅ "
  G_EMAIL="🤖 ";  G_MCP="⚙️ ";     G_AGENTS="🤖 "; G_DONE="✓";     G_RESUME="♻️ "
  G_SVC="🛡️ ";    G_SSH="🔐 ";     G_CRON="⏰ ";   G_PORTS="🌐 "
fi
# Glyphs inside values the probes built — cached for AGENTLINE_PROBE_TTL, in
# the emoji spelling whatever the set — and inside the agent list are
# swapped here, at display time, so a change of set never replays the other
# set's glyphs from the probe cache. A failed service is noted first: the
# warning state reads the ✗.
_svc_bad=""
case "$svc_panel" in *✗*) _svc_bad=1 ;; esac
if [ "$_AL_GLYPHS" = ascii ]; then
  git_ab="${git_ab//↑/^}"; git_ab="${git_ab//↓/v}"
  git_dirty="${git_dirty//±/~}"; git_dirty="${git_dirty//✖/!}"
  svc_panel="${svc_panel//✓/ok}"; svc_panel="${svc_panel//✗/FAIL}"; svc_panel="${svc_panel//·//}"
  active_mcps="${active_mcps//·//}"
fi

# === Agent rows ===
# The 🤖 list, one entry per row (the layout pass prints it as a column at
# the right edge, or as rows under line 3), each in its worker's colour: the
# hue the worker's own brand uses, not bold, so a glance tells codex from a
# Hetzner run from Claude's own subagents. The worker is the label's first
# word, up to a "/" or a space: the classifier's codex/gpt-6-astra or
# arb/qwen3.6, or the first word of a --label or a script's own label
# ("codex round 1"). Rows the tracker hook marked are Claude's, whatever
# their text; anything this table does not know is a neutral grey. Each
# colour is "r;g;b" for the dark theme, then for light (at least 4.5:1 on
# white); mono strips them with every other colour. The same table sits in
# agentline-subagents.sh (WORKER_RGB), for the activity on a subagent row,
# and tests/run.sh checks that the two agree. A case: no fork.
# (worker colours)
_worker_rgb() {  # _worker_rgb <worker word> -> $_wrgb "r;g;b"
  case "$1" in
    claude)               _wrgb="217;119;87 176;78;44" ;;
    codex)                _wrgb="169;112;255 123;63;228" ;;
    agy|antigravity|gemini) _wrgb="66;133;244 26;99;214" ;;
    nvidia|nim|deepseek)  _wrgb="118;185;0 78;122;0" ;;
    hetzner)              _wrgb="213;12;45 192;10;40" ;;
    arb)                  _wrgb="43;181;168 15;118;110" ;;
    jev|jevk5)            _wrgb="240;107;168 191;47;110" ;;
    bayrak|ssh)           _wrgb="168;168;168 102;102;102" ;;
    *)                    _wrgb="168;168;168 102;102;102" ;;
  esac
  # (end of worker colours)
  if [ "$_AL_THEME" = light ]; then _wrgb="${_wrgb#* }"; else _wrgb="${_wrgb% *}"; fi
}
# $_ag_raw (the reader's "<kind><text>" lines) -> $_ag_rows, the coloured
# entries joined by $_GS, plus $active_agents and $agents_done, the plain
# texts, for --doctor and for local.sh (blank both to drop the segment).
# Each text is cleaned on its own, like every host-derived string (see
# "Display sanitization"). A finished one is green, the "+N" dim.
_ag_rows=""; active_agents=""; agents_done=""
_ag_nl=$'\n'
_ag_rest="$_ag_raw"
while [ -n "$_ag_rest" ]; do
  _ag_l="${_ag_rest%%"$_ag_nl"*}"
  case "$_ag_rest" in *"$_ag_nl"*) _ag_rest="${_ag_rest#*"$_ag_nl"}" ;; *) _ag_rest="" ;; esac
  _ag_k="${_ag_l:0:1}"; _ag_t="${_ag_l#?}"
  _clean _ag_t
  [ -n "$_ag_t" ] || continue
  case "$_ag_k" in
    d) _ag_e="\033[32m${G_DONE}${_ag_t}${RESET}"
       agents_done="${agents_done:+${agents_done} ${G_DOT} }${G_DONE}${_ag_t}" ;;
    n) _ag_e="${DIM}${_ag_t}${RESET}"
       active_agents="${active_agents:+${active_agents} ${G_DOT} }${_ag_t}" ;;
    c|e)
       _ag_w=claude
       [ "$_ag_k" = e ] && _ag_w="${_ag_t%%[/ ]*}"
       _worker_rgb "$_ag_w"
       _ag_e="\033[38;2;${_wrgb}m${_ag_t}${RESET}"
       active_agents="${active_agents:+${active_agents} ${G_DOT} }${_ag_t}" ;;
    *) continue ;;
  esac
  _ag_rows="${_ag_rows:+${_ag_rows}${_GS}}${G_AGENTS}${_ag_e}"
done

# === Number helpers ===
# A full render used to fork ~18 small awk/date programs (a colour here, a
# "%.1fk" there), ~60 ms of the payload-change path. The payload's numbers
# are plain decimals ("42", "42.5", "0012"), and for those bash arithmetic
# gives the same bytes: an integer part compared, a %.1f rounded the way awk
# rounds it. Anything else the parser lets through ("1e-05", a negative, a
# 16-digit part) takes the old awk line, so an odd value costs a fork, never
# a different output. bash has no floating point; 10# keeps a leading zero
# from reading as octal.
#
# _num_ge <number> <int>: 0 when number >= int, 1 when not, 2 when number is
# no plain non-negative decimal (the caller then asks awk). For an integer
# threshold, p >= h exactly when p's integer part is — for the decimal. awk
# compares the double nearest it, and a fraction of enough nines rounds up
# to the next integer there: "79.999999999999999" is 80.0, red and ⚠️. So a
# fraction starting with 9s whose integer digits and leading 9s reach 13
# goes to awk too. That is further than a double's ~16 digits need (a 9 in
# the 13th significant place is the earliest a 15-digit integer part can
# round up at), so every value where the two could differ takes awk.
_num_ge() {
  local i f z
  case "$1" in ''|*[!0123456789.]*|*.*.*|.*|*.) return 2 ;; esac
  i="${1%%.*}"
  [ ${#i} -le 15 ] || return 2
  case "$1" in
    *.9*)
      f="${1#*.}"; f="${f%%[!9]*}"
      z="${i#"${i%%[!0]*}"}"
      [ $(( ${#z} + ${#f} )) -ge 13 ] && return 2 ;;
  esac
  [ $(( 10#$i )) -ge "$2" ]
}
# _tenths <int> <unit: 1000|1000000> -> $_tenths_out, what awk's
# printf "%.1f", n/unit prints. Off a tie the integer rounding is the
# decimal one. On a decimal tie (n/unit = x.x5 = m/20, m odd) awk rounds
# the double nearest m/20, so the direction is that double's: m/20 lies in
# [2^e, 2^(e+1)), its 53-bit significand is m*2^(50-e)/5, and the fraction
# (m*2^(50-e) mod 5)/5 below or above one half says whether the double
# sits under or over the tie (2^k mod 5 cycles 1 2 4 3). A multiple of 5
# is exact in binary (1.25) and printf rounds it half to even.
_tenths() {
  local n="$1" q=$(( $2 / 10 )) t r m e=0 p
  t=$(( n / q )); r=$(( n % q ))
  if [ "$r" -gt $(( q / 2 )) ]; then
    t=$(( t + 1 ))
  elif [ "$r" -eq $(( q / 2 )) ]; then
    m=$(( 2 * t + 1 ))
    if [ $(( m % 5 )) = 0 ]; then
      [ $(( t % 2 )) = 1 ] && t=$(( t + 1 ))
    else
      while [ $(( 20 << (e + 1) )) -le "$m" ]; do e=$(( e + 1 )); done
      case $(( (50 - e) % 4 )) in 0) p=1 ;; 1) p=2 ;; 2) p=4 ;; *) p=3 ;; esac
      [ $(( m % 5 * p % 5 )) -ge 3 ] && t=$(( t + 1 ))
    fi
  fi
  _tenths_out="$(( t / 10 )).$(( t % 10 ))"
}

# Where the built-in is defined, file and line: after local.sh, a color_pct
# defined anywhere else is an override (see below).
_CP_WHERE="color_pct $(( LINENO + 1 )) ${BASH_SOURCE[0]-}"
color_pct() {
  local p="$1" high="${2:-90}" mid="${3:-70}"
  awk -v p="$p" -v h="$high" -v m="$mid" 'BEGIN {
    if (p >= h) printf "\033[1;31m";
    else if (p >= m) printf "\033[1;33m";
    else printf "\033[1;32m";
  }'
}
# _color_pct <pct> <high> <mid> -> $c. color_pct is a documented local.sh
# override (see "Local overrides"), so it stays the function every colour
# comes from when replaced; the check after local.sh asks bash where it is
# defined now. The built-in's answer is worked out here instead, with no
# subshell and no awk, for a plain decimal and thresholds.
_color_pct() {
  local r
  if [ "$_cp_own" != 1 ]; then c=$(color_pct "$@"); return; fi
  case "$2$3" in *[!0123456789]*|'') c=$(color_pct "$@"); return ;; esac
  _num_ge "$1" "$2"; r=$?
  [ "$r" = 2 ] && { c=$(color_pct "$@"); return; }
  if [ "$r" = 0 ]; then c=$'\033[1;31m'
  elif _num_ge "$1" "$3"; then c=$'\033[1;33m'
  else c=$'\033[1;32m'
  fi
}

# === Local overrides ===
# install.sh replaces this script on every upgrade, so edits made to it are
# lost (the replaced copy is kept as agentline.sh.bak-*, but that is a
# recovery path, not a workflow). Tweaks belong in a file install.sh never
# touches, sourced here: after the payload parse, the host probes and the
# colours, before any line is assembled. It can redefine a colour, blank a
# variable to drop its segment (`cpu_usage=`), or replace color_pct. This is
# the slow path only — a cache-hit tick has exited long before — so it costs
# one `[ -f ]` per full render and nothing per second; an edit shows up within
# AGENTLINE_CACHE_TTL.
AGENTLINE_LOCAL="${AGENTLINE_LOCAL:-$HOME/.claude/agentline/local.sh}"

# Custom segments. local.sh calls `agentline_seg <name> <content>` to add
# one: a segment named local:<name> for AGENTLINE_LAYOUT and AGENTLINE_DROP,
# placed at the end of line 4 (the system layer) in the default layout, in
# call order. The name is 1-24 of a-z 0-9 _ - (anything else is ignored,
# so a typo cannot inject a layout separator); a second call with a name
# already given is ignored, as is empty content. It is laid out, measured
# and cached like every segment, and costs nothing per second: local.sh only
# runs on a full render.
#
# The content is often read from a file (a VPN state, a build status) that
# something else writes, and it goes through printf %b like the rest of the
# line. So colour is the one thing kept: an SGR sequence ESC [ digits ; m,
# in any spelling printf %b would turn into one (the _mono_strip list), is
# rewritten as "\033[...m"; every other control character, C1 byte and
# backslash goes, as _clean does to host strings. An OSC or a cursor move
# is left as harmless text at worst. mono strips the kept SGR later, with
# every other colour.
#
# Bounded and one pass. The first version searched the whole remaining text
# for each of the nine spellings at every escape it found, which grows with
# the square of the input and worse in a UTF-8 locale, where every pattern
# match decodes the string again: 4.8 KB of coloured text cost 1.2 s a full
# render, 27 KB of "\033[2J" 152 s. A segment is a few words, so the text is
# cut to 512 characters first; then each step jumps to the next backslash or
# ESC (every spelling starts with one), checks the spellings as prefixes
# there, and moves on.
_LSEGS=""; _LNAMES=""
_LSEG_STOP=$'[\\\\\033]'   # the pattern [\<ESC>]
_lseg_clean() {  # _lseg_clean <text> -> $_lseg_out
  local rest="${1:0:512}" o="" e hit pre par t
  while :; do
    pre="${rest%%$_LSEG_STOP*}"
    t="$pre"; _clean t; o="${o}${t}"
    [ ${#pre} -eq ${#rest} ] && break
    rest="${rest:${#pre}}"
    hit=""
    for e in '\033[' '\0033[' '\33[' '\e[' '\E[' '\x1b[' '\x1B[' '\u001b[' '\u001B[' $'\033['; do
      case "$rest" in "$e"*) hit="$e"; break ;; esac
    done
    # A backslash or ESC that starts no spelling is dropped, as _clean drops
    # it; the text after it is text.
    if [ -z "$hit" ]; then rest="${rest:1}"; continue; fi
    rest="${rest:${#hit}}"
    # Kept only when an m ends it and all before the m is digits and ";"
    # (32 at most); otherwise the escape spelling is dropped, the rest kept.
    par="${rest%%m*}"
    case "$rest" in
      *m*) case "$par" in
             *[!0123456789\;]*) ;;
             *) [ ${#par} -le 32 ] && { o="${o}\\033[${par}m"; rest="${rest#*m}"; } ;;
           esac ;;
    esac
  done
  _lseg_out="$o"
}
agentline_seg() {  # agentline_seg <name> <content> — for local.sh
  case "${1-}" in
    ''|*[!abcdefghijklmnopqrstuvwxyz0123456789_-]*) return 0 ;;
  esac
  [ ${#1} -le 24 ] || return 0
  case ",$_LNAMES," in *",local:$1,"*) return 0 ;; esac
  _lseg_clean "${2-}"
  # Colour alone is no segment: "\e[8m" made a blank one whose colour ran
  # on into the separator. Some text must be left once the SGR is gone, and
  # a coloured segment ends with a reset, closed or not. Every SGR kept is
  # the canonical \033[...m by now, so taking them out is simple.
  local t="$_lseg_out"
  while :; do
    case "$t" in *'\033['*) ;; *) break ;; esac
    t="${t%%'\033['*}${t#*'\033['*m}"
  done
  case "$t" in *[![:space:]]*) ;; *) return 0 ;; esac
  case "$_lseg_out" in *'\033['*) _lseg_out="${_lseg_out}\\033[0m" ;; esac
  _LNAMES="${_LNAMES:+${_LNAMES},}local:$1"
  _LSEGS="${_LSEGS}local:$1${_US}${_lseg_out}${_RS}"
  return 0
}

# Is color_pct still the built-in? Without a local.sh it is. With one, bash
# says where the function now in force was defined (extdebug makes
# `declare -F` print its line and file): anything but this file at the
# built-in's line is an override, and every colour is asked of it (see
# _color_pct). That is one fork, for local.sh users only. The check used to
# call color_pct and see whether the built-in's flag got set, which took a
# local.sh wrapper around the built-in (`eval "_orig_$(declare -f
# color_pct)"`, then a color_pct that calls _orig_color_pct) for the
# built-in, and ignored it — and it ran the user's function in this shell.
_cp_own=1
if [ -f "$AGENTLINE_LOCAL" ]; then
  . "$AGENTLINE_LOCAL"
  [ "$(shopt -s extdebug; declare -F color_pct 2>/dev/null)" = "$_CP_WHERE" ] || _cp_own=0
fi

# === Format Helpers ===
effort=""
case "$effort_raw" in
  low)    effort="${G_LOW}${DIM}low${RESET}" ;;
  medium) effort="${G_MED}${CYAN}med${RESET}" ;;
  high)   effort="${G_HIGH}${ORANGE}high${RESET}" ;;
  # The /effort scale runs low < medium < high < xhigh < max, with ultracode
  # as a side mode (xhigh + workflows). The payload reports ultracode as plain
  # "xhigh"; the only place the distinction survives is the session transcript,
  # which records an "ultra_effort_enter"/"ultra_effort_exit" attachment when
  # the mode toggles and a "Set effort level to <level>" line on each /effort.
  # Scan it backwards: the most recent marker tells the current state. Escaped
  # quotes in message text can never match the raw-JSON pattern, so quoting
  # these strings in conversation does not false-positive.
  xhigh)
    ultracode=""
    tp="$payload_transcript"
    if [ ! -f "$tp" ] && [ -n "$session_id" ]; then
      # The one sed left in the user's locale, as Claude Code names the
      # directory: one "-" per character (per UTF-16 unit), which the C
      # locale would make one per byte. stderr: BSD sed rejecting a cwd that
      # is not UTF-8 — the transcript is then simply not found.
      tp="$HOME/.claude/projects/$(printf '%s' "$cwd" | sed 's|[^a-zA-Z0-9]|-|g' 2>/dev/null)/${session_id}.jsonl"  # locale-ok
    fi
    if [ -f "$tp" ]; then
      marker=$(revcat "$tp" | LC_ALL=C grep -m1 -oE '"attachment":\{"type":"ultra_effort_(enter|exit)"|<local-command-stdout>Set effort level to [a-z]+')
      case "$marker" in
        *ultra_effort_enter*|*"to ultracode") ultracode=1 ;;
      esac
    fi
    if [ -n "$ultracode" ]; then
      # Mirrors the /effort picker's violet-ripple, rotated one wheel step
      # per tick by _anim_frame/_VIOLET_WHEEL above instead of a single
      # frozen frame. Token substituted at print time, same as $CLOCK_TOKEN.
      effort="$ANIM_ULTRA_TOKEN"
    else
      effort="${G_XHIGH}${RED}xhigh${RESET}"
    fi ;;
  # max mirrors the picker's rainbow-animated look with a live-ticking wheel.
  max)    effort="$ANIM_MAX_TOKEN" ;;
  *)      [ -n "$effort_raw" ] && effort="${G_EFFORT}$effort_raw" ;;
esac
# mono: an animation is only colour, so the word is printed as it is.
if [ "$_AL_THEME" = mono ]; then
  case "$effort" in
    "$ANIM_MAX_TOKEN")   effort=max ;;
    "$ANIM_ULTRA_TOKEN") effort=ultracode ;;
  esac
fi

# printf -v: the same builtin the $(printf ...) ran, without its subshell.
cost_fmt=""
[ -n "$cost" ] && printf -v cost_fmt "%.2f" "$cost"

# awk's printf "%d", ms/1000 truncates toward zero, as bash's integer
# division of the integer part does (12 digits: past that the double awk
# divides in can no longer hold the fraction, and awk answers). The same
# goes for more than 15 significant digits in all: awk reads the double
# nearest the string, and "59999.99999999999999" is 60000.0 there, 1m, where
# the integer part alone says 0m. Such a value is awk's. A negative is
# negated only once there is a value: a 13-digit one used to negate the
# empty string into "0" and skip awk (0m where awk said -31m).
duration_fmt=""
if [ -n "$duration_ms" ]; then
  total_sec=""
  _i="${duration_ms#-}"; _i="${_i%%.*}"
  _f=""; case "$duration_ms" in *.*) _f="${duration_ms#*.}" ;; esac
  _z="${_i#"${_i%%[!0]*}"}"
  case "$duration_ms" in
    *[!0123456789.-]*|?*-*|*.*.*|-|-.*|.*|*.) ;;
    *) [ -n "$_i" ] && [ ${#_i} -le 12 ] && [ $(( ${#_z} + ${#_f} )) -le 15 ] && total_sec=$(( 10#$_i / 1000 ))
       [ -n "$total_sec" ] && case "$duration_ms" in -*) total_sec=$(( -total_sec )) ;; esac ;;
  esac
  [ -z "$total_sec" ] && total_sec=$(awk -v ms="$duration_ms" 'BEGIN {printf "%d", ms/1000}')
  h=$((total_sec / 3600))
  m=$(((total_sec % 3600) / 60))
  [ $h -gt 0 ] && duration_fmt="${h}h${m}m" || duration_fmt="${m}m"
fi

# format_tokens <n> <var>: "8.4m", "12.3k" or n as it came, into <var>. A
# token count is an integer; any other spelling is awk's, as before.
format_tokens() {
  local n="$1" _v
  if [ -z "$n" ]; then _v=""
  elif case "$n" in *[!0123456789]*) false ;; *) [ ${#n} -le 15 ] ;; esac; then
    if [ $(( 10#$n )) -ge 1000000 ]; then _tenths $(( 10#$n )) 1000000; _v="${_tenths_out}m"
    elif [ $(( 10#$n )) -ge 1000 ]; then _tenths $(( 10#$n )) 1000; _v="${_tenths_out}k"
    else _v="$n"
    fi
  elif awk -v n="$n" 'BEGIN {exit !(n >= 1000000)}'; then _v=$(awk -v n="$n" 'BEGIN {printf "%.1fm", n/1000000}')
  elif awk -v n="$n" 'BEGIN {exit !(n >= 1000)}'; then _v=$(awk -v n="$n" 'BEGIN {printf "%.1fk", n/1000}')
  else _v="$n"
  fi
  printf -v "$2" '%s' "$_v"
}
format_tokens "$tokens_in" tokens_in_fmt
format_tokens "$tokens_out" tokens_out_fmt

# bash >= 4.2 formats an epoch itself: printf's %(fmt)T is strftime under
# the same TZ as date (AGENTLINE_TZ is exported before this, and bash's
# own getenv hands TZ to localtime). Older bash (macOS 3.2) keeps date.
_ptime=0
case "${BASH_VERSINFO[0]:-0}.${BASH_VERSINFO[1]:-0}" in
  [5-9].*|[1-9][0-9]*.*|4.[2-9]*|4.[1-9][0-9]*) _ptime=1 ;;
esac

# fmt_reset <ts>: -> $_reset_out. A countdown for an epoch; a string that
# is not one goes to date, which formats what it can (nothing, mostly).
fmt_reset() {
  local ts="$1" diff h m
  _reset_out=""
  [ -z "$ts" ] && return
  case "$ts" in
    *[!0-9]*) _reset_out=$(fmt_epoch "$ts" "%H:%M"); return ;;
  esac
  # $_now_epoch is already set (_tick_now, at startup): a `date +%s` here
  # was one more fork on every full render for a number the script had.
  diff=$(( ts - _now_epoch ))
  [ "$diff" -le 0 ] && return
  h=$((diff / 3600)); m=$(((diff % 3600) / 60))
  if [ $h -gt 0 ]; then _reset_out="${h}h${m}m"; else _reset_out="${m}m"; fi
}
# fmt_reset_week <ts> -> $_reset_out: "5/10", the day and month of <ts>.
# Zero-padded %d/%m is the only form both GNU and BSD date support (the
# GNU-only %-d no-pad flag breaks on macOS); the padding is stripped after,
# as the sed that used to do it did: the first character when it is 0, and
# the 0 after the slash. printf %()T takes an epoch of up to 11 digits
# here; any other spelling goes to date as before.
fmt_reset_week() {
  local ts="$1" d
  _reset_out=""
  [ -z "$ts" ] && return
  case "$_ptime:$ts" in
    1:*[!0-9]*|1:????????????*) d=$(fmt_epoch "$ts" "%d/%m") ;;
    1:*) printf -v d '%(%d/%m)T' "$(( 10#$ts ))" ;;
    *)   d=$(fmt_epoch "$ts" "%d/%m") ;;
  esac
  d="${d#0}"
  case "$d" in *"/0"*) d="${d%%/0*}/${d#*/0}" ;; esac
  _reset_out="$d"
}
fmt_reset "$five_hour_reset"; five_hour_reset_fmt="$_reset_out"
fmt_reset_week "$seven_day_reset"; seven_day_reset_fmt="$_reset_out"

# Pace: "S:60%" says nothing on its own — at 30 minutes to the reset it is
# plenty of room, at 4 hours to go it is a wall. The window started
# resets_at − window_len ago (the 5-hour window opens at first use, the week
# is rolling), so elapsed% is known and used% − elapsed% says whether usage
# runs ahead of the clock: ⇡12% = burning 12 points faster than a flat pace
# (yellow from 5, red from 15), ⇣12% = that much headroom (dim — good news
# needs no colour). Within ±5 there is nothing to say and nothing is shown.
#
# It sits beside the percentage, never instead of its colour: 92% used at 96%
# elapsed is a dim ⇣4 at best, yet the wall is 8 points away, so the absolute
# 90/70 colour on S:/W: stays as it was.
#
# Only a window proven to be this one gets an arrow: resets_at all digits
# (an ISO string, which fmt_reset still formats, gets none) and 0 < resets −
# now <= the window — a reset already past, or further off than a window
# lasts, is a stale or foreign number. And none early on: in the first
# <min_elapsed>% of a window (30 min of 5 h, ~5 h of 7 d) a single prompt is
# a large positive delta that means nothing.
#
# Pure bash arithmetic on $_now_epoch, returned in $_pace_out rather than
# printed: no subshell, no awk (color_pct forks one), so the pace costs no
# fork. used% is a float ("80.9"), rounded with the same `printf %.0f` that
# prints S:/W: (the builtin's -v form, no subshell), so "S:81%" never sits
# beside an arrow worked out from 80. A used% past 100 is no window this
# one can be in: garbage input, which printed ⇡999999999999949% and is now
# simply given no arrow. AGENTLINE_PACE=0 turns it off.
pace_arrow() {  # pace_arrow <used%> <resets_epoch> <window_secs> <min_elapsed%> -> $_pace_out
  local u="$1" ts="$2" win="$3" rem el d
  _pace_out=""
  [ "${AGENTLINE_PACE:-1}" = 0 ] && return
  case "$u" in ''|-*|*[!0-9.]*|*.*.*|.*|*.) return ;; esac
  printf -v u '%.0f' "$u" 2>/dev/null || return
  case "$u" in ''|*[!0-9]*) return ;; esac
  [ ${#u} -le 3 ] && [ "$u" -le 100 ] || return
  case "$ts" in ''|*[!0-9]*) return ;; esac
  # Ten digits is an epoch until 2286; anything longer would only overflow.
  [ ${#ts} -gt 12 ] && return
  rem=$(( ts - _now_epoch ))
  [ "$rem" -gt 0 ] && [ "$rem" -le "$win" ] || return
  el=$(( (win - rem) * 100 / win ))
  [ "$el" -ge "$4" ] || return
  d=$(( 10#$u - el ))  # 10#: a "08" is decimal, not bad octal
  if [ "$d" -ge 15 ]; then _pace_out="${RED}${G_UP}${d}%${RESET}"
  elif [ "$d" -ge 5 ]; then _pace_out="${YELLOW}${G_UP}${d}%${RESET}"
  elif [ "$d" -le -5 ]; then _pace_out="${DIM}${G_DOWN}$(( -d ))%${RESET}"
  fi
}

# === Compaction ===
# How many times this session's context has been compacted: "🔄 2" on line
# 1, hidden at 0. Claude Code writes one line per compaction into the
# session transcript — {"type":"system","subtype":"compact_boundary",
# "compactMetadata":{"trigger":…,"preTokens":…,"postTokens":…}} — and a
# session keeps the same .jsonl across compactions, so the count of those
# lines is the session's count. No hook: a PreCompact hook fires before the
# compaction (and for one that then fails), and would be one more opt-in
# install step for a number the transcript already holds. The schema is
# undocumented, so the segment fails silent: no match, no segment. Quoted in
# a message, the pattern arrives with escaped quotes and cannot match.
#
# A transcript runs to tens of MB; grepping it whole on every full render
# cost ~0.15 s. So the count is kept in ${CACHE_DIR}/compact.<sid> as
# "inode offset count postTokens" and only the bytes past the offset are
# read: the same size costs one stat and no read, growth costs one tail|awk
# over the new bytes (8 MB at most, see _CMP_CAP), and a new inode or a
# smaller file (rewritten, rotated) starts again from 0. The cache is written through a temp file and mv, so
# two renders racing never leave half a line. A line caught mid-write is
# left for the next render (see _compact_scan), never counted in halves. The payload's
# transcript_path only — the path guess the ultracode probe falls back to
# costs a sed per render, for a Claude Code too old to have compaction
# metadata anyway — and only with a trusted cache directory: without one
# every render would be a full scan.
#
# postTokens of the last compaction backs one estimate. Right after /compact
# the payload's used_percentage is null until the next API call, and the
# context segment hides; with a count > 0 and a known window size it shows
# a dim "📊 ~6%" (postTokens / window) instead, until the real figure is
# back. The last postTokens rides the same pass that counts. The estimate
# needs the compaction to be the latest thing that happened: no assistant
# turn in the transcript after the last boundary. A resumed session whose
# payload carries a null used_percentage, compacted hours before and busy
# since, used to show that old postTokens as its context. Only an assistant
# line ends it, not just any line: Claude Code follows the boundary with
# the summary itself (a user line) and /compact's own command output, and a
# prompt typed before the next response does not move the figure much.
# -L: a transcript_path that is a symlink is measured by its target. Without
# it stat read the link itself, whose size never changes, and the counter
# stayed at 0 however many compactions the target recorded.
if [ "$OS" = Darwin ]; then _stat_is() { stat -L -f '%i %z' -- "$1" 2>/dev/null; }
else _stat_is() { stat -L -c '%i %s' -- "$1" 2>/dev/null; }
fi
# Bytes [from, to) of the transcript, never past the size stat saw: a file
# still growing between the stat and the read would otherwise hand the next
# render bytes this one already counted.
_compact_chunk() {  # _compact_chunk <from> <to>
  if [ "$1" = 0 ]; then head -c "$2" "$payload_transcript" 2>/dev/null
  else tail -c "+$(( $1 + 1 ))" "$payload_transcript" 2>/dev/null | head -c "$(( $2 - $1 ))"
  fi
}
# One pass over the chunk: "<boundaries> <bytes consumed> <fresh> <last
# postTokens>". <fresh> is 1 when the chunk's last boundary has no assistant
# turn after it, 0 when an assistant turn is the later of the two, "-" when
# the chunk holds neither (no news: the stored state stands); see the
# estimate under "Compaction".
# It used to be two (grep -c, then grep|grep|tail for the postTokens), so the
# first scan of a big transcript read it twice. awk under C: length() counts
# bytes, and no awk aborts on an invalid one.
#
# Only whole lines are consumed. A chunk can end inside a line — one Claude
# Code is still writing, or the 8 MB cap — and the offset used to move past
# it anyway: a boundary line cut inside its "subtype" matched in neither
# read and was lost for good (3 counted where the transcript held 4). So the
# unterminated tail is handed back, uncounted, and the next render reads it
# again from its first byte. awk cannot see whether its last record had a
# newline, but the byte sum can: every record adds length + 1, so a sum one
# past the chunk's length means the last one had none. A sum that fits
# neither (an awk that stops a record at a NUL byte) takes the chunk whole,
# as does a full-cap chunk with no newline at all, which could otherwise
# never be got past.
_compact_scan() {  # _compact_scan <from> <to>
  _compact_chunk "$1" "$2" | LC_ALL=C awk -v len="$(( $2 - $1 ))" -v cap="$_CMP_CAP" '
    BEGIN { st = "-" }
    {
      ln = length($0) + 1; b += ln; pp = p; pst = st; m = 0
      if (index($0, "\"subtype\":\"compact_boundary\"")) {
        m = 1; n++; st = 1
        if (match($0, /"postTokens":[0-9]+/)) p = substr($0, RSTART + 13, RLENGTH - 13)
      } else if (index($0, "\"type\":\"assistant\"")) st = 0
    }
    END {
      if (b == len + 1) { b -= ln; st = pst; if (m) { n--; p = pp } }
      else if (b != len) b = len
      if (b == 0 && len >= cap) b = len
      print n + 0, b + 0, st, p
    }'
}
# At most this many bytes are read per render. The first scan used to take
# the whole file at once: a 4 GB sparse transcript held a render for 5.3 s,
# and a render killed that long (Claude Code cancels slow ones) never wrote
# the cache, so every render after it started the same scan again. Now each
# render reads the next 8 MB and records how far it got; a big transcript is
# caught up over a few renders, its count rising as it goes.
_CMP_CAP=8388608
compact_n=0; compact_post=""; compact_fresh=0
if [ -n "$CACHE_BASE" ] && [ -n "$payload_transcript" ] && [ -f "$payload_transcript" ]; then
  _cst=$(_stat_is "$payload_transcript")
  _ino="${_cst%% *}"; _size="${_cst#* }"
  case "$_ino$_size" in
    ''|*[!0-9]*) ;;
    *)
      _cfile="${CACHE_DIR}/compact.${_sid}"
      _c_ino=""; _c_size=""; _c_n=""; _c_fresh=""; _c_post=""
      [ -f "$_cfile" ] && read -r _c_ino _c_size _c_n _c_fresh _c_post < "$_cfile"
      case "$_c_ino$_c_size$_c_n" in ''|*[!0-9]*) _c_ino="" ;; esac
      # The fresh flag is the fifth field since H0g; a four-field cache from
      # before (its fourth field a postTokens, or nothing) is rebuilt.
      case "$_c_fresh" in 0|1) ;; *) _c_ino="" ;; esac
      case "$_c_post" in *[!0-9]*) _c_post="" ;; esac
      if [ -n "$_c_ino" ] && [ "$_c_ino" = "$_ino" ] && [ "$_c_size" = "$_size" ]; then
        compact_n="$_c_n"; compact_post="$_c_post"; compact_fresh="$_c_fresh"
      else
        if [ -n "$_c_ino" ] && [ "$_c_ino" = "$_ino" ] && [ "$_size" -gt "$_c_size" ]; then
          # only what was appended
          _from="$_c_size"; compact_n="$_c_n"; compact_post="$_c_post"; compact_fresh="$_c_fresh"
        else
          _from=0; compact_n=0; compact_post=""; compact_fresh=0  # new or rewritten file: all of it
        fi
        _to=$(( _from + _CMP_CAP )); [ "$_to" -gt "$_size" ] && _to="$_size"
        _new=0; _adv=""; _fr=""; _p=""
        read -r _new _adv _fr _p <<< "$(_compact_scan "$_from" "$_to")"
        case "$_fr" in 0|1) compact_fresh="$_fr" ;; esac
        case "$_new" in ''|*[!0-9]*) _new=0 ;; esac
        case "$_p" in *[!0-9]*) _p="" ;; esac
        # No answer at all (awk missing, killed) consumes nothing and counts
        # nothing: the next render tries the same bytes again.
        case "$_adv" in ''|*[!0-9]*|?????????????*) _adv=0; _new=0 ;; esac
        [ "$_adv" -gt $(( _to - _from )) ] && _adv=$(( _to - _from ))
        compact_n=$(( 10#$compact_n + _new ))
        [ "$_new" -gt 0 ] && [ -n "$_p" ] && compact_post="$_p"
        # The "size" field is how far the scan got, not the file's size:
        # short of it, the next render carries on from there.
        printf '%s %s %s %s %s\n' "$_ino" "$(( _from + _adv ))" "$compact_n" "$compact_fresh" "$compact_post" > "${_cfile}.$$" 2>/dev/null \
          && mv -f "${_cfile}.$$" "$_cfile" 2>/dev/null
      fi
      ;;
  esac
fi

thinking_icon=""
[ "$thinking" = "True" ] && thinking_icon="$G_THINK"

fast_icon=""
[ "$fast" = "True" ] && fast_icon="${G_FAST}Fast"

# === Model Color ===
model_color="$CYAN"
# Truecolor amber→orange gradient across the model name. It is coloured per
# character, which bash cannot do reliably: under C/POSIX (common on servers)
# ${s:i:1} is a byte, and slicing "✦" put escapes between its three bytes. So
# the name is only marked here and the layout pass, a python3 that runs on
# every full render anyway, paints it (see gradient() there). This used to be
# a python3 of its own — ~20 ms of interpreter start on each render of a
# Fable session. The markers carry \x02 like the placeholders above, so no
# cleaned payload string can open or close one.
GRAD_OPEN="@@${_AL_TOK}AGENTLINE_GRAD@@"
GRAD_CLOSE="@@${_AL_TOK}AGENTLINE_GRAD_END@@"
case "$model_raw" in
  claude-fable*|claude-mythos*)
    if [ "$_AL_THEME" = mono ]; then model="${G_FABLE}${model}"
    else model="${GRAD_OPEN}${G_FABLE}${model}${GRAD_CLOSE}"
    fi
    model_color="" ;;
  claude-opus*)  model_color="$MAGENTA" ;;
  claude-sonnet*) model_color="$CYAN" ;;
  claude-haiku*) model_color="$GREEN" ;;
esac

lines_fmt=""
if [ -n "$lines_added" ] || [ -n "$lines_removed" ]; then
  lines_fmt="${GREEN}+${lines_added:-0}${RESET} ${RED}-${lines_removed:-0}${RESET}"
fi

# LC_ALL=C pins the day abbreviation to English regardless of the host locale.
# printf %()T (bash >= 4.2) formats in the shell's locale instead, so it is
# asked for the weekday as a number and the C locale's name is looked up.
if [ "$_ptime" = 1 ]; then
  printf -v date_str '%(%d/%m/%Y %w)T' -1
  case "${date_str##* }" in
    0) _wd=Sun ;; 1) _wd=Mon ;; 2) _wd=Tue ;; 3) _wd=Wed ;; 4) _wd=Thu ;; 5) _wd=Fri ;; *) _wd=Sat ;;
  esac
  date_str="${date_str% *} $_wd"
else
  date_str=$(LC_ALL=C date "+%d/%m/%Y %a")
fi
# The clock is rendered as a placeholder so the cached line can be re-stamped
# with the live time on every tick; it is substituted just before printing.
time_str="$CLOCK_TOKEN"

# Word counts from hook
words_in_w=""
words_out_w=""
# The hook writes one line, "<in> <out>", read with the `read` builtin. Any
# other shape (a second line, a count that is not an integer) keeps the old
# cat/awk path, whose output it is.
_words_fmt() {  # _words_fmt <count> <var>: "%.1fk" from 1000, else "%d", as awk printed
  local n="$1" _v=""
  if [ -n "$n" ] && [ "$n" != 0 ]; then
    case "$n" in
      *[!0123456789]*|????????????????*)
        _v=$(awk -v n="$n" 'BEGIN { if (n >= 1000) printf "%.1fk", n/1000; else printf "%d", n }') ;;
      *) if [ $(( 10#$n )) -ge 1000 ]; then _tenths $(( 10#$n )) 1000; _v="${_tenths_out}k"
         else _v=$(( 10#$n ))
         fi ;;
    esac
  fi
  printf -v "$2" '%s' "$_v"
}
if [ -f "$WC_FILE" ]; then
  wi=""; wo=""; _wx=""
  { IFS=$' \t' read -r wi wo _; IFS= read -r _wx && _wx=1; } 2>/dev/null < "$WC_FILE"
  if [ -n "$_wx" ]; then
    wc_line=$(cat "$WC_FILE")
    wi=$(echo "$wc_line" | awk '{print $1}')
    wo=$(echo "$wc_line" | awk '{print $2}')
  fi
  _words_fmt "$wi" words_in_w
  _words_fmt "$wo" words_out_w
fi

# === Hyperlinks ===
# The PR number and the repository are OSC-8 links: click (or cmd-click) to
# open them. No terminal allowlist: Claude Code decides itself whether its
# terminal takes hyperlinks (FORCE_HYPERLINK overrides it), so a second
# guess here would only go stale. Two cases are known not to work and get
# plain text: a multiplexer between Claude Code and the terminal (tmux,
# screen, zellij strip or mangle the sequence) and AGENTLINE_LINKS=0.
#
# BEL terminates, not ESC \: the text goes through printf %b, where "\a"
# is BEL and a backslash inside the ST form would need escaping of its own.
# The URLs were checked where they were made (https, no controls, no
# backslash). The layout pass strips the sequences before measuring widths.
_links=1
[ "${AGENTLINE_LINKS:-1}" = 0 ] && _links=0
[ -n "${TMUX-}${STY-}${ZELLIJ-}" ] && _links=0
_link() {  # _link <url> <text> -> $_link_out, the text alone when links are off
  if [ "$_links" = 1 ] && [ -n "$1" ]; then
    _link_out="\033]8;;${1}\a${2}\033]8;;\a"
  else
    _link_out="$2"
  fi
}

# === Build Output ===
P=" ${DIM}${G_SEP}${RESET} "

# Every segment is emitted as a named record instead of being appended to a
# fixed line: the layout pass at the end ("Layout") decides which line each
# one lands on, in what order, and — at narrow widths — which ones give way.
# One flat string rather than an associative array, which bash 3.2 (the macOS
# /bin/bash) does not have; a function call, not a fork. The names are the
# AGENTLINE_LAYOUT vocabulary. An empty text is no segment at all.
SEGS=""
_seg() { [ -n "$2" ] && SEGS="${SEGS}$1${_US}$2${_RS}"; return 0; }
# Segments shown in their warning state (a red disk ⚠️, a cold or expiring
# prompt cache, a failed service): the layout pass never drops these, or
# fit mode would hide a warning exactly when the terminal is narrow — a
# 95% disk at COLUMNS=100 used to lose its ⚠️ silently, where before fit
# mode the line wrapped and kept it.
_WARNED=""

# Line 1: model first, then stats. A payload that did not decode leads with a
# dim marker instead of silently losing the model and context segments; it is
# prepended, not a replacement, because the host and session-independent
# segments after it are still correct. The layout pass puts it at the front
# of the first line whatever the layout, and never drops it.
[ -n "$payload_err" ] && _seg warn "${DIM}${G_ALERT}payload${RESET}"
if [ -n "$model" ]; then
  _seg model "${model_color}${model}${thinking_icon:+ ${thinking_icon}}${RESET}"
fi
_seg effort "$effort"
[ -n "$fast_icon" ] && _seg fast "${YELLOW}${fast_icon}${RESET}"
if [ -n "$used_pct" ]; then
  _color_pct "$used_pct" 80 60
  ctx_icon="$G_CTX"
  ctx_tag=""
  _num_ge "$used_pct" 80; _r=$?
  [ "$_r" = 2 ] && { awk -v p="$used_pct" 'BEGIN {exit !(p >= 80)}'; _r=$?; }
  [ "$_r" = 0 ] && ctx_icon="$G_WARN"
  # Past 200k tokens on a larger window the percentage keeps its own 60/80
  # colours. exceeds_200k_tokens is only Claude Code's fixed-threshold flag,
  # and this segment used to turn it into a yellow ⚠️ at 20-25% on the 1M
  # models, on the premise that pricing and quality change at 200k. That
  # held for the Sonnet 4/4.5 1M beta; Opus 4.7 and later and the other
  # current 1M-context models bill every token at the standard rate, with
  # no long-context premium, and are documented to stay strong across the
  # window, so the alarm said nothing true. A big context still costs more
  # per turn, but only because each request carries more tokens, and the
  # percentage already shows that. What is left is a small dim ">200k"
  # after it, opt-in with AGENTLINE_TAG_200K=1, for anyone who wants to see
  # the flag. The parser has already ignored it on a 200k window, where it
  # is just "about 100%" again.
  [ -n "$warn_200k" ] && [ "${AGENTLINE_TAG_200K:-0}" = 1 ] && ctx_tag=" ${DIM}>200k${RESET}"
  printf -v _pct '%.0f' "$used_pct"
  _seg ctx "${c}${ctx_icon}${_pct}%${RESET}${ctx_tag}"
elif [ "$compact_n" -gt 0 ] && [ -n "$compact_post" ] && [ "$compact_fresh" = 1 ]; then
  # Just compacted, and the payload has no figure until the next API call:
  # an approximate one from the compaction's own postTokens (see
  # "Compaction"). Dim and marked "~" — it is an estimate. Plain integers
  # only (a window size is), and a result past 100 is no estimate at all.
  case "$ctx_size" in
    ''|0|*[!0-9]*) ;;
    *)
      if [ ${#ctx_size} -le 12 ] && [ ${#compact_post} -le 12 ] && [ $(( 10#$ctx_size )) -gt 0 ]; then
        ctx_est=$(( (10#$compact_post * 100 + 10#$ctx_size / 2) / 10#$ctx_size ))
        [ "$ctx_est" -le 100 ] && _seg ctx "${DIM}${G_CTX}~${ctx_est}%${RESET}"
      fi ;;
  esac
fi
[ "$compact_n" -gt 0 ] && _seg compact "${DIM}${G_COMPACT}${compact_n}${RESET}"
if [ -n "$five_hour" ]; then
  _color_pct "$five_hour" 90 70
  reset_part=""; [ -n "$five_hour_reset_fmt" ] && reset_part="${DIM}${G_RESET}${five_hour_reset_fmt}${RESET}"
  pace_arrow "$five_hour" "$five_hour_reset" 18000 10
  printf -v _pct '%.0f' "$five_hour"
  _seg 5h "${c}S:${_pct}%${RESET}${_pace_out:+ }${_pace_out}${reset_part:+ }${reset_part}"
fi
# === Fable weekly limit — opt-in network source ===
# When the payload carried no per-model bucket (the normal case on 2.1.x, see
# the parse block), the only place the Fable share exists is the /usage
# endpoint, which reports it inside `limits[]` as kind=weekly_scoped with
# scope.model.display_name=Fable. That is a network call, which this script
# otherwise never makes, so it is strictly opt-in (AGENTLINE_USAGE_API=1),
# served from a cache for AGENTLINE_USAGE_TTL seconds (default 300), and any
# failure -- no credentials, expired token, non-200, malformed JSON -- simply
# leaves `F:` hidden. The token is read by python straight from the profile's
# .credentials.json and never appears in argv, env, or output. The cache file
# lives in the same owner-only directory as the render cache and is skipped
# entirely when that directory failed its trust check ($CACHE_BASE empty).
#
# Account scope: Claude Code keeps one account per config directory
# (CLAUDE_CONFIG_DIR, default ~/.claude), so both the credentials read and
# the cache key follow it — a single global usage file showed one profile's
# weekly figure in another profile's bar. The key is the path with every
# non-alphanumeric byte turned into `_`: parameter expansion, no cksum fork.
# Two logins that take turns in the *same* directory still share a key; the
# cached figure is then at most one TTL behind the switch. On macOS the OAuth
# token lives in the Keychain, not in .credentials.json, so this source finds
# no token there and `F:` stays hidden.
_cfg_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
_cfg_dir="${_cfg_dir%/}"
_acct_key="${_cfg_dir//[!A-Za-z0-9]/_}"
if [ -z "$seven_day_top" ] && [ "${AGENTLINE_USAGE_API:-0}" = "1" ] && [ -n "$CACHE_BASE" ]; then
  usage_cache="${CACHE_DIR}/usage.${_acct_key}"
  usage_ttl="${AGENTLINE_USAGE_TTL:-300}"
  usage_age=999999
  if [ -f "$usage_cache" ]; then
    mtime=$(stat -c %Y "$usage_cache" 2>/dev/null || stat -f %m "$usage_cache" 2>/dev/null || echo 0)
    # A file removed between the test and the stat (the daily prune, say)
    # makes GNU stat fall through to `-f`, which prints a filesystem report.
    case "$mtime" in ''|*[!0-9]*) mtime=0 ;; esac
    usage_age=$(( _now_epoch - mtime ))
  fi
  if [ "$usage_age" -lt "$usage_ttl" ]; then
    seven_day_top=$(<"$usage_cache")
  else
    # The refresh runs detached from the render. Claude Code cancels an
    # in-flight status-line script whenever a new update is due — with
    # refreshInterval=1 that is every second — and a full render already
    # takes most of one, so a fetch made inside the render was routinely
    # killed halfway. It used to claim the refresh by touching the cache
    # itself, so a killed render left a fresh mtime on the old (or empty)
    # content and nothing retried for a whole TTL.
    #
    # Now the claim is its own small file, holding the epoch it was taken
    # (read with the `read` builtin): every open session and every tick
    # lands here the moment the TTL runs out, and the first one to find no
    # claim younger than 30 s takes it and starts the fetch, so N sessions
    # make one request, not N. No lock, so nothing can be left stuck — an
    # abandoned claim simply ages out. The fetch is a background python that
    # leaves the render's process group (os.setsid) and holds none of its
    # output, so neither the render finishing nor Claude Code killing it
    # can abort the fetch; it writes a temp file and renames it over the
    # cache, then drops the claim. A 20 s alarm bounds it however the
    # network misbehaves.
    #
    # os.setsid() runs only once the interpreter is up, some 20 ms after the
    # fork, and a render that exits sooner than that could have its group
    # killed while the fetch was still in it. So the fetch is started with
    # HUP, INT and TERM ignored — an ignored disposition survives exec — and
    # python puts them back to default the moment it has its own session.
    # The group is backgrounded as one job and `exec`s python: one fork, as
    # a plain `python3 ... &` was.
    #
    # Meanwhile the previous figure is shown, but only for a minute past its
    # TTL. The result, empty included, replaces the cache: keeping the old
    # value on failure would leave a figure on screen that nothing has
    # confirmed since, indefinitely for a logged-out account; an empty
    # result instead hides `F:` for one TTL and does not retry every render.
    # If fetches never land at all, the grace runs out and `F:` hides too.
    if [ -f "$usage_cache" ] && [ "$usage_age" -lt $(( usage_ttl + 60 )) ]; then
      seven_day_top=$(<"$usage_cache")
    fi
    usage_claim="${usage_cache}.claim"
    claimed_at=0
    [ -f "$usage_claim" ] && read -r claimed_at < "$usage_claim"
    case "$claimed_at" in ''|*[!0-9]*) claimed_at=0 ;; esac
    # A claim that cannot be written (full disk, read-only cache dir) starts
    # no fetch: without it every full render would fetch again, and the
    # result could not be cached either. 2>/dev/null comes first so the
    # shell's own "cannot create" message for the failed redirect is muted.
    if [ $(( _now_epoch - claimed_at )) -ge 30 ] &&
       printf '%s\n' "$_now_epoch" 2>/dev/null > "$usage_claim"; then
      { trap '' HUP INT TERM
        exec python3 -I - "$_cfg_dir" "$usage_cache" "$usage_claim" >/dev/null 2>&1 <<'PYEOF'
import json, os, re, signal, sys, urllib.request
try:
    os.setsid()
except OSError:
    pass
for _sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(_sig, signal.SIG_DFL)
cfg, cache, claim = sys.argv[1:4]
# AGENTLINE_USAGE_URL is the test seam (tests/run.sh points it at a local fake
# server; -I closed the old PYTHONPATH one). It is honoured for a loopback
# http URL only: the request carries the account OAuth token, and a project
# .claude/settings.json can set env vars for the session, so an arbitrary URL
# here would hand that token to whoever wrote the project settings. The
# override also ignores any http_proxy: it is plain http, and a proxy would
# see the token in the clear (the real endpoint only ever tunnels TLS).
url, fetch = 'https://api.anthropic.com/api/oauth/usage', urllib.request.urlopen
_override = os.environ.get('AGENTLINE_USAGE_URL', '')
if re.match(r'http://(127\.0\.0\.1|localhost|\[::1\])(:[0-9]+)?/', _override):
    url = _override
    fetch = urllib.request.build_opener(urllib.request.ProxyHandler({})).open
def _expired(*_):
    raise TimeoutError()
signal.signal(signal.SIGALRM, _expired)
signal.alarm(20)
out = ''
try:
    cred = json.load(open(os.path.join(os.path.expanduser(cfg), '.credentials.json')))['claudeAiOauth']
    req = urllib.request.Request(url, headers={
        'Authorization': 'Bearer ' + cred['accessToken'],
        'anthropic-beta': 'oauth-2025-04-20',
        'Accept': 'application/json',
    })
    d = json.load(fetch(req, timeout=10))
    scoped = [l for l in d.get('limits', []) if isinstance(l, dict) and l.get('kind') == 'weekly_scoped']
    for want in ('fable', 'opus'):
        for l in scoped:
            name = str(((l.get('scope') or {}).get('model') or {}).get('display_name') or '').lower()
            if name == want and isinstance(l.get('percent'), (int, float)):
                out = str(l['percent'])
                break
        if out:
            break
except Exception:
    pass
signal.alarm(0)
# The claim is dropped only once the result is in place. After a failed
# write the cache is still expired, and dropping the claim anyway made the
# very next full render fetch again — once per render for as long as the
# disk stayed full. Left in place, the claim holds retries to one per 30 s.
tmp = '%s.%d' % (cache, os.getpid())
try:
    with open(tmp, 'w') as f:
        f.write(out)
    os.replace(tmp, cache)
except OSError:
    try:
        os.unlink(tmp)
    except OSError:
        pass
else:
    try:
        os.unlink(claim)
    except OSError:
        pass
PYEOF
      } &
    fi
  fi
fi
# Weekly limits. The premium-model bucket rides inside the W segment as an
# orange `F:` field, between the account-wide percentage and the reset marker,
# so the reset date stays at the end where it reads as belonging to both. It
# is its own colour on purpose: the 70/90 thresholds answer "how close am I to
# the wall", while this answers "how much of that is the expensive model" —
# a different question, so it does not share W's colour. Either half may be
# missing; the segment renders whichever exist and disappears when neither do.
week_body=""
if [ -n "$seven_day" ]; then
  _color_pct "$seven_day" 90 70
  printf -v _pct '%.0f' "$seven_day"
  week_body="${c}W:${_pct}%${RESET}"
  # The pace follows W: directly, before F: — it is the account-wide
  # window's pace; the Fable share has no reset of its own in the payload.
  pace_arrow "$seven_day" "$seven_day_reset" 604800 3
  week_body="${week_body}${_pace_out:+ }${_pace_out}"
fi
case "$seven_day_top" in
  ''|*[!0-9.]*) ;;
  *) printf -v _pct '%.0f' "$seven_day_top"
     week_body="${week_body:+${week_body} }${ORANGE}F:${_pct}%${RESET}" ;;
esac
if [ -n "$week_body" ]; then
  reset_part=""; [ -n "$seven_day_reset_fmt" ] && reset_part="${DIM}${G_RESET}${seven_day_reset_fmt}${RESET}"
  _seg week "${week_body}${reset_part:+ }${reset_part}"
fi

# === Prompt cache ===
# Whether the next turn pays full input price. A warm cache is the normal
# case and says nothing, so like ailine the segment hides while warm and
# appears only when there is something to act on:
#   - warm, with at most AGENTLINE_CACHE_WARN seconds left (default 60 on a
#     5m TTL, 300 on 1h): a yellow "🗄️ ↻1m12s", ticking live — the countdown
#     is a PCEXP_TOKEN placeholder filled in at print time (_pc_fill), so a
#     cached tick counts it down like the clock. Whether it shows at all is
#     decided per full render, which comes at least every
#     AGENTLINE_CACHE_TTL seconds, so it appears at most that late.
#   - cold: a red "🗄️ cold·ttl" saying why, plus the dim "~45k" tokens the
#     next turn re-writes, when the payload says.
# AGENTLINE_CACHE_VERBOSE=1 adds the session hit ratio in any state, red
# below 25, yellow below 75. All bash tests on parser-made digits: no fork.
#
# Which cause a cold cache shows. A miss re-writes the cache, so right after
# one the cache is warm again, not cold: last_miss_cause is history, and it
# carries no time of its own to say whether it belongs to the latest request.
# A cache that went cold by sitting idle past expires_at would otherwise
# blame a tools_changed miss from an hour before. So an expires_at already
# past means the TTL ran out, whatever the recorded miss — and whatever
# `warm` still says, since a payload is only as fresh as the last event and
# nothing re-runs the status line exactly at expiry. The recorded cause is
# shown only when the payload gives no expiry to judge by (the latest
# response wrote no cache at all), where it can only describe that response.
# No "miss" marker while warm: with no time on the cause it would keep
# naming the same old miss after every hit that followed it.
pc_meas="0m00s"
if [ -n "$pc_state" ]; then
  pc_body=""
  pc_gone=0
  if [ -n "$pc_exp" ] && [ "$pc_exp" -le "$_now_epoch" ]; then pc_gone=1; pc_cause=ttl; fi
  if [ "$pc_state" = cold ] || [ "$pc_gone" = 1 ]; then
    pc_body="${RED}cold${pc_cause:+${G_DOT}${pc_cause}}${RESET}${pc_recache:+ ${DIM}~${pc_recache}${RESET}}"
    _WARNED="${_WARNED},cache"
  elif [ -n "$pc_exp" ]; then
    pc_warn=60; [ "$pc_ttl" = 1h ] && pc_warn=300
    case "${AGENTLINE_CACHE_WARN-}" in
      ''|*[!0-9]*|??????*) ;;
      *) pc_warn=$(( 10#$AGENTLINE_CACHE_WARN )) ;;
    esac
    pc_rem=$(( pc_exp - _now_epoch ))
    if [ "$pc_rem" -gt 0 ] && [ "$pc_rem" -le "$pc_warn" ]; then
      pc_body="${YELLOW}${G_RESET}${PCEXP_TOKEN}${pc_exp}@@${RESET}"; _WARNED="${_WARNED},cache"
      # The layout pass measures the countdown before it is filled in, at
      # the widest it can print within this warn window: "0m00s" was a cell
      # short of the "12m00s" an AGENTLINE_CACHE_WARN of 600+ prints.
      if [ "$pc_warn" -ge 60 ]; then pc_meas="$(( pc_warn / 60 ))m00s"; else pc_meas="${pc_warn}s"; fi
    fi
  fi
  if [ "${AGENTLINE_CACHE_VERBOSE:-0}" = 1 ] && [ -n "$pc_hit" ]; then
    if [ "$pc_hit" -lt 25 ]; then c="$RED"; elif [ "$pc_hit" -lt 75 ]; then c="$YELLOW"; else c="$GREEN"; fi
    pc_body="${c}${pc_hit}%${RESET}${pc_body:+ }${pc_body}"
  fi
  [ -n "$pc_body" ] && _seg cache "${G_CACHE}${pc_body}"
fi
[ -n "$cost_fmt" ]       && _seg cost "${G_COST}\$${cost_fmt}"
[ -n "$duration_fmt" ]   && _seg dur "${G_DUR}${duration_fmt}"
[ -n "$tokens_in_fmt" ]  && _seg tok_in "${G_IN}${tokens_in_fmt}"
[ -n "$tokens_out_fmt" ] && _seg tok_out "${G_OUT}${tokens_out_fmt}"
# Word counter (optional hook): ↑ words you typed, ↓ words Claude wrote.
if [ -n "$words_in_w" ] || [ -n "$words_out_w" ]; then
  _seg words "${G_WORDS}${DIM}${G_ARR_UP}${RESET}${words_in_w:-0} ${DIM}${G_ARR_DN}${RESET}${words_out_w:-0}"
fi
[ -n "$lines_fmt" ]      && _seg lines "${G_LINES}${lines_fmt}"
[ -n "$cpu_usage" ]      && _seg cpu "${G_CPU}${cpu_usage}"
[ -n "$mem_used_gb" ]    && _seg mem "${G_MEM}${mem_used_gb}"
if [ -n "$disk_pct" ]; then
  if [ "$disk_pct" -ge 80 ]; then
    _seg disk "${RED}${G_WARN}${G_DISK}${disk_pct}%${RESET}"; _WARNED="${_WARNED},disk"
  else
    _color_pct "$disk_pct" 90 80
    _seg disk "${c}${G_DISK}${disk_pct}%${RESET}"
  fi
fi

# Line 2: env info
[ -n "$version" ]          && _seg version "${DIM}v${version}${RESET}"
# Breadcrumb: when the session has cd'd away from where it was launched
# (workspace.project_dir), the launch folder's name leads the path, dim:
# "↖ agentline ~/src/other". Only outside it: in the launch directory, or
# anywhere below it, the path shown already starts with that folder, and
# "↖ agentline ~/src/agentline/tests" said it twice. A directory that merely
# shares the prefix (~/src/agentline2) is outside. The name ($crumb, capped
# in the parser) and the test come by expansion, no fork.
_pd="${project_dir%/}"; _cd="${cwd_disp%/}"
_crumb_in=0
case "$_cd/" in "$_pd"/*) _crumb_in=1 ;; esac
if [ -n "$folder" ] && [ -n "$_pd" ] && [ "$_crumb_in" = 0 ] && [ -n "$crumb" ]; then
  _seg dir "${DIM}${G_BACK}${crumb}${RESET} ${BLUE}${folder}${RESET}"
else
  [ -n "$folder" ] && _seg dir "${BLUE}${folder}${RESET}"
fi
# The branch, then how far it is from its upstream ("↑2↓1") and the
# uncommitted work, dim ("±3 ?2 ✖1") — both from the throttled git status
# probe, and each simply absent when zero or not measured.
if [ -n "$git_branch" ]; then
  _link "$git_url" "$git_repo"
  _seg git "${MAGENTA}${G_GIT}${RESET}${DIM}${git_repo:+${_link_out}@}${RESET}${MAGENTA}${git_branch}${RESET}${git_ab:+ ${git_ab}}${git_dirty:+ ${DIM}${git_dirty}${RESET}}"
fi
# Pull request: "🔀 ✅ #1234" (a GitLab MR is !1234), the review state first.
# The footer already shows the PR number; what this adds is the review
# state at a glance and a link. An unknown state shows the number alone.
if [ -n "$pr_number" ]; then
  case "$pr_state" in
    draft)             pr_glyph="$G_PR_DRAFT" ;;
    pending)           pr_glyph="$G_PR_PENDING" ;;
    changes_requested) pr_glyph="$G_PR_CHANGES" ;;
    approved)          pr_glyph="$G_PR_OK" ;;
    *)                 pr_glyph="" ;;
  esac
  pr_ref="#${pr_number}"; [ "$pr_kind" = mr ] && pr_ref="!${pr_number}"
  _link "$pr_url" "$pr_ref"
  _seg pr "${G_PR}${pr_glyph}${CYAN}${_link_out}${RESET}"
fi
# Linked worktree: "🌳 name", only when the session runs in one (the main
# clone has neither field). The last path component, whether Claude Code
# hands over a name or a path, capped at 24 characters (the parser's
# $wt_disp).
[ -n "$wt_disp" ] && _seg worktree "${G_TREE}${GREEN}${wt_disp}${RESET}"
[ -n "$session_name_fmt" ] && _seg session "${G_SESSION}${session_name_fmt}"

# Masked email. The payload's account.email is free; only when it is absent is
# `claude auth status` consulted, and that result is cached for 60 seconds --
# a CLI cold start on every render would otherwise dominate the whole script.
#
# The cache holds the *unmasked* address, so it lives in the owner-only cache
# directory, keyed by account like the usage cache (a `claude` child inherits
# CLAUDE_CONFIG_DIR and reports that profile). It used to sit loose in the
# shared temp dir as agentline-email-<uid>, world-readable under the usual
# umask and shared by every profile; that file is removed on sight. When the
# cache directory failed its trust check there is nowhere safe to keep the
# address, and no cache means a CLI cold start every second, so the lookup is
# skipped and only a payload-supplied address is shown.
_old_email_cache="${TMPDIR:-/tmp}/agentline-email-${UID:-0}"
[ -e "$_old_email_cache" ] && rm -f "$_old_email_cache" 2>/dev/null
account_email="$payload_email"
if [ -z "$account_email" ] && [ -n "$CACHE_BASE" ]; then
  auth_cache="${CACHE_DIR}/email.${_acct_key}"
  cache_age=999999
  if [ -f "$auth_cache" ]; then
    mtime=$(stat -c %Y "$auth_cache" 2>/dev/null || stat -f %m "$auth_cache" 2>/dev/null || echo 0)
    case "$mtime" in ''|*[!0-9]*) mtime=0 ;; esac
    cache_age=$(( _now_epoch - mtime ))
  fi
  if [ "$cache_age" -lt 60 ]; then
    account_email=$(cat "$auth_cache" 2>/dev/null)
  else
    account_email=$(claude auth status --json 2>/dev/null | python3 -I -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('email', ''))
except:
    print('')
")
    # Empty results are cached too, so a logged-out state does not re-spawn
    # the CLI on every render.
    printf '%s' "$account_email" > "$auth_cache" 2>/dev/null
  fi
  # CLI output (fresh or cached) is host data like the probes above.
  _clean account_email
fi

# The mask keeps the first and last character of the local part and of the
# domain label before the TLD: octocat@example.com -> o*****t@e*****e.com. It
# is the regex below, ^(.)(.*)(.)@(.)(.*)(.)(\..+)$, done with parameter
# expansion for the common case — a python3 start (~20 ms) on every full
# render used to be spent on it. The greedy groups are walked the same way
# the regex backtracks: the last "@" that leaves a valid domain, then the
# last "." in that domain with two characters before it and one after.
# Parameter expansion counts bytes under C/POSIX and characters under UTF-8,
# so it is only trusted with an address spelled from an explicit ASCII list
# (no ranges: bash 3.2 matches [a-z] by collation order, which admits
# accented letters); anything else still goes to the python3 original.
#
# That python gets the address on stdin (a here-string, no extra fork), never
# as an argument: argv is world-readable through `ps` and /proc/<pid>/cmdline
# for as long as the process runs, and this is the unmasked address. Bytes in
# and out, surrogateescape both ways, so no encoding can make it raise.
IFS= read -r -d '' _AL_PY <<'PYEOF'
import re, sys
email = sys.stdin.buffer.read().decode('utf-8', 'surrogateescape').rstrip('\n')
m = re.match(r'^(.)(.*)(.)(@)(.)(.*)(.)(\..+)$', email)
if m:
    local_first = m.group(1)
    local_mid   = '*' * len(m.group(2))
    local_last  = m.group(3)
    at          = m.group(4)
    dom_first   = m.group(5)
    dom_mid     = '*' * len(m.group(6))
    dom_last    = m.group(7)
    tld         = m.group(8)
    email = f'{local_first}{local_mid}{local_last}{at}{dom_first}{dom_mid}{dom_last}{tld}'
sys.stdout.buffer.write(email.encode('utf-8', 'surrogateescape'))
PYEOF
_mask_email() {  # _mask_email <address> -> $masked_email
  local e="$1" head loc dom dhead pre post s1 s2
  masked_email="$e"
  case "$e" in
    '') return ;;
    *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@._+-]*)
      masked_email=$(python3 -I -c "$_AL_PY" <<< "$e"); return ;;
  esac
  head="$e"
  while :; do
    case "$head" in *@*) ;; *) return ;; esac
    loc="${head%@*}"; dom="${e:$(( ${#loc} + 1 ))}"; head="$loc"
    # Every earlier "@" leaves a shorter local part, so none can reach two.
    [ ${#loc} -ge 2 ] || return
    dhead="$dom"
    while :; do
      case "$dhead" in *.*) ;; *) break ;; esac
      pre="${dhead%.*}"; post="${dom:${#pre}}"; dhead="$pre"
      [ ${#pre} -ge 2 ] || break
      if [ ${#post} -ge 2 ]; then
        printf -v s1 '%*s' $(( ${#loc} - 2 )) ''
        printf -v s2 '%*s' $(( ${#pre} - 2 )) ''
        masked_email="${loc:0:1}${s1// /*}${loc:$(( ${#loc} - 1 ))}@${pre:0:1}${s2// /*}${pre:$(( ${#pre} - 1 ))}${post}"
        return
      fi
    done
  done
}
_mask_email "$account_email"
[ -n "$masked_email" ] && _seg email "${G_EMAIL}${DIM}${masked_email}${RESET}"
_seg date "${DIM}${date_str}${RESET}"
_seg clock "${CYAN}${time_str}${RESET}"

# Line 3 — Claude layer: MCP servers + active agents + resume command
[ -n "$active_mcps" ]   && _seg mcp "${G_MCP}${DIM}${active_mcps}${RESET}"
# One entry per row, each in its worker's colour (see "Agent rows"), then
# the ones that just finished in green. The rows are joined by $_GS: the
# layout pass sets them in a column of their own.
if [ -n "$active_agents$agents_done" ]; then
  _seg agents "$_ag_rows"
fi
# Recovery command: brings the session back after an unexpected exit.
# `claude --resume` takes a session ID. A session name is free-form text, so
# using it unquoted split the command into several arguments and could not be
# pasted. The id is therefore preferred; the name is only a fallback, quoted,
# where --resume treats it as a search term for the interactive picker.
# The readable name is already shown on line 2, so nothing is lost here.
resume_cmd=""
if [ -n "$session_id" ]; then
  # $session_id is kept raw for the transcript path; the displayed copy is
  # cleaned like every other payload string.
  _sid_disp="$session_id"; _clean _sid_disp
  resume_cmd="claude --resume ${_sid_disp}"
elif [ -n "$session_name" ]; then
  resume_cmd="claude --resume \"${session_name//\"/\\\"}\""
fi
[ -n "$resume_cmd" ] && _seg resume "${G_RESUME}${DIM}${resume_cmd}${RESET}"

# Line 4 — System layer: service health + ssh + cron + dev servers
[ -n "$svc_panel" ] && _seg services "${G_SVC}${svc_panel}"
[ -n "$_svc_bad" ] && _WARNED="${_WARNED},services"
if [ -n "$ssh_count" ] && [ "$ssh_count" -gt 0 ]; then
  ssh_c="$DIM"; [ "$ssh_count" -gt 1 ] && ssh_c="$YELLOW"
  _seg ssh "${G_SSH}${ssh_c}ssh:${ssh_count}${RESET}"
fi
if [ -n "$cron_count" ] && [ "$cron_count" -gt 0 ]; then
  _seg cron "${G_CRON}${DIM}cron:${cron_count}${RESET}"
fi
[ -n "$dev_ports" ] && _seg ports "${G_PORTS}${DIM}${dev_ports}${RESET}"
# local.sh's own segments (agentline_seg), already cleaned, in call order.
SEGS="${SEGS}${_LSEGS}"

[ -n "$_AL_DOCTOR" ] && _dt_mark segments
# === Layout ===
# One python pass turns the segment records into rows. $AGENTLINE_LAYOUT is
# the order: "/" starts a line, "," separates segment names, and a name left
# out is a segment hidden (the starship / l0ng-ai format-string idea — order
# and grouping come free from an ordered list). The default reproduces the
# historical four lines byte for byte.
#
# Lines 3 and 4 are separate layers (Claude vs system). On a quiet host the
# split wastes a row, so they are joined when the combined width fits. On a
# busy host either line can outgrow the terminal, so each is wrapped onto
# continuation rows at segment (│) boundaries instead of overflowing — a
# segment is never split internally. Width is measured after stripping colour
# escapes, counting wide glyphs as two cells.
#
# The width: $AGENTLINE_WIDTH when set (an explicit override wins), else the
# live terminal width, else 120. Claude Code >= 2.1.153 exports COLUMNS to the
# status-line command; 2 cells come off it as a margin, because COLUMNS is
# read when the command starts and can trail a resize, and because terminals
# disagree on emoji widths: an emoji with a variation selector (⚠️ ♻️ ⚙️ 🛡️)
# is measured at two cells (see vis()), which a terminal that ignores the
# selector draws one cell narrower.
#
# Fit mode. When the width is known — COLUMNS is there — every line, not just
# 3 and 4, is fitted to it: segments are dropped from an over-wide line in
# $AGENTLINE_DROP order (lowest priority first) until it fits, then whatever
# still does not fit wraps. model, ctx, 5h and week are never dropped,
# whatever the list says. Without COLUMNS the width is only a guess, and
# hiding data on a guess is worse than overflowing, so lines 1 and 2 are left
# whole as they always were — unless AGENTLINE_DROP is set, which asks for fit
# mode against whatever the width is. AGENTLINE_DROP="" fits by wrapping
# alone, dropping nothing.
#
# The rows come back joined by a literal \n, the form printf %b renders, so
# the output is used as-is. It is written as bytes through os.fsencode, which
# reverses exactly how python decoded argv: a byte the locale cannot decode
# round-trips instead of raising on the way out.
AGENTLINE_LAYOUT_DEFAULT="model,effort,fast,ctx,compact,5h,week,cache,cost,dur,tok_in,tok_out,words,lines,cpu,mem,disk / version,dir,git,pr,worktree,session,email,date,clock / mcp,agents,resume / services,ssh,cron,ports"
# cpu, mem and disk close the list: they are host readings, the least a line
# about the session needs, and without them a busy line 1 at COLUMNS≈122
# still overflowed by a few cells and wrapped them onto a row of their own.
# cache (the prompt-cache warning) goes last of all: it only shows when it
# is about to cost something, and then it outranks any host reading.
AGENTLINE_DROP_DEFAULT="tok_in,tok_out,words,compact,dur,date,version,email,lines,cpu,mem,disk,cache"
# The default layout this render: local.sh's segments close line 4 (its
# last line), in call order. They are not on the default drop list — asked
# for by name, they wrap with line 4 rather than vanish; AGENTLINE_DROP can
# name them. Any local:<name> is a known name to a custom layout, so a
# segment that has no content this render hides nothing but itself.
_lay_def="${AGENTLINE_LAYOUT_DEFAULT}${_LNAMES:+,${_LNAMES}}"
# Leading zeros and absurd lengths are refused: bash arithmetic reads "08" as
# bad octal, and a width is never six digits.
_cols="${COLUMNS-}"
case "$_cols" in ''|0*|*[!0-9]*|??????*) _cols="" ;; esac
_fit=0
if [ -n "$_cols" ]; then
  _fit=1
  STATUSLINE_WIDTH=$(( _cols - 2 ))
else
  STATUSLINE_WIDTH=120
fi
case "${AGENTLINE_WIDTH-}" in
  ''|*[!0-9]*|??????*) ;;
  *) STATUSLINE_WIDTH="$AGENTLINE_WIDTH" ;;
esac
[ -n "${AGENTLINE_DROP+set}" ] && _fit=1
IFS= read -r -d '' _AL_PY <<'PYEOF'
import os, re, sys, unicodedata
width, sep, layout, default_layout = max(1, int(sys.argv[1])), sys.argv[2], sys.argv[3], sys.argv[4]
fitting, drop_spec = sys.argv[5] == '1', sys.argv[6]
placeholders = dict(zip(sys.argv[7:10], ('00:00:00', 'max', 'ultracode')))
grad_re = re.compile(re.escape(sys.argv[10]) + '(.*?)' + re.escape(sys.argv[11]), re.S)
# The prompt-cache countdown carries its epoch: measured as argv[14], the
# widest it can print within the warn window bash chose ("0m00s" for the
# default windows, "12m00s" for AGENTLINE_CACHE_WARN=720).
pcexp_re = re.compile(re.escape(sys.argv[12]) + '[0-9]*@@')
pc_meas = sys.argv[14]
# The live terminal width is known (COLUMNS): the agent list may take a
# column at the right edge (see the end of this program).
live = sys.argv[17] == '1'
# The segment records come on stdin (a here-string: one trailing newline).
segs = sys.stdin.buffer.read().decode('utf-8', 'surrogateescape')
if segs.endswith('\n'):
    segs = segs[:-1]
KEEP = ('warn', 'model', 'ctx', '5h', 'week')
# Plus whatever is in its warning state this render (_WARNED in bash).
warned = set(sys.argv[13].split(','))
drop = [n for n in re.split(r'[\s,]+', drop_spec) if n and n not in KEEP and n not in warned]

# The Fable/Mythos model name arrives between GRAD_OPEN/GRAD_CLOSE markers
# and is painted here, one truecolor step per character, amber to orange.
# The endpoints come from bash as "r,g,b" (theme and overrides, see "Colors").
def rgb(v, default):
    try:
        t = tuple(int(x) for x in v.split(','))
        return t if len(t) == 3 and all(0 <= x <= 255 for x in t) else default
    except ValueError:
        return default
FABLE = rgb(sys.argv[15], (255, 215, 90)), rgb(sys.argv[16], (255, 125, 25))
def gradient(m):
    s = m.group(1)
    start, end = FABLE
    n = max(len(s) - 1, 1)
    out = []
    for i, ch in enumerate(s):
        r = int(start[0] + (end[0]-start[0]) * i / n)
        g = int(start[1] + (end[1]-start[1]) * i / n)
        b = int(start[2] + (end[2]-start[2]) * i / n)
        out.append(f'\033[1;38;2;{r};{g};{b}m{ch}')
    return ''.join(out)

# A raw lone 0x80-0x9F byte reaches here as a surrogate (\udc80-\udc9f, the
# surrogateescape decoding of an invalid byte) and would be written back as
# that byte: a bare 0x9B is the 8-bit CSI. _clean cannot take it without
# decoding (it could be part of a character there), but here a surrogate is
# never part of one. A local.sh segment is the way such a byte arrives.
C1_RAW = re.compile('[\udc80-\udc9f]')
seg = {}
for rec in segs.split('\x1e'):
    name, _, text = rec.partition('\x1f')
    if text and name not in seg:
        seg[name] = grad_re.sub(gradient, C1_RAW.sub('', text))

# local.sh's segments (agentline_seg): any well-formed name is known.
LOCAL_RE = re.compile(r'local:[a-z0-9_-]{1,24}')
def parse(spec):
    # "/" starts a line, "," separates names; unknown names and repeats are
    # ignored, so a typo hides nothing but itself.
    known = set(default_layout.replace('/', ',').replace(' ', '').split(','))
    lines, seen = [], set()
    for part in spec.split('/'):
        names = []
        for n in part.split(','):
            n = n.strip()
            if (n in known or LOCAL_RE.fullmatch(n)) and n not in seen:
                seen.add(n)
                names.append(n)
        lines.append(names)
    return lines

def vis(s):
    # The clock and the animated effort words are still placeholders here,
    # substituted after layout; count them at the width they will print at.
    for tok, shown in placeholders.items():
        s = s.replace(tok, shown)
    s = pcexp_re.sub(pc_meas, s)
    # Colour codes are mostly still in backslash-escape form here (rendered
    # later by printf %b), so strip the literal \033[..m sequences before
    # measuring — and real ESC ones too, which color_pct prints already
    # expanded (the context, limit and disk segments).
    s = re.sub(r'(?:\\033|\x1b)\[[0-9;]*m', '', s)
    # OSC-8 hyperlinks (the PR number, the repo) take no cells: only the
    # text between opener and closer is drawn. The URL holds no backslash
    # (cleaned where it was made), so the backslash-form BEL ends it.
    s = re.sub(r'(?:\\033|\x1b)\]8;;[^\\\x07]*(?:\\a|\x07)', '', s)
    # Wide and fullwidth characters take two cells. A variation selector 16
    # (U+FE0F) asks for the emoji presentation of the character before it,
    # which terminals draw two cells wide, so it makes that character two
    # cells whatever its own width (⚠️, ⚙️, 🛡️: the bases are narrow). Other
    # combining marks and format characters (U+FE0E, ZWJ) take none. These
    # glyphs used to come out right by accident — U+FE0F was counted as a
    # cell of its own — and the icons that carry one also got a hand-added
    # second space; the glyph table now gives every icon exactly one.
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

def wrap(texts):
    rows, cur = [], ''
    for t in texts:
        cand = cur + sep + t if cur else t
        if cur and vis(cand) > width:
            rows.append(cur)
            cur = t
        else:
            cur = cand
    if cur:
        rows.append(cur)
    return rows

# Drop in AGENTLINE_DROP order until the line fits one row. When the list
# runs out first, the line wraps anyway, and the segments dropped on the way
# were lost for nothing while the wrapped rows had room to spare (at 100
# columns line 2 lost version, e-mail and date and still took two rows, the
# second one 60 cells short). So once the drops cannot make one row, the row
# count of what is left is the target, and each dropped segment comes back —
# the most important first, i.e. last dropped first, at its own position —
# as long as the wrapped line stays within that many rows.
def fit(names):
    names = [n for n in names if n in seg]
    if not fitting:
        return [seg[n] for n in names]
    order, dropped = list(names), []
    for d in drop:
        if vis(sep.join(seg[n] for n in names)) <= width:
            break
        if d in names:
            names.remove(d)
            dropped.append(d)
    if dropped and vis(sep.join(seg[n] for n in names)) > width:
        target = len(wrap([seg[n] for n in names]))
        for d in reversed(dropped):
            cand = [n for n in order if n in names or n == d]
            if len(wrap([seg[n] for n in cand])) <= target:
                names = cand
    return [seg[n] for n in names]

lines = parse(layout)
# A layout that names no segment at all is a typo, not a request for a blank
# status line.
if not any(lines):
    lines = parse(default_layout)
is_default = lines == parse(default_layout)
if 'warn' in seg:
    lines[0].insert(0, 'warn')
# The agent list (🤖) is no member of its line: it is a list of rows, one
# entry each, joined by \x1d. It goes where its line names it, below.
ag_line, ag = None, []
for i, names in enumerate(lines):
    if 'agents' in names:
        names.remove('agents')
        ag = [r for r in seg.get('agents', '').split('\x1d') if r]
        ag_line = i if ag else None
        break
texts = [fit(names) for names in lines]

def build(merge):
    """The rows, and after each layout line how many rows there are."""
    rows, ends = [], []
    if is_default:
        # Lines 1 and 2 are always printed, as they always were, and are only
        # measured in fit mode; lines 3 and 4 merge when they fit together,
        # wrap when they do not, and vanish when empty.
        for t in texts[:2]:
            rows += (wrap(t) if fitting else []) or [sep.join(t)]
            ends.append(len(rows))
        l3, l4 = texts[2], texts[3]
        if merge and l3 and l4 and vis(sep.join(l3 + l4)) <= width:
            rows.append(sep.join(l3 + l4))
            ends += [len(rows)] * 2
        else:
            rows += wrap(l3)
            ends.append(len(rows))
            rows += wrap(l4)
            ends.append(len(rows))
    else:
        # A custom layout: empty lines collapse, and the same rule decides
        # what is measured — every line in fit mode, the third line on
        # otherwise.
        for i, t in enumerate(texts):
            if t:
                rows += wrap(t) if fitting or i >= 2 else [sep.join(t)]
            ends.append(len(rows))
    return rows, ends

# The agent list as a column at the right edge: entry i beside row i,
# padded with spaces so it ends at the width, at least 3 cells from the
# row's own text. Claude Code prints a status line as plain lines, so
# spaces are the only way to place it. Only with the live width (COLUMNS):
# padded to a guessed width, the column would land mid-screen or wrap. When
# a row has no room for its entry, or there are more entries than rows, it
# is no column at all. A row holding the prompt-cache countdown is measured
# at the countdown's widest form; the countdown prints narrower as it runs
# down, so the padding carries a token that bash fills (_pc_fill) with the
# difference, and the column does not move while it counts.
def column(rows):
    if not live or len(ag) > len(rows):
        return None
    out = list(rows)
    for i, e in enumerate(ag):
        gap = width - vis(rows[i]) - vis(e)
        if gap < 3:
            return None
        m = pcexp_re.search(rows[i])
        pad = ' ' * gap + (m.group(0)[:-2] + ':%d@@' % len(pc_meas) if m else '')
        out[i] = rows[i] + pad + e
    return out

rows, ends = build(True)
if ag:
    # Else: one row per entry, right after the rows of the line that names
    # it (the default: under line 3, the Claude layer, before line 4's
    # system layer, which is then never merged into line 3).
    out = column(rows) or column(build(False)[0])
    if out is None:
        rows, ends = build(False)
        out = rows[:ends[ag_line]] + ag + rows[ends[ag_line]:]
    rows = out
sys.stdout.buffer.write(os.fsencode('\\n'.join(rows)))
PYEOF
# The segments go in on stdin, not as an argument: one argv string is capped
# (128 KB on Linux, E2BIG past it), and when this python failed for any
# reason — that, or no python3 at all — $out came back empty and all four
# lines vanished. A here-string costs no fork.
out=$(python3 -I -c "$_AL_PY" "$STATUSLINE_WIDTH" "$P" "${AGENTLINE_LAYOUT:-$_lay_def}" \
  "$_lay_def" "$_fit" "${AGENTLINE_DROP-$AGENTLINE_DROP_DEFAULT}" \
  "$CLOCK_TOKEN" "$ANIM_MAX_TOKEN" "$ANIM_ULTRA_TOKEN" "$GRAD_OPEN" "$GRAD_CLOSE" "$PCEXP_TOKEN" "$_WARNED" "$pc_meas" \
  "$FABLE_FROM" "$FABLE_TO" "${_cols:+1}" <<< "$SEGS")
_layout_rc=$?
[ -n "$_AL_DOCTOR" ] && _dt_mark layout

# If the layout pass failed, bash lays the lines out itself: each line of
# the layout string, its segments joined with the separator in order — no
# fitting, no wrapping, no gradient (its markers are removed) — so a failed
# pass costs the polish, never the status line. The exit status decides, not
# an empty $out: a layout whose segments all lack data is rightly empty. A
# layout that names nothing known is the default, as in the python pass.
if [ "$_layout_rc" != 0 ] && [ -z "$out" ] && [ -n "$SEGS" ]; then
  _all="${_RS}${SEGS}"
  _lay="${AGENTLINE_LAYOUT:-$_lay_def}"; _lay="${_lay// /}"
  _known=0; _names="${_lay//\//,},"
  while [ -n "$_names" ]; do
    _n="${_names%%,*}"; _names="${_names#*,}"
    case ",${_lay_def//[\/ ]/,}," in *",${_n},"*) [ -n "$_n" ] && _known=1 ;; esac
    case "$_n" in local:?*) _known=1 ;; esac
  done
  [ "$_known" = 1 ] || _lay="$_lay_def"
  _lay="warn,${_lay// /}/"
  while [ -n "$_lay" ]; do
    _names="${_lay%%/*},"; _lay="${_lay#*/}"; _row=""
    while [ -n "$_names" ]; do
      _n="${_names%%,*}"; _names="${_names#*,}"
      [ -n "$_n" ] || continue
      case "$_all" in
        *"${_RS}${_n}${_US}"*)
          _t="${_all#*"${_RS}${_n}${_US}"}"; _t="${_t%%"${_RS}"*}"
          _t="${_t//"$GRAD_OPEN"/}"; _t="${_t//"$GRAD_CLOSE"/}"
          _t="${_t//"$_GS"/ ${DIM}${G_DOT}${RESET} }"
          _row="${_row:+${_row}${P}}${_t}" ;;
      esac
    done
    [ -n "$_row" ] && out="${out:+${out}\\n}${_row}"
  done
fi

# mono (see "Theme"): every SGR sequence goes, in both spellings the render
# holds — "\033[...m" still in backslash form for printf %b, and a real ESC
# from color_pct and the gradient. Done once on the finished render, before
# it is cached, rather than at each colour site: the service panel is built
# with its colours inside the probe cache, and local.sh may set colours of
# its own. Only [0-9;]* then m is taken; anything else after an ESC [ is
# left as it was (no cleaned string can hold one). OSC-8 links are not
# colour and stay. Slow path only, by parameter expansion.
#
# local.sh is the user's, and printf %b turns every spelling of ESC into a
# real one: \e, \E, \x1b, \0033 (and \u001b on bash 4.2+) as well as \033.
# All of them are taken, or a colour written in one of those survived mono.
# A function, because --doctor strips its host-probe lines the same way.
_mono_strip() {  # _mono_strip <text> -> $_mono_out
  local _esc _rest _par _o="$1"
  for _esc in '\033[' '\0033[' '\33[' '\e[' '\E[' '\x1b[' '\x1B[' '\u001b[' '\u001B[' $'\033['; do
    case "$_o" in *"$_esc"*) ;; *) continue ;; esac
    _rest="$_o"; _o=""
    while :; do
      case "$_rest" in *"$_esc"*) ;; *) break ;; esac
      _o="${_o}${_rest%%"$_esc"*}"; _rest="${_rest#*"$_esc"}"
      _par="${_rest%%m*}"
      case "$_rest" in
        *m*) case "$_par" in *[!0123456789\;]*) _o="${_o}${_esc}" ;; *) _rest="${_rest#*m}" ;; esac ;;
        *) _o="${_o}${_esc}" ;;
      esac
    done
    _o="${_o}${_rest}"
  done
  _mono_out="$_o"
}
if [ "$_AL_THEME" = mono ]; then
  _mono_strip "$out"; out="$_mono_out"
fi

# Prune the cache directory. Every session leaves render_<sid>.* files behind
# and nothing else ever removes them, so a long-lived host collects thousands.
# At most once a day, files untouched for more than 7 days are deleted — no
# live session's cache is that old, since each full render rewrites it. The
# gate is an epoch in a stamp file read with the `read` builtin, so the check
# costs no fork on every other full render of the day; the stamp is written
# before the sweep so a concurrent render does not start a second one.
#
# The same sweep repairs modes. `umask 077` only governs files created from
# now on: a `>` redirect onto a cache file an older release left at 644 keeps
# 644, and a directory made before the `mkdir -m 700` fix keeps whatever it
# had. So every file that survives the sweep is set to 600 and the directory
# to 700 (the directory is the `-maxdepth 0` entry, `-type d`). The first
# full render after an upgrade with no stamp yet, and every day after, runs it.
if [ -n "$CACHE_BASE" ]; then
  _prune_stamp="${CACHE_DIR}/.pruned"
  _pruned_at=0
  [ -f "$_prune_stamp" ] && read -r _pruned_at < "$_prune_stamp"
  case "$_pruned_at" in ''|*[!0-9]*) _pruned_at=0 ;; esac
  if [ $(( _now_epoch - _pruned_at )) -ge 86400 ]; then
    printf '%s\n' "$_now_epoch" > "$_prune_stamp" 2>/dev/null
    find "$CACHE_DIR" -maxdepth 1 \
      \( -type f -mtime +7 ! -name .pruned -delete \) -o \
      \( -type f ! -perm 600 -exec chmod 600 {} + \) -o \
      \( -type d ! -perm 700 -exec chmod 700 {} + \) 2>/dev/null
  fi
fi

# Cache the finished render (clock still a placeholder) for the ticks that
# follow. $out normally holds no real newline — colour breaks are literal \n
# rendered by printf %b — but a payload value could smuggle one in and would
# then collide with the epoch/body split, so such a render is simply not
# cached. The timestamp is taken now, not at script start, so the TTL measures
# from when the data was finished and the printed clock is not a render late.
_tick_now
case "$out" in
  *$'\n'*) ;;
  *)
    if [ -n "$CACHE_BASE" ]; then
      printf '%s' "$_cache_key" > "${CACHE_BASE}.payload" 2>/dev/null
      printf '%s\n%s' "$_now_epoch" "$out" > "${CACHE_BASE}.render" 2>/dev/null
    fi
    ;;
esac
out="${out//$CLOCK_TOKEN/$_now_clock}"
case "$out" in
  *"$ANIM_MAX_TOKEN"*)
    _anim_frame max rainbow
    out="${out//$ANIM_MAX_TOKEN/$_anim_out}" ;;
esac
case "$out" in
  *"$ANIM_ULTRA_TOKEN"*)
    _anim_frame ultracode violet
    out="${out//$ANIM_ULTRA_TOKEN/$_anim_out}" ;;
esac
case "$out" in
  *"$PCEXP_TOKEN"*) _pc_fill "$out"; out="$_pc_out" ;;
esac

# === Doctor report ===
# Everything below runs only for --doctor (see "Doctor"), after a full cold
# render, and prints plain text in place of the status line. Forks are fine
# here; the normal path has already printed and never gets this far.
#
# "Hidden" is explained by where a segment's data comes from: a payload
# field that was absent, a host probe that returned nothing, a hook side file
# that is missing. Claude Code version gates are only stated where the
# statusline docs give one (prompt_cache); for every other field the report
# says "absent in the payload" rather than guess at a version.
IFS= read -r -d '' _AL_DOCTOR_PY <<'PYEOF'
import json, re, sys
path = sys.argv[1]
def masked(cmd):
    # A report is made to be pasted into an issue, and an inline
    # `TOKEN=... bash agentline.sh` (or a --key=value) would carry a secret
    # into it: every NAME=value word keeps its name, not its value.
    return re.sub(r'''(^|[\s;&|(])(-{0,2}[A-Za-z_][A-Za-z0-9_-]*)=(?:"[^"]*"|'[^']*'|[^\s;&|)])*''',
                  r'\1\2=***', str(cmd))
try:
    d = json.load(open(path))
except FileNotFoundError:
    print('  (no %s)' % path)
    sys.exit()
except Exception as e:
    print('  %s does not parse: %s' % (path, e))
    sys.exit()
d = d if isinstance(d, dict) else {}
sl = d.get('statusLine') if isinstance(d.get('statusLine'), dict) else {}
print('  statusLine       %s' % (masked(sl.get('command')) if sl.get('command') else '(none)'))
print('  refreshInterval  %s' % (sl.get('refreshInterval') if sl.get('refreshInterval') is not None
                                 else 'unset: the clock only ticks on conversation events'))
ssl = d.get('subagentStatusLine') if isinstance(d.get('subagentStatusLine'), dict) else {}
cmd = ssl.get('command') if isinstance(ssl.get('command'), str) else ''
print('  subagent rows    %s' % (masked(cmd) + ('' if 'agentline-subagents.sh' in cmd else ' (not agentline)')
                                 if cmd else '(none: install.sh --with-subagents)'))
hooks = d.get('hooks') if isinstance(d.get('hooks'), dict) else {}
WANT = (('agent-tracker-hook.sh', ('PreToolUse', 'SubagentStart', 'SubagentStop', 'Stop')),
        ('wordcount-hook.sh', ('PostToolUse', 'Stop')))
for name, events in WANT:
    got = []
    for ev in events:
        groups = hooks.get(ev) if isinstance(hooks.get(ev), list) else []
        ok = any(name in str(h.get('command') or '')
                 for g in groups if isinstance(g, dict)
                 for h in (g.get('hooks') or []) if isinstance(h, dict))
        got.append(ev + (' yes' if ok else ' NO'))
    print('  %-16s %s' % (name, ', '.join(got)))
PYEOF
_ver_ge() {  # _ver_ge <have> <want> — dotted versions; 2 when <have> is no version
  local IFS=. i x y
  local -a a b
  a=($1); b=($2)
  for i in 0 1 2; do
    x="${a[$i]:-0}"; x="${x%%[!0-9]*}"; y="${b[$i]:-0}"
    [ -n "$x" ] || return 2
    [ ${#x} -le 9 ] || return 2
    [ $(( 10#$x )) -gt $(( 10#$y )) ] && return 0
    [ $(( 10#$x )) -lt $(( 10#$y )) ] && return 1
  done
  return 0
}
_dt_have() { case "${_RS}${SEGS}" in *"${_RS}$1${_US}"*) return 0 ;; esac; return 1; }
_dt_why() {  # _dt_why <segment> — where its data comes from
  case "$1" in
    model)    echo "payload model.id / model.display_name" ;;
    effort)   echo "payload effort.level" ;;
    fast)     echo "payload fast_mode" ;;
    ctx)      echo "payload context_window.used_percentage" ;;
    compact)  echo "compact_boundary lines in transcript_path (not counted by --doctor: it needs the cache)" ;;
    5h)       echo "payload rate_limits.five_hour.used_percentage" ;;
    week)     echo "payload rate_limits.seven_day.used_percentage (F: seven_day_overage_included, or AGENTLINE_USAGE_API=1)" ;;
    cache)
      if [ -n "$pc_state" ]; then echo "payload prompt_cache: hidden while warm and not about to expire"
      elif [ -n "$version" ] && _ver_ge "$version" 2.1.251; then echo "payload prompt_cache: absent (no API response yet, or no caching reported)"
      elif [ -n "$version" ]; then echo "payload prompt_cache: needs Claude Code >= 2.1.251, this is $version (https://code.claude.com/docs/en/statusline)"
      else echo "payload prompt_cache (Claude Code >= 2.1.251; miss cause >= 2.1.260)"
      fi ;;
    cost)     echo "payload cost.total_cost_usd" ;;
    dur)      echo "payload cost.total_duration_ms" ;;
    tok_in)   echo "payload context_window.total_input_tokens" ;;
    tok_out)  echo "payload context_window.total_output_tokens" ;;
    words)    echo "wordcount hook: $WC_FILE$([ -f "$WC_FILE" ] || echo ' (missing)')" ;;
    lines)    echo "payload cost.total_lines_added / total_lines_removed" ;;
    cpu)      echo "probe: top" ;;
    mem)      [ "$OS" = Darwin ] && echo "probe: vm_stat + sysctl" || echo "probe: /proc/meminfo" ;;
    disk)     echo "probe: df -P /" ;;
    version)  echo "payload version" ;;
    dir)      echo "payload cwd, else pwd" ;;
    git)      echo "probe: .git/HEAD (git on the odd case); none outside a repo or on a detached HEAD" ;;
    pr)       echo "payload pr.number" ;;
    worktree) echo "payload workspace.git_worktree / worktree.name" ;;
    session)  echo "payload session_name" ;;
    email)    echo "payload account.email (the claude auth status fallback is skipped by --doctor)" ;;
    date|clock) echo "always" ;;
    mcp)      echo "~/.claude.json mcpServers: remote, or with a running process" ;;
    agents)   echo "agent registry: $AGENTS_FILE$([ -f "$AGENTS_FILE" ] || echo ' (missing)')" ;;
    resume)   echo "payload session_id / session_name" ;;
    services)
      if ! command -v systemctl >/dev/null 2>&1; then echo "systemctl not installed (Linux only)"
      elif [ ! -r "$SVC_CONFIG" ]; then echo "no service list: $SVC_CONFIG"
      else echo "systemctl show, units from $SVC_CONFIG"
      fi ;;
    ssh)      echo "probe: who (remote logins)" ;;
    cron)     echo "probe: crontab -l" ;;
    ports)    [ "$OS" = Darwin ] && echo "probe: lsof, listeners on 3000-9999" || echo "probe: ss, listeners on 3000-9999" ;;
    local:*)  echo "local.sh: agentline_seg ${1#local:}" ;;
    *)        echo "" ;;
  esac
}
if [ -n "$_AL_DOCTOR" ]; then
  echo "agentline doctor"
  echo
  echo "environment"
  printf '  %-16s %s\n' script "$0" \
    bash "${BASH_VERSION}$([ "$_fast_time" = 1 ] || echo ' (< 5.0: a cached tick forks date twice)')" \
    os "$OS" \
    python3 "$(command -v python3 || echo 'NOT FOUND: payload parse and layout fail')" \
    timeout "${_TIMEOUT:-none: git status counts are skipped, probes run unguarded}" \
    locale "LC_ALL=${LC_ALL-} LANG=${LANG-}" \
    COLUMNS "${COLUMNS:-unset (Claude Code sets it for the status line)}" \
    width "$STATUSLINE_WIDTH$([ "$_fit" = 1 ] && echo ', fit mode' || echo ', no fit: lines 1-2 are never trimmed')" \
    layout "${AGENTLINE_LAYOUT:-default}" \
    drop "${AGENTLINE_DROP-default}" \
    links "$([ "$_links" = 1 ] && echo on || echo 'off (AGENTLINE_LINKS=0 or a multiplexer)')" \
    theme "$_AL_THEME$([ -n "${NO_COLOR-}" ] && echo ' (NO_COLOR is set)')" \
    glyphs "$_AL_GLYPHS"
  _dt_pl="stdin, ${#input} bytes"
  [ -n "$_dt_sample" ] && _dt_pl="built-in sample (stdin is a terminal; pipe a payload in to diagnose it)"
  [ -z "$input" ] && _dt_pl="empty stdin"
  [ -n "$payload_err" ] && _dt_pl="$_dt_pl — does NOT decode as a JSON object"
  printf '  %-16s %s\n' payload "$_dt_pl" "claude code" "${version:-absent in the payload}"
  echo
  echo "cache"
  if [ -d "$CACHE_DIR" ]; then
    _dt_ls=$(ls -ld "$CACHE_DIR" 2>/dev/null)
    printf '  %-16s %s\n' dir "$CACHE_DIR" "state" "${_dt_ls%% *}, $([ "$_dt_cache_ok" = 1 ] && echo 'trusted: caching on' || echo 'FAILED the owner/symlink check: caching off, every tick is a full render')"
  else
    printf '  %-16s %s\n' dir "$CACHE_DIR (missing; the next render creates it)"
  fi
  printf '  %-16s %s\n' ttl "render ${CACHE_TTL}s, host probes ${PROBE_TTL}s (both bypassed by --doctor)"
  echo
  echo "settings (${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json)"
  python3 -I -c "$_AL_DOCTOR_PY" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" 2>/dev/null
  # agentline-run is not a setting: installed beside this script, and on
  # PATH only after install.sh --link-bin.
  _dt_run="$HOME/.claude/agentline/agentline-run"
  if [ -x "$_dt_run" ]; then
    _dt_on=$(command -v agentline-run 2>/dev/null)
    printf '  %-16s %s\n' agentline-run "$_dt_run, $([ -n "$_dt_on" ] && echo "on PATH as $_dt_on" || echo 'not on PATH (install.sh --link-bin)')"
  else
    printf '  %-16s %s\n' agentline-run "not installed (re-run install.sh)"
  fi
  echo
  echo "timings (one cold render, ms)"
  _dt_prev=""; _dt_first=""
  while read -r _dt_n _dt_t; do
    case "$_dt_t" in ''|*[!0-9]*) continue ;; esac
    if [ -n "$_dt_prev" ]; then
      _dt_us=$(( _dt_t - _dt_prev ))
      printf '  %-36s %4d.%d\n' "$_dt_n" $(( _dt_us / 1000 )) $(( _dt_us % 1000 / 100 ))
    else
      _dt_first="$_dt_t"
    fi
    _dt_prev="$_dt_t"
  done <<< "$_dt_log"
  if [ -n "$_dt_first" ]; then
    _dt_us=$(( _dt_prev - _dt_first ))
    printf '  %-36s %4d.%d\n' total $(( _dt_us / 1000 )) $(( _dt_us % 1000 / 100 ))
  fi
  [ "${BASH_VERSINFO[0]:-0}" -ge 5 ] || echo "  (bash < 5: each mark starts a python3, ~20 ms, counted in the phase it ends)"
  echo
  echo "host probes (empty: the probe returned nothing)"
  # The service panel is built with its colours inside; mono (NO_COLOR)
  # strips them here as it does from the render.
  for _v in $PROBE_VARS active_agents agents_done; do
    _mono_out="${!_v}"
    [ "$_AL_THEME" = mono ] && _mono_strip "$_mono_out"
    printf '  %-16s %b\n' "$_v" "$_mono_out"
  done
  echo
  echo "segments (shown = emitted; at a narrow width the layout may still drop it, see AGENTLINE_DROP)"
  _dt_lay=",${AGENTLINE_LAYOUT:-$_lay_def},"; _dt_lay="${_dt_lay//[\/ ]/,}"
  for _n in ${_lay_def//[\/,]/ }; do
    _dt_s=hidden; _dt_have "$_n" && _dt_s=shown
    _dt_note=""
    case "$_dt_lay" in *",$_n,"*) ;; *) _dt_note=" [not in AGENTLINE_LAYOUT]" ;; esac
    _dt_w=$(_dt_why "$_n")
    # A hidden payload segment: its field was not in the payload.
    case "$_dt_s:$_dt_w" in "hidden:payload "*) _dt_w="absent: ${_dt_w#payload }" ;; esac
    printf '  %-9s %-7s %s%s\n' "$_n" "$_dt_s" "$_dt_w" "$_dt_note"
    # The counts beside the branch are the git row's most asked-about part,
    # and they go missing for many reasons: the gate above left one.
    if [ "$_n" = git ]; then
      _dt_w="$_git_why"
      [ "$_dt_w" = back-off ] && _dt_w="backed off after a slow repo (git status timed out) until $(fmt_epoch "$_git_why_until" '%H:%M:%S')"
      _dt_s=hidden
      if [ -n "$git_ab$git_dirty" ]; then
        _dt_s=shown; _dt_w="${git_ab}${git_ab:+${git_dirty:+ }}${git_dirty}"
        case "$_git_why" in
          "no upstream"*) _dt_w="$_dt_w; no upstream (no ahead/behind)" ;;
          "upstream gone"*) _dt_w="$_dt_w; upstream gone (no ahead/behind)" ;;
        esac
      fi
      printf '  %-9s %-7s %s\n' counts "$_dt_s" "git status: $_dt_w"
    fi
  done
  echo
  echo "render"
  printf '%b\n' "$out"
  exit 0
fi
printf "%b" "$out"
