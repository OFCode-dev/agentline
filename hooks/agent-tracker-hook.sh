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
#                            is queued, with its subagent_type and the time,
#                            for the SubagentStart that follows. SubagentStart
#                            has no description of its own, and a type alone
#                            reads "general-purpose" for most dispatches.
#   SubagentStart            the agent is running: its row is re-labelled
#                            "<label> #<first 6 of agent_id>", taking the
#                            oldest queued entry of the same agent_type. A
#                            start that matches no queued dispatch is not one
#                            this session asked for — an internal agent
#                            (prompt suggestions, /btw: an empty agent_type;
#                            under `claude --agent` a named one) — and is
#                            ignored; so is an empty agent_type.
#   SubagentStop             the agent finished: its row goes, and a "✓<label>"
#                            row takes its place, which agentline shows for a
#                            few seconds. An agent_id this hook never started
#                            (an internal agent, a stop repeated because a stop
#                            hook blocked) is ignored, so a repeat is harmless.
#   Stop                     end of the turn: the dispatches still queued are
#                            cleared. Started agents keep their rows: one run
#                            with run_in_background is still working after the
#                            turn ends, and its SubagentStop (and ✓) comes
#                            later. An agent whose SubagentStop never comes
#                            ages out of the registry's 300 s window.
#
# A dispatch that never starts — permission denied, blocked by another hook,
# invalid input, the user interrupting — used to leave its label queued, so
# every later agent of the turn took its predecessor's label and a ghost row
# stayed; an interrupt fires no Stop, so the queue even carried into the next
# turn. Matching by type bounds the damage to agents of the same type, and a
# queued entry, and its row, live QUEUE_TTL (120 s) at most — the row is
# written with that short life (see agentline_agent_edit), so it goes on time
# even if no hook ever runs again. Agents of one type started in parallel
# still take their labels in the order their hooks win the lock: the
# payloads carry nothing that ties a start to its tool call.
#
# All of a session's state (the queue and the agent_id map) is one JSON file
# beside the registry, edited under one flock with a 5 s deadline. The rows
# themselves go through agentline_agent_edit — the same locked helper any
# external process uses, one call per event however many rows change — so a
# parallel dispatch cannot lose entries, and an external agent that
# registered its own run keeps its row past the end of the assistant's turn.

# Its session state sits beside the registry, private like it (0600).
umask 077
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
# shellcheck source=./agentline-agent.sh
. "$HOOK_DIR/agentline-agent.sh" 2>/dev/null || exit 0

input=$(cat)

# The parse prints the registry edit for the shell below: a ttl, then one
# "+label" or "-label" per row, separated by \x1e (no description can hold
# one: control characters are blanked), or SKIP. Every row this hook writes
# ends in \x1fc, the mark of a Claude subagent: agentline.sh shows it in
# Claude's colour, and leaves it off the main line under
# AGENTLINE_AGENTS=external, where Claude Code's subagent panel lists it.
# The mark is part of the key, hidden like agentline-run's pid. The state
# file keeps a started agent's row as written, so the stop of an agent
# started under a release without the mark still removes its unmarked row. (Program read first, run with -c:
# see the note at the payload parser in agentline.sh.)
IFS= read -r -d '' _AL_HOOK_PY <<'PYEOF'
import errno, fcntl, json, os, re, sys, time

base = sys.argv[1]
SEP = '\x1e'      # between the ops printed for the shell
MARK = '\x1fc'    # the key suffix of a Claude subagent's row
QUEUE_TTL = 120   # a dispatch whose SubagentStart never came
IDS_TTL = 3600    # a started agent whose SubagentStop never came
CAP = 64          # entries of each kind kept, a bound on the file
now = int(time.time())

def one_line(s, n):
    s = re.sub(r'[\x00-\x1f\x7f]+', ' ', str(s)).strip()
    # A leading check mark is what the reader takes for a finished row
    # (agentline-agent.sh writes "✓<label>" on SubagentStop), so a
    # description starting with one would show as done while running.
    return re.sub(r'^[\s✓]+', '', s)[:n]

# The secret heuristic of agentline-subagents.sh, the same definition (the
# test suite compares the copies; see the reasoning there). A description
# is Claude Code's own UI text, and it is shown — but on line 3 as well as
# in Claude Code's panel, so one that looks like it holds a secret is shown
# as "agent", and a subagent type as "*" (it is matched, never shown). The
# registry helper checks again: it is the boundary for every writer. The
# whole description is checked, before it is cut to the row's 28 cells.
SECRET_KEY = re.compile(r'(?:^|[^A-Za-z0-9])(?:sk-|sk_|rk_|gh[pousr]_|github_pat_|glpat-|xox[a-z]-|hf_'
                        r'|nvapi-|aiza|ya29\.|npm_|pypi-)|(?:akia|asia)[a-z0-9]{12}|eyj[a-z0-9_-]{8}'
                        r'|bearer|basic |token|secret|passw|apikey|api_key|[=:]\S{8}|[A-Za-z0-9_-]{24}', re.I)
SECRET_PART = re.compile(r'[-._/]')

def secretish(s):
    if not isinstance(s, str) or SECRET_KEY.search(s):
        return True
    for t in s.split():
        if len(t) >= 16 and re.search('[A-Za-z]', t) and re.search('[0-9]', t) and \
                any(len(p) > 5 and re.search('[A-Za-z]', p) and re.search('[0-9]', p)
                    for p in SECRET_PART.split(t)):
            return True
    return False
# (end of the secret heuristic)

def shown(s, generic, n):
    s = one_line(s, 4096)
    return (s[:n] if not secretish(s) else generic) if s else ''

