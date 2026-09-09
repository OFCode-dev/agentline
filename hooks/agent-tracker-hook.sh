#!/bin/bash
# agentline optional hook: tracks active subagent spawns.
# Feeds the 🤖 active-agents segment on agentline's line 3.
# Called by PreToolUse (to add) and Stop (to clear). Wire it up with
# `bash install.sh --with-hooks` (see README).
#
# Registration goes through agentline-agent.sh — the same locked helper any
# external process uses — so a parallel dispatch cannot lose entries. On Stop
# this hook removes only the labels it registered itself, tracked in a
# per-session sidecar: an external agent that registered its own run keeps its
# row and stays visible past the end of the assistant's turn.

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
# shellcheck source=./agentline-agent.sh
. "$HOOK_DIR/agentline-agent.sh" 2>/dev/null || exit 0

input=$(cat)
parsed=$(printf '%s' "$input" | python3 -c "
import sys, json, re
try:
    d = json.load(sys.stdin)
    tool = d.get('tool_name', '')
    sid = re.sub(r'[^A-Za-z0-9_-]', '', str(d.get('session_id') or ''))[:64] or 'default'
    # PreToolUse: extract agent description/type. The subagent tool is named
    # 'Agent' in current Claude Code releases and 'Task' in earlier ones.
    if tool in ('Agent', 'Task'):
        inp = d.get('tool_input', {})
        desc = inp.get('description', '')
        atype = inp.get('subagent_type', '')
        label = (desc[:28] if desc else atype).replace('\n', ' ').replace('\t', ' ').strip()
        print('ADD\t' + sid + '\t' + label if label else 'SKIP')
    elif not tool:
        # Stop hook - clear this session's own agents
        print('CLEAR\t' + sid)
    else:
        print('SKIP')
except Exception:
    print('SKIP')
" 2>/dev/null)

event=${parsed%%$'\t'*}
rest=${parsed#*$'\t'}

case "$event" in
  ADD)
    session=${rest%%$'\t'*}
    label=${rest#*$'\t'}
    owned="${AGENTLINE_AGENT_FILE}.owned.${session}"
    agentline_agent add "$label"
    # Remember what this session owns so Stop can clear only its own rows.
    grep -qxF "$label" "$owned" 2>/dev/null || printf '%s\n' "$label" >>"$owned"
    ;;
  CLEAR)
    session=$rest
    owned="${AGENTLINE_AGENT_FILE}.owned.${session}"
    if [ -f "$owned" ]; then
      while IFS= read -r label; do
        [ -n "$label" ] && agentline_agent remove "$label"
      done <"$owned"
      rm -f "$owned"
    fi
    ;;
esac
