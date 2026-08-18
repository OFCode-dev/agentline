#!/bin/bash
# agentline optional hook: tracks active subagent spawns.
# Feeds the 🤖 active-agents segment on agentline's line 3.
# Called by PreToolUse (to add) and Stop (to clear). Wire it up with
# `bash install.sh --with-hooks` (see README).

AGENTFILE="/tmp/claude_agents.txt"

input=$(cat)
event=$(echo "$input" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    tool = d.get('tool_name', '')
    # PreToolUse: extract agent description/type. The subagent tool is named
    # 'Agent' in current Claude Code releases and 'Task' in earlier ones.
    if tool in ('Agent', 'Task'):
        inp = d.get('tool_input', {})
        desc = inp.get('description', '')
        atype = inp.get('subagent_type', '')
        label = desc[:28] if desc else atype
        print('ADD ' + label)
    elif not tool:
        # Stop hook - clear agents
        print('CLEAR')
    else:
        print('SKIP')
except:
    print('SKIP')
" 2>/dev/null)

case "$event" in
  ADD*)
    label="${event#ADD }"
    timestamp=$(date +%s)
    echo "${timestamp} ${label}" >> "$AGENTFILE"
    # Keep only last 8 entries (prevent unbounded growth)
    tail -8 "$AGENTFILE" > "${AGENTFILE}.tmp" && mv "${AGENTFILE}.tmp" "$AGENTFILE"
    ;;
  CLEAR)
    rm -f "$AGENTFILE"
    ;;
esac
