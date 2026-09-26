#!/bin/bash
# agentline optional hook: tracks the subagents Claude Code runs.
# Feeds the 🤖 active-agents segment on agentline's line 3. Wire it up with
# `bash install.sh --with-hooks` (see README).
#
# One script serves four events and dispatches on the payload's
# hook_event_name. It used to tell them apart by whether tool_name was
# present, treating anything without one as the main Stop: registered for
# SubagentStop, the first subagent to finish would have cleared every sibling.
#
#   PreToolUse (Agent|Task)  a dispatch: the row appears at once under the
#                            tool call's description (or subagent_type), and
#                            that label is queued for the SubagentStart that
#                            follows. SubagentStart has no description of its
#                            own, and a type alone reads "general-purpose" for
#                            most dispatches.
#   SubagentStart            the agent is running: its row is re-labelled
#                            "<label> #<first 6 of agent_id>", taking the oldest
#                            queued label (agent_type when none is queued). An
#                            empty agent_type is an internal agent (prompt
#                            suggestions, /btw) and is ignored.
#   SubagentStop             the agent finished: its row goes, and a "✓<label>"
#                            row takes its place, which agentline shows for a
#                            few seconds. An agent_id this hook never started
#                            (an internal agent, a stop repeated because a stop
#                            hook blocked) is ignored, so a repeat is harmless.
#   Stop                     end of the turn: every row this session still
#                            owns is cleared — the safety net for an agent
#                            whose SubagentStop never came, and the only
#                            clearing a Claude Code without SubagentStart has.
#
# The queued labels are matched to starts oldest first. A parallel dispatch
# starts its agents in the order it made them, as far as the payloads show;
# if two starts ever cross, two labels trade places, and nothing is lost.
#
# Registration goes through agentline-agent.sh — the same locked helper any
# external process uses — so a parallel dispatch cannot lose entries. What a
# session owns (its rows, its queue, its agent ids) is kept in per-session
# sidecars next to the registry, so an external agent that registered its own
# run keeps its row and stays visible past the end of the assistant's turn.

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
# shellcheck source=./agentline-agent.sh
. "$HOOK_DIR/agentline-agent.sh" 2>/dev/null || exit 0

input=$(cat)

# The parse also keeps the session's queue and id map, under a flock of their
# own: a parallel dispatch fires its hooks concurrently, and two starts must
# not pop the same queued label. It prints one instruction for the shell
# below, its fields separated by \x1f (a tab is IFS whitespace, and `read`
# would merge the empty field a start with nothing queued has). (Program read
# first, run with -c: see the note at the payload parser in agentline.sh.)
IFS= read -r -d '' _AL_HOOK_PY <<'PYEOF'
import fcntl, json, os, re, sys

base = sys.argv[1]
US = '\x1f'

def one_line(s, n):
    return re.sub(r'[\x00-\x1f\x7f]+', ' ', str(s)).strip()[:n]

def locked(path, edit):
    # edit(lines) -> (new lines, result), under flock on <path>.lock.
    try:
        fd = os.open(path + '.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
    except OSError:
        return None
    try:
        try:
            with open(path, encoding='utf-8', errors='surrogateescape') as f:
                lines = [l for l in f.read().split('\n') if l]
        except OSError:
            lines = []
        new, result = edit(lines)
        if new != lines:
            if new:
                tmp = '%s.%d' % (path, os.getpid())
                with open(tmp, 'w', encoding='utf-8', errors='surrogateescape') as f:
                    f.write(''.join(l + '\n' for l in new))
                os.replace(tmp, path)
            else:
                try:
                    os.unlink(path)
                except OSError:
                    pass
        return result
    except OSError:
        return None
    finally:
        os.close(fd)

try:
    d = json.load(sys.stdin)
    if not isinstance(d, dict):
        raise ValueError
    sid = re.sub(r'[^A-Za-z0-9_-]', '', str(d.get('session_id') or ''))[:64] or 'default'
    event = d.get('hook_event_name') or ''
    tool = d.get('tool_name') or ''
    # A payload with no event name comes from a Claude Code older than the
    # field: keep the old reading of it, a tool call or else the Stop.
    if not event:
        event = 'PreToolUse' if tool else 'Stop'
    pending = '%s.pending.%s' % (base, sid)
    ids = '%s.ids.%s' % (base, sid)
    aid = re.sub(r'[^A-Za-z0-9_-]', '', str(d.get('agent_id') or ''))[:64]
    out = ['SKIP']

    if event == 'PreToolUse':
        # The subagent tool is 'Agent' in current Claude Code releases and
        # 'Task' in earlier ones.
        inp = d.get('tool_input') if isinstance(d.get('tool_input'), dict) else {}
        label = one_line(inp.get('description') or inp.get('subagent_type') or '', 28)
        if tool in ('Agent', 'Task') and label:
            locked(pending, lambda ls: (ls + [label], None))
            out = ['ADD', sid, label]
    elif event == 'SubagentStart':
        atype = one_line(d.get('agent_type') or '', 28)
        if atype and aid:
            queued = locked(pending, lambda ls: (ls[1:], ls[0] if ls else '')) or ''
            label = queued or atype
            row = '%s #%s' % (label, aid[:6])
            locked(ids, lambda ls: ([l for l in ls if not l.startswith(aid + US)]
                                    + [US.join((aid, row, label))], None))
            out = ['START', sid, queued, row]
    elif event == 'SubagentStop':
        def take(ls):
            hit = [l for l in ls if l.startswith(aid + US)]
            return [l for l in ls if not l.startswith(aid + US)], hit[-1] if hit else ''
        entry = locked(ids, take) if aid else ''
        if entry:
            _, row, label = (entry.split(US) + ['', ''])[:3]
            out = ['DONE', sid, row, label]
    elif event == 'Stop':
        for p in (pending, ids):
            for q in (p, p + '.lock'):
                try:
                    os.unlink(q)
                except OSError:
                    pass
        out = ['CLEAR', sid]
    print(US.join(out))
except Exception:
    print('SKIP')
PYEOF
# -I (isolated): the hook runs in the project directory, and plain `python3 -c`
# would import a json.py or re.py sitting there instead of the standard one.
parsed=$(printf '%s' "$input" | python3 -I -c "$_AL_HOOK_PY" "$AGENTLINE_AGENT_FILE" 2>/dev/null)

IFS=$'\x1f' read -r event session a b <<< "$parsed"
owned="${AGENTLINE_AGENT_FILE}.owned.${session}"

# Remember what this session owns so Stop can clear only its own rows.
# LC_ALL=C: an exact byte comparison, whatever the label's bytes are.
_own() { LC_ALL=C grep -qxF "$1" "$owned" 2>/dev/null || printf '%s\n' "$1" >>"$owned"; }

case "$event" in
  ADD)
    agentline_agent add "$a"
    _own "$a"
    ;;
  START)
    # $a: the dispatch row to re-label (empty when none was queued), $b: the
    # row with the agent id. Added first, so the agent never vanishes from a
    # render in between.
    agentline_agent add "$b"
    _own "$b"
    [ -n "$a" ] && agentline_agent remove "$a"
    ;;
  DONE)
    # $a: the running row, $b: its label. The ✓ row is not owned: a Stop
    # right after the last agent finished would wipe the flash at once. It
    # ages out on its own (see agentline-agent.sh).
    agentline_agent add "✓$b"
    agentline_agent remove "$a"
    ;;
  CLEAR)
    if [ -f "$owned" ]; then
      while IFS= read -r label; do
        [ -n "$label" ] && agentline_agent remove "$label"
      done <"$owned"
      rm -f "$owned"
    fi
    ;;
esac
exit 0
