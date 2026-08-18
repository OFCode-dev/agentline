#!/bin/bash
# agentline — a four-line, zero-dependency status bar for Claude Code.
# https://github.com/OFCode-dev/agentline
#
# Claude Code pipes its statusLine JSON payload to stdin; this script renders
# up to four lines: session stats, environment, Claude layer, system layer.
# Every segment degrades gracefully — anything it cannot measure disappears
# instead of erroring.
input=$(cat)

# === JSON Parsing ===
# One python3 pass extracts every payload field as shell-quoted assignments;
# the former per-field helper spawned 20+ interpreters per render, and this is
# the hottest path in the script. shlex.quote makes the eval safe for any
# payload value (quotes, spaces, newlines).
eval "$(PAYLOAD="$input" python3 - <<'PYEOF'
import json, os, re, shlex
try:
    d = json.loads(os.environ.get('PAYLOAD', '') or '{}')
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}

def g(*keys):
    v = d
    for k in keys:
        v = v.get(k) if isinstance(v, dict) else None
    return '' if v is None else v

# Model ids carry variant and build suffixes: "claude-opus-5[1m]" (1M context
# window) and dated builds like "claude-haiku-4-5-20251001". The match is
# therefore left-anchored only -- anchoring the tail made the [1m] variant fall
# through and print the raw id. Falls back to the payload's display_name, then
# to the raw id.
mid = str(g('model', 'id'))
m = re.match(r'claude-([a-z]+)-(\d+)(?:-(\d+))?', mid)
if m:
    ver = m.group(2) if m.group(3) is None else f'{m.group(2)}.{m.group(3)}'
    model = f'{m.group(1).capitalize()} {ver}'
else:
    model = str(g('model', 'display_name')) or mid

fields = {
    'cwd': g('cwd'),
    'model_raw': mid,
    'model': model,
    'used_pct': g('context_window', 'used_percentage'),
    'five_hour': g('rate_limits', 'five_hour', 'used_percentage'),
    'seven_day': g('rate_limits', 'seven_day', 'used_percentage'),
    'five_hour_reset': g('rate_limits', 'five_hour', 'resets_at'),
    'seven_day_reset': g('rate_limits', 'seven_day', 'resets_at'),
    'effort_raw': g('effort', 'level'),
    'cost': g('cost', 'total_cost_usd'),
    'duration_ms': g('cost', 'total_duration_ms'),
    'lines_added': g('cost', 'total_lines_added'),
    'lines_removed': g('cost', 'total_lines_removed'),
    'tokens_in': g('context_window', 'total_input_tokens'),
    'tokens_out': g('context_window', 'total_output_tokens'),
    'thinking': g('thinking', 'enabled'),
    'session_name': g('session_name'),
    'session_id': g('session_id'),
    'fast': g('fast_mode'),
    'version': g('version'),
    'payload_email': g('account', 'email'),
}
print('\n'.join(f'{k}={shlex.quote(str(v))}' for k, v in fields.items()))
PYEOF
)"
[ -z "$cwd" ] && cwd="$(pwd)"

# === Platform detection ===
# One source tree runs on macOS laptops and Linux servers. Resolve the
# platform once here; never probe per call site.
OS="$(uname -s)"

# Display timezone: system-local by default. Set $AGENTLINE_TZ (for example
# "Europe/Istanbul") to pin the clock to home time on remote UTC servers.
[ -n "$AGENTLINE_TZ" ] && export TZ="$AGENTLINE_TZ"

# Epoch -> formatted date. GNU date wants `-d @<ts>`, BSD date wants `-r <ts>`.
# The flavour is decided once, at definition time, not on every invocation.
if date -r 0 >/dev/null 2>&1; then
  fmt_epoch() { date -r "$1" "+$2" 2>/dev/null; }   # BSD / macOS
else
  fmt_epoch() { date -d "@$1" "+$2" 2>/dev/null; }  # GNU / Linux
fi

# === System Info ===
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
active_mcps=$(python3 - "$cwd" <<'PYEOF'
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
)

# Active agents (from hook-written file)
active_agents=""
if [ -f /tmp/claude_agents.txt ]; then
  now=$(date +%s)
  active_agents=$(awk -v now="$now" '{
    age = now - $1
    if (age < 300) {
      label = substr($0, index($0,$2))
      if (length(label) > 25) label = substr(label,1,22) "..."
      printf "%s · ", label
    }
  }' /tmp/claude_agents.txt | sed 's/ · $//')
fi

