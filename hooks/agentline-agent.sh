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
#   AGENTLINE_AGENT_CAP     maximum entries kept (default 16)

AGENTLINE_AGENT_FILE="${CLAUDE_AGENTS_FILE:-${AGENTLINE_TMP:-/tmp}/claude_agents.txt}"
AGENTLINE_AGENT_WINDOW="${AGENTLINE_AGENT_WINDOW:-300}"
AGENTLINE_AGENT_CAP="${AGENTLINE_AGENT_CAP:-16}"

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
  case "$op" in add|remove) ;; *) return 1 ;; esac

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
    echo "agentline-agent: python3 not found, skipped $op '$label'" >&2
    return 0
  fi
  python3 - "$op" "$label" "$file" "$AGENTLINE_AGENT_WINDOW" "$AGENTLINE_AGENT_CAP" <<'PYEOF'
import errno, fcntl, glob, os, re, shutil, stat, sys, tempfile, time

op, label, path, win, cap = sys.argv[1:6]
win = int(win) if win.isdigit() else 300
cap = int(cap) if cap.isdigit() else 16
# One row per line, so a label can never smuggle in a second one.
label = re.sub(r'[\r\n]+', ' ', label)

def skip(why):
    sys.stderr.write(f"agentline-agent: {why}, skipped {op} '{label}'\n")
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
    if ts <= 0 or now - ts >= win or rest == '' or rest == label:
        continue
    rows.append(line)
if op == 'add':
    rows.append(f"{now} {label}")
# Age pruning already ran, so the cap can only ever drop the oldest of the
# still-live entries — never a running agent while a stale row survives.
rows = rows[-cap:] if cap > 0 else []

# Temp file beside the registry, then an atomic rename: the reader, which
# takes no lock, sees the old file or the new one, never a half-written one.
tmp = None
try:
    tfd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or '.',
                                prefix=os.path.basename(path) + '.')
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
cutoff = time.time() - 60
for p in [path + '.d'] + glob.glob(glob.escape(path) + '.d.stale.*'):
    try:
        st = os.lstat(p)
        if st.st_uid != os.getuid() or st.st_mtime > cutoff:
            continue
        if stat.S_ISDIR(st.st_mode):
            shutil.rmtree(p, ignore_errors=True)
        else:
            os.unlink(p)
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
