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
# Sourced, it also offers agentline_agent_edit (below): several adds and
# removes in one locked write, optionally with a shorter life than the window.
#
# agentline.sh shows up to AGENTLINE_AGENT_SHOW (default 4) of them, oldest
# first, and counts the rest as "+N".
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
# Writes are serialised by a kernel lock on <file>.lock (flock(2), taken from
# python3, the same mechanism on every platform), so dispatching several agents
# at once cannot drop an entry, and a writer that dies holding the lock cannot
# wedge the registry: the kernel releases it with the process. Stale rows are
# pruned on every write, which keeps the file bounded even if a process dies
# before deregistering.
#
# Environment:
#   CLAUDE_AGENTS_FILE      data file (default $AGENTLINE_TMP/claude_agents.txt)
#   AGENTLINE_TMP           side-file directory shared with agentline.sh
#                           (default /tmp)
#   AGENTLINE_AGENT_WINDOW  freshness window, seconds (default 300, matches
#                           the window agentline.sh displays)
#   AGENTLINE_AGENT_CAP     maximum entries kept (default 32). Only a safety
#                           bound on the file: agentline.sh shows the first
#                           AGENTLINE_AGENT_SHOW and folds the rest into "+N",
#                           so a large dispatch is counted, not hidden.
#
# A label starting with "✓" is a finished agent (agent-tracker-hook.sh writes
# one on SubagentStop). agentline.sh shows it for a few seconds; here it is
# pruned after a minute, and it is the first to go when the cap is reached,
# so a burst of finished agents can never push a running one out.

AGENTLINE_AGENT_FILE="${CLAUDE_AGENTS_FILE:-${AGENTLINE_TMP:-/tmp}/claude_agents.txt}"
AGENTLINE_AGENT_WINDOW="${AGENTLINE_AGENT_WINDOW:-300}"
AGENTLINE_AGENT_CAP="${AGENTLINE_AGENT_CAP:-32}"

# agentline_agent <add|remove> <label>
#
# Rewrites the file under an exclusive lock: drop malformed rows, drop rows
# older than the window, drop any row with this label, then append a fresh
# one for `add`. Never fails loudly — a status bar must not break a hook or a
# caller's pipeline, so every step degrades to leaving the file untouched,
# with a one-line note on stderr.
agentline_agent() {
  local op="$1" label="$2"
  [ -n "$op" ] && [ -n "$label" ] || return 1
  case "$op" in
    add)    agentline_agent_edit 0 "+$label" ;;
    remove) agentline_agent_edit 0 "-$label" ;;
    *)      return 1 ;;
  esac
}

# agentline_agent_edit <ttl> <+label|-label>...
#
# Several adds (+) and removes (-), applied in order in ONE locked rewrite —
# what the tracker hook uses, so a subagent start (add its row, drop the
# dispatch row) or a Stop clearing a dozen rows costs one python3 run, not
# one per row: at 24 agents the per-row Stop took 1.4 s at every turn end.
#
# ttl > 0 gives the rows added here a shorter life than the window: they are
# stamped ttl seconds short of it, back-dated, so every reader — agentline.sh
# knows only its fixed 300 s window, and an external reader only the format —
# drops them at the same moment with no change to the file format. The
# tracker uses it for a dispatch that has not started yet.
agentline_agent_edit() {
  local ttl="$1"
  shift 2>/dev/null || return 1
  [ $# -gt 0 ] || return 1

  local file="$AGENTLINE_AGENT_FILE"
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 1

  # The whole read-modify-write is one python3 run holding flock(2) on
  # <file>.lock. It replaced a mkdir lock whose stale-lock breaking could not
  # be made safe from the shell: two waiters could each decide the same
  # directory was stale, and a 12-writer stress run lost rows, leaked
  # `.d.stale.*` directories and once moved a stale directory into a freshly
  # taken lock, which then could not be released and wedged every later
  # writer. A kernel lock has no stale state at all — it dies with its holder
  # — and python3 is already what the tracker hook parses its payload with.
  # flock(1) takes the same flock(2) lock, so the flock-based writers of
  # earlier releases (they used this very file) exclude and are excluded.
  if ! command -v python3 >/dev/null 2>&1; then
    local what="" o
    for o in "$@"; do
      case "$o" in +*) what="${what:+$what, }add '${o#+}'" ;; *) what="${what:+$what, }remove '${o#-}'" ;; esac
    done
    echo "agentline-agent: python3 not found, skipped $what" >&2
    return 0
  fi
  # -I (isolated): this runs in whatever directory the caller is in (a hook:
  # the project), and plain `python3 -` would import an os.py or json.py
  # sitting there instead of the standard one.
  python3 -I - "$file" "$AGENTLINE_AGENT_WINDOW" "$AGENTLINE_AGENT_CAP" "$ttl" "$@" <<'PYEOF'
# Only what every write needs is imported up front: this runs on every
# subagent start and stop and every heartbeat, and glob, shutil and tempfile
# together were most of its start-up (a write took 44 ms against 25 ms for
# the mkdir lock). The sweep imports its own modules when it has work.
import errno, fcntl, os, re, sys, time