# Home-relative path (~/projects/agentline) rather than the bare folder name.
# Paths outside $HOME are shown absolute.
case "$cwd" in
  "$HOME")   folder="~" ;;
  "$HOME"/*) folder="~${cwd#"$HOME"}" ;;
  *)         folder="$cwd" ;;
esac

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
    # Skip services not defined on this machine (portability)
    systemctl cat "$svc" >/dev/null 2>&1 || continue
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      entry="\033[2;37m${label} ✓\033[0m"
    else
      entry="\033[1;31m${label} ✗\033[0m"
    fi
    svc_panel="${svc_panel:+${svc_panel} \033[2;37m·\033[0m }${entry}"
  done < "$SVC_CONFIG"
fi

# === Colors ===
RESET="\033[0m"
DIM="\033[2;37m"
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

# === Format Helpers ===
effort=""
case "$effort_raw" in
  low)    effort="🟢${DIM}low${RESET}" ;;
  medium) effort="🟡${CYAN}med${RESET}" ;;
  high)   effort="🟠${ORANGE}high${RESET}" ;;
  # The /effort scale runs low < medium < high < xhigh < max, with ultracode
  # as a side mode (xhigh + workflows). The payload reports ultracode as plain
  # "xhigh", so xhigh wears ultracode's violet-ripple styling (bold white on a
  # violet gradient) and max mirrors the picker's rainbow-animated, static.
  xhigh)  effort="🟣\033[1;38;2;255;255;255;48;2;62;22;118mx\033[48;2;82;37;149mh\033[48;2;101;51;179mi\033[48;2;121;66;210mg\033[48;2;140;80;240mh${RESET}" ;;
  max)    effort="🌈\033[1;38;2;255;107;107mm\033[38;2;243;249;157ma\033[38;2;122;162;247mx${RESET}" ;;
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
    model=$(python3 - "✦ ${model}" <<'PYEOF'
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
)
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
time_str=$(date "+%H:%M:%S")

# Word counts from hook
words_in_w=""
words_out_w=""
if [ -f /tmp/claude_wordcount.txt ]; then
  wc_line=$(cat /tmp/claude_wordcount.txt)
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

# Line 1: model first, then stats
line1=""
if [ -n "$model" ]; then
  line1="${model_color}${model}${thinking_icon:+ ${thinking_icon}}${RESET}"
fi
[ -n "$effort" ]         && line1="${line1:+${line1}${P}}${effort}"
[ -n "$fast_icon" ]      && line1="${line1:+${line1}${P}}${YELLOW}${fast_icon}${RESET}"
if [ -n "$used_pct" ]; then
  c=$(color_pct "$used_pct" 80 60)
  ctx_icon="📊"
  awk -v p="$used_pct" 'BEGIN {exit !(p >= 80)}' && ctx_icon="⚠️ "
  line1="${line1:+${line1}${P}}${c}${ctx_icon} $(printf '%.0f' $used_pct)%${RESET}"
fi
if [ -n "$five_hour" ]; then
  c=$(color_pct "$five_hour" 90 70)
  reset_part=""; [ -n "$five_hour_reset_fmt" ] && reset_part="${DIM}↻${five_hour_reset_fmt}${RESET}"
  line1="${line1:+${line1}${P}}${c}S:$(printf '%.0f' $five_hour)%${RESET}${reset_part:+ }${reset_part}"
fi
if [ -n "$seven_day" ]; then
  c=$(color_pct "$seven_day" 90 70)
  reset_part=""; [ -n "$seven_day_reset_fmt" ] && reset_part="${DIM}↻${seven_day_reset_fmt}${RESET}"
  line1="${line1:+${line1}${P}}${c}W:$(printf '%.0f' $seven_day)%${RESET}${reset_part:+ }${reset_part}"
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
account_email="$payload_email"
if [ -z "$account_email" ]; then
  auth_cache="${TMPDIR:-/tmp}/agentline-email-$(id -u 2>/dev/null || echo 0)"
  cache_age=999999
  if [ -f "$auth_cache" ]; then
    mtime=$(stat -c %Y "$auth_cache" 2>/dev/null || stat -f %m "$auth_cache" 2>/dev/null || echo 0)
    cache_age=$(( $(date +%s) - mtime ))
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
fi

masked_email=$(python3 - "$account_email" <<'PYEOF'
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
)
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
  resume_cmd="claude --resume ${session_id}"
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
layer_rows=$(python3 - "$STATUSLINE_WIDTH" "$P" "$line3" "$line4" <<'PYEOF'
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
)

# Print only non-empty rows, so lines 3 and 4 collapse away instead of gaps
out="${line1}\n${line2}"
while IFS= read -r row; do
  [ -n "$row" ] && out="${out}\n${row}"
done <<< "$layer_rows"
printf "%b" "$out"
