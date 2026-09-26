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
input=$(cat)

# === Live clock fast path ===
# Claude Code re-invokes this script every `statusLine.refreshInterval`
# seconds (install.sh sets 1), which is what makes the HH:MM:SS clock on
# line 2 tick in real time instead of freezing between conversation events.
# A full render costs ~20 subprocesses — far too much to pay once a second —
# so the finished output is cached with the clock replaced by a placeholder.
# While the payload is byte-identical and the cache is younger than
# $AGENTLINE_CACHE_TTL, a tick only substitutes the current time and prints:
# zero subprocesses on bash >= 5.0. Any real event (token counts, cost, cwd,
# model) changes the payload and invalidates the cache on the spot, so no
# segment is ever shown stale across a state change.
CLOCK_TOKEN='@@AGENTLINE_CLOCK@@'
CACHE_TTL="${AGENTLINE_CACHE_TTL:-5}"

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
[ -d "$CACHE_DIR" ] || mkdir -m 700 "$CACHE_DIR" 2>/dev/null
if [ -d "$CACHE_DIR" ] && [ ! -L "$CACHE_DIR" ] && [ -O "$CACHE_DIR" ]; then
  CACHE_BASE="${CACHE_DIR}/render_${_sid}"
fi

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

_tick_now
# The cache files are read with the `read` builtin, not `$(<file)`: bash 5
# serves `$(<file)` in-process, but bash 3.2 (macOS) forks a subshell for
# each, which cost this path two forks a second. `IFS= read -r -d ''` takes
# the file verbatim; its non-zero status at end of file is expected.
_prev_payload=""
_cached=""
if [ -n "$CACHE_BASE" ] && [ -f "${CACHE_BASE}.payload" ]; then
  IFS= read -r -d '' _prev_payload < "${CACHE_BASE}.payload"
fi
if [ -n "$_prev_payload" ] && [ "$_prev_payload" = "$input" ] && [ -f "${CACHE_BASE}.render" ]; then
  IFS= read -r -d '' _cached < "${CACHE_BASE}.render"
  _cached_ts="${_cached%%$'\n'*}"
  _cached_body="${_cached#*$'\n'}"
  case "$_cached_ts" in
    ''|*[!0-9]*) ;;
    *)
      if [ -n "$_cached_body" ] && [ $(( _now_epoch - _cached_ts )) -lt "$CACHE_TTL" ]; then
        _tick_out="${_cached_body//$CLOCK_TOKEN/$_now_clock}"
        case "$_tick_out" in
          *'@@AGENTLINE_ANIM_MAX@@'*)
            _anim_frame max rainbow
            _tick_out="${_tick_out//@@AGENTLINE_ANIM_MAX@@/$_anim_out}" ;;
        esac
        case "$_tick_out" in
          *'@@AGENTLINE_ANIM_ULTRA@@'*)
            _anim_frame ultracode violet
            _tick_out="${_tick_out//@@AGENTLINE_ANIM_ULTRA@@/$_anim_out}" ;;
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
try:
    d = json.loads(raw) if raw.strip() else {}
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

# Whether to force the context warning, decided here rather than by comparing
# the window size in bash: `[ -gt ]` fails with "integer expression expected"
# on a size past 64 bits ("9999999999999999999999999"), and python compares
# any size. exceeds_200k_tokens is Claude Code's own fixed-threshold flag
# (input + output of the last response > 200k, whatever the window); only a
# strict JSON true counts, and only on a window larger than 200k — on a 200k
# window it just means "about 100%" again.
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