path, win, cap, ttl = sys.argv[1:5]
win = int(win) if win.isdigit() else 300
cap = int(cap) if cap.isdigit() else 32
ttl = int(ttl) if ttl.isdigit() else 0
DONE, DONE_WIN = '✓', 60  # a finished agent's row, and how long it is kept
READER_WIN = 300          # the window agentline.sh shows rows for
# One row per line, so a label can never smuggle in a second one. An op is
# its sign and a label; one without a label means nothing.
ops = [(o[0], re.sub(r'[\r\n]+', ' ', o[1:])) for o in sys.argv[5:]
       if len(o) > 1 and o[0] in '+-']

def skip(why):
    what = ', '.join("%s '%s'" % ('add' if s == '+' else 'remove', l) for s, l in ops)
    sys.stderr.write(f"agentline-agent: {why}, skipped {what}\n")
    sys.exit(0)

if not ops:
    sys.exit(0)

# An open() that fails — an unwritable AGENTLINE_TMP, a read-only or full
# file system, another user's lock file in a sticky /tmp — will fail the same
# way for the whole deadline, so it is reported at once instead of waited on.
# O_NOFOLLOW: a symlink planted at the lock's name in a shared /tmp is refused
# rather than followed.
try:
    fd = os.open(path + '.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o644)
except OSError as e:
    skip(f"cannot open the lock ({e.strerror})")

# A live lock is waited on for up to 5 s, then the write is skipped rather
# than raced: a heartbeat `add` re-registers on its next beat, whereas a
# racing rewrite can silently drop another writer's row. The wait polls with
# LOCK_NB because a blocking flock() has no timeout.
deadline = time.monotonic() + 5
while True:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        break
    except OSError as e:
        if e.errno not in (errno.EAGAIN, errno.EACCES, errno.EWOULDBLOCK):
            skip(f"cannot lock ({e.strerror})")
    if time.monotonic() >= deadline:
        skip("registry busy")
    time.sleep(0.05)

now = int(time.time())
rows = []
try:
    with open(path, 'rb') as f:
        data = f.read().decode('utf-8', 'surrogateescape')
except OSError:
    data = ''
for line in data.split('\n'):
    m = re.match(r'([0-9]+)[ \t]+(.*)$', line)
    if not m:
        continue  # malformed, or the empty tail after the last newline
    ts, rest = int(m.group(1)), m.group(2)
    if ts <= 0 or now - ts >= win or rest == '':
        continue
    if rest.startswith(DONE) and now - ts >= DONE_WIN:
        continue
    rows.append((rest, line))
# The back-date is taken against the shorter of the two windows, so a row
# with a ttl leaves the reader's view and this file's pruning alike after ttl
# seconds, whatever AGENTLINE_AGENT_WINDOW says.
stamp = now - (min(win, READER_WIN) - ttl if 0 < ttl < min(win, READER_WIN) else 0)
for sign, label in ops:
    rows = [r for r in rows if r[0] != label]
    if sign == '+':
        rows.append((label, f"{stamp} {label}"))
rows = [line for _, line in rows]
# Age pruning already ran, so the cap can only ever drop the oldest of the
# still-live entries — never a running agent while a stale row survives —
# and finished rows go before any running one.
def done(r):
    return r.partition(' ')[2].startswith(DONE)
while len(rows) > max(cap, 0):
    old = next((i for i, r in enumerate(rows) if done(r)), 0)
    del rows[old]

# Temp file beside the registry, then an atomic rename: the reader, which
# takes no lock, sees the old file or the new one, never a half-written one.
# The name is unique to this process (pid + random) and opened O_EXCL |
# O_NOFOLLOW, which is all tempfile.mkstemp added, without its import.
tmp = None
try:
    name = f"{path}.{os.getpid()}.{os.urandom(4).hex()}"
    tfd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    tmp = name
    with os.fdopen(tfd, 'wb') as f:
        f.write(''.join(r + '\n' for r in rows).encode('utf-8', 'surrogateescape'))
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)
    tmp = None
except OSError as e:
    skip(f"cannot write the registry ({e.strerror})")
finally:
    if tmp:
        try:
            os.unlink(tmp)
        except OSError:
            pass

# Sweep what the mkdir lock of earlier releases could leave behind: its lock
# directory <file>.d (or a file squatting that name) and the `.d.stale.*`
# directories it set aside. Only our own, and only past a minute — no writer
# of this release uses those names, but an older copy of this helper still
# running elsewhere might hold a fresh one. <file>.lock itself is never
# removed: unlinking a flock file while someone holds it lets the next writer
# lock a new inode and walk straight past them.
#
# Listing the directory (a shared /tmp can be large) is not paid on every
# write: the sweep runs while <file>.d exists, or until it has once found
# nothing left to wait for, which it records by writing one byte into the
# lock file (its content means nothing to flock).
if os.path.lexists(path + '.d') or os.fstat(fd).st_size == 0:
    import glob, shutil, stat
    cutoff, pending = time.time() - 60, False
    for p in [path + '.d'] + glob.glob(glob.escape(path) + '.d.stale.*'):
        try:
            st = os.lstat(p)
            if st.st_uid != os.getuid():
                continue
            if st.st_mtime > cutoff:
                pending = True  # possibly live: look again on a later write
                continue
            if stat.S_ISDIR(st.st_mode):
                shutil.rmtree(p, ignore_errors=True)
            else:
                os.unlink(p)
        except OSError:
            pass
    if not pending:
        try:
            os.pwrite(fd, b'2', 0)
        except OSError:
            pass
PYEOF
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