def session(path, edit):
    # edit(queue, ids) -> the registry edit; the state is saved when changed.
    # The lock is a separate file, never unlinked: removing a flock file that
    # a hook still holds or waits on lets the next one lock a fresh inode and
    # walk straight past it. O_NOFOLLOW everywhere, and the new state goes to
    # an O_EXCL temp with a random name: a symlink planted in a shared /tmp
    # (the session id is visible in the file names) is refused, never
    # followed into a file of the user's.
    try:
        fd = os.open(path + '.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    except OSError:
        return None
    try:
        # A blocking flock() has no timeout; the registry helper gives up
        # after 5 s, and so does this.
        deadline = time.monotonic() + 5
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError as e:
                if e.errno not in (errno.EAGAIN, errno.EACCES, errno.EWOULDBLOCK):
                    return None
            if time.monotonic() >= deadline:
                return None
            time.sleep(0.02)
        try:
            rfd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(rfd, 'rb') as f:
                st = json.loads(f.read(1 << 20).decode('utf-8', 'replace'))
        except (OSError, ValueError):
            st = {}
        st = st if isinstance(st, dict) else {}
        def fresh(xs, width, ttl):
            return [x for x in (xs if isinstance(xs, list) else [])
                    if isinstance(x, list) and len(x) == width
                    and all(isinstance(v, str) for v in x[:-1])
                    and type(x[-1]) is int and 0 <= now - x[-1] < ttl][-CAP:]
        queue = fresh(st.get('queue'), 3, QUEUE_TTL)  # [type, label, epoch]
        ids = fresh(st.get('ids'), 4, IDS_TTL)        # [agent_id, row, label, epoch]
        old = json.dumps(st, sort_keys=True)
        result = edit(queue, ids)
        new = {'queue': queue[-CAP:], 'ids': ids[-CAP:]}
        if json.dumps(new, sort_keys=True) != old:
            if queue or ids:
                tmp = None
                try:
                    name = '%s.%d.%s' % (path, os.getpid(), os.urandom(4).hex())
                    tfd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                    tmp = name
                    with os.fdopen(tfd, 'w') as f:
                        json.dump(new, f)
                    os.replace(tmp, path)
                    tmp = None
                finally:
                    if tmp:
                        os.unlink(tmp)
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
    state = '%s.session.%s' % (base, sid)
    aid = re.sub(r'[^A-Za-z0-9_-]', '', str(d.get('agent_id') or ''))[:64]
    edit = None

    if event == 'PreToolUse':
        # The subagent tool is 'Agent' in current Claude Code releases and
        # 'Task' in earlier ones. No subagent_type means the general-purpose
        # agent, which is the agent_type its SubagentStart then reports.
        inp = d.get('tool_input') if isinstance(d.get('tool_input'), dict) else {}
        label = shown(inp.get('description') or inp.get('subagent_type') or '', 'agent', 28)
        atype = shown(inp.get('subagent_type') or '', '*', 64) or 'general-purpose'
        if tool in ('Agent', 'Task') and label:
            def edit(queue, ids):
                queue.append([atype, label, now])
                return [str(QUEUE_TTL), '+' + label + MARK]
    elif event == 'SubagentStart':
        atype = shown(d.get('agent_type') or '', '*', 64)
        if atype and aid:
            def edit(queue, ids):
                # The oldest dispatch of this type; a case-only difference in
                # the type's spelling still pairs, a different type never.
                hit = next((q for q in queue if q[0] == atype), None) or \
                      next((q for q in queue if q[0].lower() == atype.lower()), None)
                if hit is None:
                    return None
                queue.remove(hit)
                label = hit[1]
                row = '%s #%s%s' % (label, aid[:6], MARK)
                ids[:] = [e for e in ids if e[0] != aid] + [[aid, row, label, now]]
                ops = ['0', '+' + row]
                # Two dispatches with one description share one row: it
                # stays until the last of them has started.
                if not any(q[1] == label for q in queue):
                    ops.append('-' + label + MARK)
                return ops
    elif event == 'SubagentStop':
        if aid:
            def edit(queue, ids):
                hit = [e for e in ids if e[0] == aid]
                if not hit:
                    return None
                ids[:] = [e for e in ids if e[0] != aid]
                # The ✓ row is not the session's: a Stop right after the last
                # agent finished must not wipe the flash. It ages out on its
                # own (see agentline-agent.sh).
                return ['0', '+✓' + hit[-1][2] + MARK, '-' + hit[-1][1]]
    elif event == 'Stop':
        def edit(queue, ids):
            labels = []
            for q in queue:
                if q[1] not in labels:
                    labels.append(q[1])
            del queue[:]
            return ['0'] + ['-' + l + MARK for l in labels] if labels else None
        # The per-session sidecars of earlier releases (.pending/.ids/.owned
        # and their locks): no hook of this release opens those names, so
        # they can go, and their rows age out of the registry on their own.
        for kind in ('pending', 'ids', 'owned'):
            for q in ('%s.%s.%s' % (base, kind, sid), '%s.%s.%s.lock' % (base, kind, sid)):
                try:
                    os.unlink(q)
                except OSError:
                    pass
    ops = session(state, edit) if edit else None
    print(SEP.join(ops) if ops else 'SKIP')
except Exception:
    print('SKIP')
PYEOF
# -I (isolated): the hook runs in the project directory, and plain `python3 -c`
# would import a json.py or re.py sitting there instead of the standard one.
parsed=$(printf '%s' "$input" | python3 -I -c "$_AL_HOOK_PY" "$AGENTLINE_AGENT_FILE" 2>/dev/null)

IFS=$'\x1e' read -r -a ops <<< "$parsed"
case "${ops[0]}" in ''|*[!0-9]*) exit 0 ;; esac
[ "${#ops[@]}" -gt 1 ] && agentline_agent_edit "${ops[@]}"
exit 0