fields = {
    # cwd stays raw: it is a filesystem path (git, the probe-cache key, the
    # transcript lookup). Only its displayed form, $folder, is cleaned.
    'cwd': g('cwd'),
    'model_raw': mid,
    'model': clean(model),
    'used_pct': num(g('context_window', 'used_percentage')),
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
    'session_name': clean(g('session_name')),
    # session_id is also a path component (the transcript fallback), so it
    # stays raw; the resume command shows a cleaned copy.
    'session_id': g('session_id'),
    'fast': g('fast_mode'),
    'version': clean(g('version')),
    'payload_email': clean(g('account', 'email')),
    'payload_transcript': g('transcript_path'),
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
eval "$(PAYLOAD="$input" python3 -c "$_AL_PARSER")"
[ -z "$cwd" ] && cwd="$(pwd)"

# === Platform detection ===
# One source tree runs on macOS laptops and Linux servers. Resolve the
# platform once here; never probe per call site.
OS="$(uname -s)"

# ($AGENTLINE_TZ is applied up in the fast path, before any clock is read.)

# Epoch -> formatted date. GNU date wants `-d @<ts>`, BSD date wants `-r <ts>`.
# The flavour is decided once, at definition time, not on every invocation.
if date -r 0 >/dev/null 2>&1; then
  fmt_epoch() { date -r "$1" "+$2" 2>/dev/null; }   # BSD / macOS
else
  fmt_epoch() { date -d "@$1" "+$2" 2>/dev/null; }  # GNU / Linux
fi

# Reverse a file: GNU has tac, BSD/macOS has tail -r.
if command -v tac >/dev/null 2>&1; then
  revcat() { tac "$1" 2>/dev/null; }
else
  revcat() { tail -r "$1" 2>/dev/null; }
fi

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
PROBE_VARS="active_mcps cpu_usage cron_count dev_ports disk_pct git_branch git_repo mem_used_gb ssh_count svc_panel"
_probes_fresh=0
if [ -n "$CACHE_BASE" ] && [ -f "${CACHE_BASE}.probes" ]; then
  _pc=$(<"${CACHE_BASE}.probes")
  _pc_ts="${_pc%%$'\n'*}";   _pc_rest="${_pc#*$'\n'}"
  _pc_cwd="${_pc_rest%%$'\n'*}"; _pc_body="${_pc_rest#*$'\n'}"
  case "$_pc_ts" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$_pc_cwd" = "$cwd" ] && [ $(( _now_epoch - _pc_ts )) -lt "$PROBE_TTL" ]; then
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
  cpu_line=$(top -l 1 -n 0 2>/dev/null | grep "CPU usage")
  if [ -n "$cpu_line" ]; then
    idle=$(echo "$cpu_line" | awk -F',' '{print $3}' | grep -oE '[0-9]+(\.[0-9]+)?')
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

# Git branch
git_branch=""
git_repo=""
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
  git_branch=$(cd "$cwd" 2>/dev/null && git branch --show-current 2>/dev/null)
  # owner/repo from the origin remote, shown to the left of the branch so it is
  # obvious which repository the branch belongs to. Handles both SSH and HTTPS
  # remotes; stays empty when there is no origin.
  if [ -n "$git_branch" ]; then
    git_repo=$(cd "$cwd" 2>/dev/null && git remote get-url origin 2>/dev/null \
      | sed -E 's#^git@[^:]+:#/#; s#^[a-z]+://[^/]+/#/#; s#\.git$##; s#^/##')
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
active_mcps=$(python3 -c "$_AL_PY" "$cwd")

fi  # end of throttled host probes (part 1)

# Side files written by the optional hooks (hooks/*.sh) live in one shared
# directory, /tmp unless $AGENTLINE_TMP names another. The hooks resolve the
# same variable, so reader and writers always agree; a per-user or per-test
# directory keeps two users on one host — or a test run — from reading each
# other's counters. The agent registry also honours CLAUDE_AGENTS_FILE, the
# override agentline-agent.sh has always accepted: the reader used to ignore
# it, so a relocated registry silently emptied the 🤖 segment.
AGENTLINE_TMP="${AGENTLINE_TMP:-/tmp}"
AGENTS_FILE="${CLAUDE_AGENTS_FILE:-$AGENTLINE_TMP/claude_agents.txt}"

# Active agents (from hook-written file) — never throttled, see PROBE_VARS.
active_agents=""
if [ -f "$AGENTS_FILE" ]; then
  now=$(date +%s)
  active_agents=$(awk -v now="$now" '{
    age = now - $1
    if (age < 300) {
      label = substr($0, index($0,$2))
      if (length(label) > 25) label = substr(label,1,22) "..."
      printf "%s · ", label
    }
  }' "$AGENTS_FILE" | sed 's/ · $//')
fi

# Home-relative path (~/projects/agentline) rather than the bare folder name.
# Paths outside $HOME are shown absolute.
case "$cwd" in
  "$HOME")   folder="~" ;;
  "$HOME"/*) folder="~${cwd#"$HOME"}" ;;
  *)         folder="$cwd" ;;
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
# Socket enumeration is platform-specific -- `ss` on Linux, `lsof` on macOS -- so
# each branch normalizes to "proc:port" pairs and the labeling below is shared.
if command -v ss >/dev/null 2>&1; then
  dev_raw=$(ss -ltnp 2>/dev/null | awk '
    /users:\(\(/ {
      n = split($4, a, ":"); port = a[n]
      if (port ~ /^[0-9]+$/ && port >= 3000 && port <= 9999) {
        match($0, /users:\(\("[^"]+"/)
        seen[port] = substr($0, RSTART+9, RLENGTH-10)
      }
    }
    END { for (p in seen) printf "%s:%s ", seen[p], p }')
else
  dev_raw=$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {
      n = split($9, a, ":"); port = a[n]
      if (port ~ /^[0-9]+$/ && port >= 3000 && port <= 9999) {
        seen[port] = $1
      }
    }
    END { for (p in seen) printf "%s:%s ", seen[p], p }')
fi
dev_ports=$(printf '%s' "$dev_raw" | python3 -c "
import sys
for item in sys.stdin.read().split():
    if item and ':' in item:
        proc, port = item.rsplit(':', 1)
        proc = proc.strip('()')
        print(f'{proc}({port})', end=' ')
" | sed 's/ $//')

# Disk usage (root fs). Some mounts report "-" instead of a percentage; the
# numeric guard hides the segment there rather than tripping the -ge test below.
disk_pct=$(df -P / 2>/dev/null | awk 'NR==2 {gsub("%","",$5); if ($5 ~ /^[0-9]+$/) print $5}')

# Service health mini-panel (name + status per service).
# Machine-local config, one "systemd-unit-name:Label" per line; # and blanks ignored.
# Kept out of the repo on purpose so each machine can list its own units.
SVC_CONFIG="${AGENTLINE_SERVICES:-$HOME/.claude/agentline-services.conf}"
svc_panel=""
# systemd is Linux-only. On macOS the panel stays empty and line 4 degrades cleanly.
if command -v systemctl >/dev/null 2>&1 && [ -r "$SVC_CONFIG" ]; then
  while IFS=: read -r svc label; do
    case "$svc" in ''|\#*) continue ;; esac
    [ -z "$label" ] && label="$svc"
    # The label sits between real escapes, so it is cleaned here rather
    # than with the other host strings below ($svc_panel keeps its colours).
    label="${label//[[:cntrl:]]/}"; label="${label//\\/}"
    label="${label//${_C1_LEAD}[${_C1_LO}-${_C1_HI}]/}"
    # Skip services not defined on this machine (portability)
    systemctl cat "$svc" >/dev/null 2>&1 || continue
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      entry="\033[2m${label} ✓\033[0m"
    else
      entry="\033[1;31m${label} ✗\033[0m"
    fi
    svc_panel="${svc_panel:+${svc_panel} \033[2m·\033[0m }${entry}"
  done < "$SVC_CONFIG"
fi

fi  # end of throttled host probes (part 2)

# Persist the probe results for the next $PROBE_TTL seconds. `printf -v %q` is
# a builtin, so quoting the values costs no fork, and it round-trips the ANSI
# escapes in $svc_panel through eval intact. Skipped when the probes came from
# the cache (nothing new to store) or when the cache directory failed its
# ownership check at stage 0.
if [ "$_probes_fresh" != 1 ] && [ -n "$CACHE_BASE" ]; then
  _pc_out=""
  for _v in $PROBE_VARS; do
    printf -v _q '%q' "${!_v}"
    _pc_out="${_pc_out}${_v}=${_q}"$'\n'
  done
  printf '%s\n%s\n%s' "$_now_epoch" "$cwd" "$_pc_out" > "${CACHE_BASE}.probes" 2>/dev/null
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
for _v in git_branch git_repo folder active_mcps active_agents dev_ports; do
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

color_pct() {
  local p="$1" high="${2:-90}" mid="${3:-70}"
  awk -v p="$p" -v h="$high" -v m="$mid" 'BEGIN {
    if (p >= h) printf "\033[1;31m";
    else if (p >= m) printf "\033[1;33m";
    else printf "\033[1;32m";
  }'
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
[ -f "$AGENTLINE_LOCAL" ] && . "$AGENTLINE_LOCAL"

# === Format Helpers ===
effort=""
case "$effort_raw" in
  low)    effort="🟢${DIM}low${RESET}" ;;
  medium) effort="🟡${CYAN}med${RESET}" ;;
  high)   effort="🟠${ORANGE}high${RESET}" ;;
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
      tp="$HOME/.claude/projects/$(printf '%s' "$cwd" | sed 's|[^a-zA-Z0-9]|-|g')/${session_id}.jsonl"
    fi
    if [ -f "$tp" ]; then
      marker=$(revcat "$tp" | grep -m1 -oE '"attachment":\{"type":"ultra_effort_(enter|exit)"|<local-command-stdout>Set effort level to [a-z]+')
      case "$marker" in
        *ultra_effort_enter*|*"to ultracode") ultracode=1 ;;
      esac
    fi
    if [ -n "$ultracode" ]; then
      # Mirrors the /effort picker's violet-ripple, rotated one wheel step
      # per tick by _anim_frame/_VIOLET_WHEEL above instead of a single
      # frozen frame. Token substituted at print time, same as $CLOCK_TOKEN.
      effort="@@AGENTLINE_ANIM_ULTRA@@"
    else
      effort="🔴${RED}xhigh${RESET}"
    fi ;;
  # max mirrors the picker's rainbow-animated look with a live-ticking wheel.
  max)    effort="@@AGENTLINE_ANIM_MAX@@" ;;
  *)      [ -n "$effort_raw" ] && effort="⚙️  $effort_raw" ;;
esac

cost_fmt=""
[ -n "$cost" ] && cost_fmt=$(printf "%.2f" "$cost")

duration_fmt=""
if [ -n "$duration_ms" ]; then
  total_sec=$(awk -v ms="$duration_ms" 'BEGIN {printf "%d", ms/1000}')
  h=$((total_sec / 3600))
  m=$(((total_sec % 3600) / 60))
  [ $h -gt 0 ] && duration_fmt="${h}h${m}m" || duration_fmt="${m}m"
fi

format_tokens() {
  local n="$1"
  if [ -z "$n" ]; then echo ""
  elif awk -v n="$n" 'BEGIN {exit !(n >= 1000000)}'; then awk -v n="$n" 'BEGIN {printf "%.1fm", n/1000000}'
  elif awk -v n="$n" 'BEGIN {exit !(n >= 1000)}'; then awk -v n="$n" 'BEGIN {printf "%.1fk", n/1000}'
  else echo "$n"
  fi
}
tokens_in_fmt=$(format_tokens "$tokens_in")
tokens_out_fmt=$(format_tokens "$tokens_out")

fmt_reset() {
  local ts="$1"; [ -z "$ts" ] && return
  case "$ts" in
    ''|*[!0-9]*) fmt_epoch "$ts" "%H:%M"; return ;;
  esac
  local now diff h m
  now=$(date +%s)
  diff=$(( ts - now ))
  [ "$diff" -le 0 ] && return
  h=$((diff / 3600)); m=$(((diff % 3600) / 60))
  if [ $h -gt 0 ]; then echo "${h}h${m}m"; else echo "${m}m"; fi
}
fmt_reset_week() {
  # Zero-padded %d/%m is the only form both GNU and BSD date support (the
  # GNU-only %-d no-pad flag breaks on macOS); strip the padding afterwards.
  local ts="$1"; [ -z "$ts" ] && return
  fmt_epoch "$ts" "%d/%m" | sed 's/^0//; s#/0#/#'
}
five_hour_reset_fmt=$(fmt_reset "$five_hour_reset")
seven_day_reset_fmt=$(fmt_reset_week "$seven_day_reset")

thinking_icon=""
[ "$thinking" = "True" ] && thinking_icon="🧠"

fast_icon=""
[ "$fast" = "True" ] && fast_icon="⚡Fast"

# === Model Color ===
model_color="$CYAN"
case "$model_raw" in
  claude-fable*|claude-mythos*)
    # Truecolor amber→orange gradient across the model name
    IFS= read -r -d '' _AL_PY <<'PYEOF'
import sys
s = sys.argv[1]
start, end = (255, 215, 90), (255, 125, 25)
n = max(len(s) - 1, 1)
out = []
for i, ch in enumerate(s):
    r = int(start[0] + (end[0]-start[0]) * i / n)
    g = int(start[1] + (end[1]-start[1]) * i / n)
    b = int(start[2] + (end[2]-start[2]) * i / n)
    out.append(f'\033[1;38;2;{r};{g};{b}m{ch}')
print(''.join(out))
PYEOF
    model=$(python3 -c "$_AL_PY" "✦ ${model}")
    model_color="" ;;
  claude-opus*)  model_color="$MAGENTA" ;;
  claude-sonnet*) model_color="$CYAN" ;;
  claude-haiku*) model_color="$GREEN" ;;
esac

session_name_fmt=""
if [ -n "$session_name" ]; then
  [ ${#session_name} -gt 30 ] && session_name_fmt="${session_name:0:27}..." || session_name_fmt="$session_name"
fi

lines_fmt=""
if [ -n "$lines_added" ] || [ -n "$lines_removed" ]; then
  lines_fmt="\033[1;32m+${lines_added:-0}\033[0m \033[1;31m-${lines_removed:-0}\033[0m"
fi

# LC_ALL=C pins the day abbreviation to English regardless of the host locale.
date_str=$(LC_ALL=C date "+%d/%m/%Y %a")
# The clock is rendered as a placeholder so the cached line can be re-stamped
# with the live time on every tick; it is substituted just before printing.
time_str="$CLOCK_TOKEN"

# Word counts from hook
words_in_w=""
words_out_w=""
if [ -f "$AGENTLINE_TMP/claude_wordcount.txt" ]; then
  wc_line=$(cat "$AGENTLINE_TMP/claude_wordcount.txt")
  wi=$(echo "$wc_line" | awk '{print $1}')
  wo=$(echo "$wc_line" | awk '{print $2}')
  [ -n "$wi" ] && [ "$wi" != "0" ] && words_in_w=$(awk -v n="$wi" 'BEGIN {
    if (n >= 1000) printf "%.1fk", n/1000; else printf "%d", n
  }')
  [ -n "$wo" ] && [ "$wo" != "0" ] && words_out_w=$(awk -v n="$wo" 'BEGIN {
    if (n >= 1000) printf "%.1fk", n/1000; else printf "%d", n
  }')
fi

# === Build Output ===
P=" ${DIM}│${RESET} "

# Line 1: model first, then stats. A payload that did not decode leads with a
# dim marker instead of silently losing the model and context segments; it is
# prepended, not a replacement, because the host and session-independent
# segments after it are still correct.
line1=""
[ -n "$payload_err" ] && line1="${DIM}⚠ payload${RESET}"
if [ -n "$model" ]; then
  line1="${line1:+${line1}${P}}${model_color}${model}${thinking_icon:+ ${thinking_icon}}${RESET}"
fi
[ -n "$effort" ]         && line1="${line1:+${line1}${P}}${effort}"
[ -n "$fast_icon" ]      && line1="${line1:+${line1}${P}}${YELLOW}${fast_icon}${RESET}"
if [ -n "$used_pct" ]; then
  c=$(color_pct "$used_pct" 80 60)
  ctx_icon="📊"
  ctx_tag=""
  if awk -v p="$used_pct" 'BEGIN {exit !(p >= 80)}'; then
    ctx_icon="⚠️ "
  elif [ -n "$warn_200k" ]; then
    # On a 1M-window model 25% is already past 200k tokens — where long-context
    # pricing and quality change — yet the percentage alone reads as harmless.
    # Claude Code's exceeds_200k_tokens flag says so directly, so it forces
    # the warning, in yellow (this branch is below the 80% red), with a tag
    # saying why. The parser has already ignored it on a 200k window, where
    # it is just "about 100%" again.
    ctx_icon="⚠️ "
    c="$YELLOW"
    ctx_tag=" ${DIM}>200k${RESET}"
  fi
  line1="${line1:+${line1}${P}}${c}${ctx_icon} $(printf '%.0f' "$used_pct")%${RESET}${ctx_tag}"
fi
if [ -n "$five_hour" ]; then
  c=$(color_pct "$five_hour" 90 70)
  reset_part=""; [ -n "$five_hour_reset_fmt" ] && reset_part="${DIM}↻${five_hour_reset_fmt}${RESET}"
  line1="${line1:+${line1}${P}}${c}S:$(printf '%.0f' $five_hour)%${RESET}${reset_part:+ }${reset_part}"
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
      python3 - "$_cfg_dir" "$usage_cache" "$usage_claim" >/dev/null 2>&1 <<'PYEOF' &
import json, os, signal, sys, urllib.request
cfg, cache, claim = sys.argv[1:4]
try:
    os.setsid()
except OSError:
    pass
def _expired(*_):
    raise TimeoutError()
signal.signal(signal.SIGALRM, _expired)
signal.alarm(20)
out = ''
try:
    cred = json.load(open(os.path.join(os.path.expanduser(cfg), '.credentials.json')))['claudeAiOauth']
    req = urllib.request.Request('https://api.anthropic.com/api/oauth/usage', headers={
        'Authorization': 'Bearer ' + cred['accessToken'],
        'anthropic-beta': 'oauth-2025-04-20',
        'Accept': 'application/json',
    })
    d = json.load(urllib.request.urlopen(req, timeout=10))
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
  c=$(color_pct "$seven_day" 90 70)
  week_body="${c}W:$(printf '%.0f' $seven_day)%${RESET}"
fi
case "$seven_day_top" in
  ''|*[!0-9.]*) ;;
  *) week_body="${week_body:+${week_body} }${ORANGE}F:$(printf '%.0f' "$seven_day_top")%${RESET}" ;;
esac
if [ -n "$week_body" ]; then
  reset_part=""; [ -n "$seven_day_reset_fmt" ] && reset_part="${DIM}↻${seven_day_reset_fmt}${RESET}"
  line1="${line1:+${line1}${P}}${week_body}${reset_part:+ }${reset_part}"
fi
[ -n "$cost_fmt" ]       && line1="${line1:+${line1}${P}}💰 \$${cost_fmt}"
[ -n "$duration_fmt" ]   && line1="${line1:+${line1}${P}}⏱️  ${duration_fmt}"
[ -n "$tokens_in_fmt" ]  && line1="${line1:+${line1}${P}}📥 ${tokens_in_fmt}"
[ -n "$tokens_out_fmt" ] && line1="${line1:+${line1}${P}}📤 ${tokens_out_fmt}"
# Word counter (optional hook): ↑ words you typed, ↓ words Claude wrote.
if [ -n "$words_in_w" ] || [ -n "$words_out_w" ]; then
  line1="${line1:+${line1}${P}}🔤 ${DIM}↑${RESET}${words_in_w:-0} ${DIM}↓${RESET}${words_out_w:-0}"
fi
[ -n "$lines_fmt" ]      && line1="${line1:+${line1}${P}}📝 ${lines_fmt}"
[ -n "$cpu_usage" ]      && line1="${line1:+${line1}${P}}🔥 ${cpu_usage}"
[ -n "$mem_used_gb" ]    && line1="${line1:+${line1}${P}}💾 ${mem_used_gb}"
if [ -n "$disk_pct" ]; then
  if [ "$disk_pct" -ge 80 ]; then
    line1="${line1:+${line1}${P}}${RED}⚠️ 💽 ${disk_pct}%${RESET}"
  else
    c=$(color_pct "$disk_pct" 90 80)
    line1="${line1:+${line1}${P}}${c}💽 ${disk_pct}%${RESET}"
  fi
fi

# Line 2: env info
line2=""
[ -n "$version" ] && line2="${DIM}v${version}${RESET}"
[ -n "$folder" ]            && line2="${line2:+${line2}${P}}${BLUE}${folder}${RESET}"
[ -n "$git_branch" ]       && line2="${line2:+${line2}${P}}${MAGENTA}🌿 ${RESET}${DIM}${git_repo:+${git_repo}@}${RESET}${MAGENTA}${git_branch}${RESET}"
[ -n "$session_name_fmt" ] && line2="${line2:+${line2}${P}}🏷️  ${session_name_fmt}"

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
    account_email=$(claude auth status --json 2>/dev/null | python3 -c "
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

IFS= read -r -d '' _AL_PY <<'PYEOF'
import re, sys
email = sys.argv[1]
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
    print(f'{local_first}{local_mid}{local_last}{at}{dom_first}{dom_mid}{dom_last}{tld}')
else:
    print(email)
PYEOF
masked_email=$(python3 -c "$_AL_PY" "$account_email")
[ -n "$masked_email" ] && line2="${line2:+${line2}${P}}🤖 ${DIM}${masked_email}${RESET}"
line2="${line2:+${line2}${P}}${DIM}${date_str}${RESET}${P}${CYAN}${time_str}${RESET}"

# Line 3 — Claude layer: MCP servers + active agents + resume command
line3=""
if [ -n "$active_mcps" ]; then
  line3="⚙️  ${DIM}${active_mcps}${RESET}"
fi
if [ -n "$active_agents" ]; then
  line3="${line3:+${line3}${P}}🤖 ${YELLOW}${active_agents}${RESET}"
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
[ -n "$resume_cmd" ] && line3="${line3:+${line3}${P}}♻️  ${DIM}${resume_cmd}${RESET}"

# Line 4 — System layer: service health + ssh + cron + dev servers
line4=""
[ -n "$svc_panel" ] && line4="🛡️ ${svc_panel}"
if [ -n "$ssh_count" ] && [ "$ssh_count" -gt 0 ]; then
  ssh_c="$DIM"; [ "$ssh_count" -gt 1 ] && ssh_c="$YELLOW"
  line4="${line4:+${line4}${P}}🔐 ${ssh_c}ssh:${ssh_count}${RESET}"
fi
if [ -n "$cron_count" ] && [ "$cron_count" -gt 0 ]; then
  line4="${line4:+${line4}${P}}⏰ ${DIM}cron:${cron_count}${RESET}"
fi
if [ -n "$dev_ports" ]; then
  line4="${line4:+${line4}${P}}🌐 ${DIM}${dev_ports}${RESET}"
fi

# Lines 3 and 4 are separate layers (Claude vs system). On a quiet host the
# split wastes a row, so they are joined when the combined width fits. On a
# busy host either line can outgrow the terminal, so each is wrapped onto
# continuation rows at segment (│) boundaries instead of overflowing — a
# segment is never split internally. Width is measured after stripping colour
# escapes, counting wide glyphs as two cells; tune with $AGENTLINE_WIDTH.
STATUSLINE_WIDTH="${AGENTLINE_WIDTH:-120}"
IFS= read -r -d '' _AL_PY <<'PYEOF'
import re, sys, unicodedata
width, sep, line3, line4 = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]

def vis(s):
    # Colour codes are still in backslash-escape form here (rendered later by
    # printf %b), so strip the literal \033[..m sequences before measuring.
    s = re.sub(r'\\033\[[0-9;]*m', '', s)
    return sum(2 if unicodedata.east_asian_width(c) in ('W', 'F') else 1 for c in s)

def wrap(line):
    if not line:
        return []
    if vis(line) <= width:
        return [line]
    rows, cur = [], ''
    for seg in line.split(sep):
        cand = cur + sep + seg if cur else seg
        if cur and vis(cand) > width:
            rows.append(cur)
            cur = seg
        else:
            cur = cand
    if cur:
        rows.append(cur)
    return rows

if line3 and line4 and vis(line3 + sep + line4) <= width:
    rows = [line3 + sep + line4]
else:
    rows = wrap(line3) + wrap(line4)
sys.stdout.write('\n'.join(rows))
PYEOF
layer_rows=$(python3 -c "$_AL_PY" "$STATUSLINE_WIDTH" "$P" "$line3" "$line4")

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

# Print only non-empty rows, so lines 3 and 4 collapse away instead of gaps
out="${line1}\n${line2}"
while IFS= read -r row; do
  [ -n "$row" ] && out="${out}\n${row}"
done <<< "$layer_rows"

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
      printf '%s' "$input" > "${CACHE_BASE}.payload" 2>/dev/null
      printf '%s\n%s' "$_now_epoch" "$out" > "${CACHE_BASE}.render" 2>/dev/null
    fi
    ;;
esac
out="${out//$CLOCK_TOKEN/$_now_clock}"
case "$out" in
  *'@@AGENTLINE_ANIM_MAX@@'*)
    _anim_frame max rainbow
    out="${out//@@AGENTLINE_ANIM_MAX@@/$_anim_out}" ;;
esac
case "$out" in
  *'@@AGENTLINE_ANIM_ULTRA@@'*)
    _anim_frame ultracode violet
    out="${out//@@AGENTLINE_ANIM_ULTRA@@/$_anim_out}" ;;
esac
printf "%b" "$out"
