#!/bin/bash
# agentline: shared registry for the 🤖 live-agent segment on line 3.
#
# Any long-running process can announce itself here and disappear when it is
# done: a Claude subagent (via agent-tracker-hook.sh), an external agent CLI
# such as `agy` or `codex` driven from a shell, or a plain background job.
# agentline.sh renders every entry younger than the freshness window and does
# not care who wrote it.
#
# Usage:
#   agentline-agent.sh add    <label>   # register, or refresh an existing one
#   agentline-agent.sh remove <label>   # deregister
#
# `add` is idempotent — it replaces any line carrying the same label rather
# than appending a second one — so it doubles as a heartbeat:
#
#   label="codex round 1"
#   agentline-agent.sh add "$label"
#   while :; do sleep 30; agentline-agent.sh add "$label"; done &
#   hb=$!
#   trap 'kill "$hb" 2>/dev/null; agentline-agent.sh remove "$label"' EXIT
#   codex exec ...
#
# Writes are serialised with flock, so dispatching several agents at once
# cannot drop an entry. Stale rows are pruned on every write, which keeps the
# file bounded even if a process dies before deregistering.
#
# Environment:
#   CLAUDE_AGENTS_FILE      data file (default /tmp/claude_agents.txt)
#   AGENTLINE_AGENT_WINDOW  freshness window, seconds (default 300, matches
#                           the window agentline.sh displays)
#   AGENTLINE_AGENT_CAP     maximum entries kept (default 16)

AGENTLINE_AGENT_FILE="${CLAUDE_AGENTS_FILE:-/tmp/claude_agents.txt}"
AGENTLINE_AGENT_WINDOW="${AGENTLINE_AGENT_WINDOW:-300}"
AGENTLINE_AGENT_CAP="${AGENTLINE_AGENT_CAP:-16}"

# agentline_agent <add|remove> <label>
#
# Rewrites the file under an exclusive lock: drop malformed rows, drop rows
# older than the window, drop any row with this label, then append a fresh
# one for `add`. Never fails loudly — a status bar must not break a hook or a
# caller's pipeline, so every step degrades to leaving the file untouched.
agentline_agent() {
  local op="$1" label="$2"
  [ -n "$op" ] && [ -n "$label" ] || return 1
  case "$op" in add|remove) ;; *) return 1 ;; esac

  local file="$AGENTLINE_AGENT_FILE"
  local lock="${file}.lock"
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 1

  (
    exec 9>>"$lock" 2>/dev/null || exit 0
    flock -w 5 9 2>/dev/null

    local now tmp
    now=$(date +%s)
    tmp=$(mktemp "${file}.XXXXXX" 2>/dev/null) || exit 0

    if [ -f "$file" ]; then
      awk -v now="$now" -v win="$AGENTLINE_AGENT_WINDOW" -v lab="$label" '
        {
          ts = $1 + 0
          if (ts <= 0) next
          if (now - ts >= win) next
          rest = $0
          sub(/^[0-9]+[ \t]+/, "", rest)
          if (rest == "" || rest == lab) next
          print
        }' "$file" >"$tmp" 2>/dev/null
    fi

    [ "$op" = "add" ] && printf '%s %s\n' "$now" "$label" >>"$tmp"

    # Age pruning already ran, so the cap can only ever drop the oldest of the
    # still-live entries — it can no longer evict a running agent while a
    # stale row survives, which the previous `tail -8` on append could do.
    if [ "$(wc -l <"$tmp" 2>/dev/null || echo 0)" -gt "$AGENTLINE_AGENT_CAP" ]; then
      tail -n "$AGENTLINE_AGENT_CAP" "$tmp" >"${tmp}.cap" 2>/dev/null &&
        mv -f "${tmp}.cap" "$tmp"
    fi

    chmod 644 "$tmp" 2>/dev/null
    mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp" "${tmp}.cap"
  )
}

# Run as a command when executed directly; stay quiet when sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  op="${1:-}"
  [ $# -gt 0 ] && shift
  label="$*"
  case "$op" in
    add|remove)
      if [ -z "$label" ]; then
        echo "usage: ${0##*/} $op <label>" >&2
        exit 2
      fi
      agentline_agent "$op" "$label"
      ;;
    *)
      echo "usage: ${0##*/} add|remove <label>" >&2
      exit 2
      ;;
  esac
fi
