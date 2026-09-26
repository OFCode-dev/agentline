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
# Writes are serialised by a mkdir lock (<file>.d, the same mechanism on every
# platform), so dispatching several agents at once cannot drop an entry. Stale
# rows are pruned on every write, which keeps the file bounded even if a
# process dies before deregistering.
#
# Environment:
#   CLAUDE_AGENTS_FILE      data file (default $AGENTLINE_TMP/claude_agents.txt)
#   AGENTLINE_TMP           side-file directory shared with agentline.sh
#                           (default /tmp)
#   AGENTLINE_AGENT_WINDOW  freshness window, seconds (default 300, matches
#                           the window agentline.sh displays)
#   AGENTLINE_AGENT_CAP     maximum entries kept (default 16)

AGENTLINE_AGENT_FILE="${CLAUDE_AGENTS_FILE:-${AGENTLINE_TMP:-/tmp}/claude_agents.txt}"
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
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 1

  (
    # Serialise writers with an atomic `mkdir` lock — on every platform. The
    # lock used to be flock(1) where it was on PATH and mkdir elsewhere, but
    # that choice was made per process: a Linux hook with flock and a writer
    # whose PATH lacked it (a stripped hook env, a container sharing the temp
    # dir) took different locks and did not exclude each other at all. One
    # mechanism per registry file is the only safe answer, and mkdir is the
    # one every platform has. Writes are rare (subagent start/stop, heartbeats
    # every 30 s), so the few forks cost nothing that matters.
    #
    # A lock directory older than 10 s belongs to a writer that died holding
    # it (a write takes well under a second). It is broken by renaming it to
    # a name unique to this waiter, which only one waiter can do: the loser's
    # rename finds nothing. The renamed directory is re-checked, because
    # between our stat and our rename another waiter may have broken the
    # stale lock and taken a fresh one — if what we moved is fresh, it is put
    # back rather than stolen. A lock not won within 5 s, for any reason —
    # held, unbreakable (another user's directory in a sticky /tmp, a
    # non-empty directory, a file in the way) — means the write is skipped
    # rather than raced: a heartbeat `add` re-registers on its next beat,
    # whereas a racing rewrite can silently drop another row. The deadline is
    # checked first on every pass, so no path can spin past it.
    local lockdir="${file}.d" deadline held now_s stale
    deadline=$(( $(date +%s) + 5 ))
    until mkdir "$lockdir" 2>/dev/null; do
      now_s=$(date +%s)
      if [ "$now_s" -ge "$deadline" ]; then
        echo "agentline-agent: registry busy, skipped $op '$label'" >&2
        exit 0
      fi
      held=$(stat -c %Y "$lockdir" 2>/dev/null || stat -f %m "$lockdir" 2>/dev/null)
      # The holder may release between mkdir and stat. GNU stat then fails
      # the -c form and reads `-f %m` as "filesystem status of a file named
      # %m", printing a report instead of a number; drop anything
      # non-numeric and simply retry the mkdir.
      case "$held" in *[!0-9]*) held="" ;; esac
      if [ -n "$held" ] && [ $(( now_s - held )) -gt 10 ]; then
        stale="${lockdir}.stale.$$.$RANDOM"
        if mv "$lockdir" "$stale" 2>/dev/null; then
          held=$(stat -c %Y "$stale" 2>/dev/null || stat -f %m "$stale" 2>/dev/null)
          case "$held" in *[!0-9]*) held="" ;; esac
          if [ -n "$held" ] && [ $(( now_s - held )) -le 10 ]; then
            # Moved a live lock: hand it back, unless someone has already
            # taken the name (then its owner's rmdir on exit cleans up).
            [ -e "$lockdir" ] || mv "$stale" "$lockdir" 2>/dev/null
          else
            # A directory that will not rmdir (it has contents) is left
            # aside under its stale name rather than deleted blind.
            rmdir "$stale" 2>/dev/null || rm -f "$stale" 2>/dev/null
            continue
          fi
        fi
      fi
      sleep 0.1 2>/dev/null || sleep 1
    done
    trap 'rmdir "$lockdir" 2>/dev/null' EXIT

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
