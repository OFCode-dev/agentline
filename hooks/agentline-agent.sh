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
#                           (default: the private directory below; yours,
#                           and writable by nobody else)
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

# The side-file directory, by agentline.sh's rule. The default used to be
# /tmp itself, where every user on the host could read the labels — Claude
# subagent descriptions, the names of external work. Now it is the user's
# own: $XDG_RUNTIME_DIR/agentline when that is a real directory of ours,
# else ${TMPDIR:-/tmp}/agentline-$EUID, created 0700 and used only when it
# is a directory (not a symlink) we own that nobody else can write to; an
# AGENTLINE_TMP or CLAUDE_AGENTS_FILE directory has to pass the same test
# (so a shared /tmp itself does not); anything else and nothing is written.
# Every file is written 0600 under umask 077, and read only when it is a
# regular file of ours. The registry the previous release left in /tmp is
# merged into the new one on the first write, then removed (only our own).
AGENTLINE_AGENT_DIR=""     # set: the private default, created and checked
AGENTLINE_AGENT_LEGACY=""  # set: the previous release's /tmp registry
if [ -n "${CLAUDE_AGENTS_FILE-}" ]; then
  AGENTLINE_AGENT_FILE="$CLAUDE_AGENTS_FILE"
elif [ -n "${AGENTLINE_TMP-}" ]; then
  AGENTLINE_AGENT_FILE="$AGENTLINE_TMP/claude_agents.txt"
else
  if [ -n "${XDG_RUNTIME_DIR-}" ] && [ -d "$XDG_RUNTIME_DIR" ] && [ ! -L "$XDG_RUNTIME_DIR" ] && [ -O "$XDG_RUNTIME_DIR" ]; then
    AGENTLINE_AGENT_DIR="$XDG_RUNTIME_DIR/agentline"
  else
    AGENTLINE_AGENT_DIR="${TMPDIR:-/tmp}/agentline-${EUID:-0}"
  fi
  AGENTLINE_AGENT_FILE="$AGENTLINE_AGENT_DIR/claude_agents.txt"
  AGENTLINE_AGENT_LEGACY="${_AGENTLINE_LEGACY_TMP:-/tmp}/claude_agents.txt"
fi
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

  # The directory is checked again, and for real, by the python3 below
  # (ours, not a link, writable by nobody else); here it is only created.
  # created=1 lets that check tighten a directory made just now to 0700.
  local file="$AGENTLINE_AGENT_FILE" dir created=0
  if [ -n "$AGENTLINE_AGENT_DIR" ]; then
    dir="$AGENTLINE_AGENT_DIR"
    # Not -p: the parent ($XDG_RUNTIME_DIR, the temp dir) exists, and -m
    # sets the mode at creation, with no window where it is wider.
    [ -d "$dir" ] || { mkdir -m 700 "$dir" 2>/dev/null && created=1; }
  else
    case "$file" in */*) dir="${file%/*}"; dir="${dir:-/}" ;; *) dir=. ;; esac
    [ -d "$dir" ] || { mkdir -p "$dir" 2>/dev/null && created=1; } || return 1
  fi

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
      o="${o//[[:cntrl:]]/?}"  # a label's ESC must not reach the terminal
      case "$o" in +*) what="${what:+$what, }add '${o#+}'" ;; *) what="${what:+$what, }remove '${o#-}'" ;; esac
    done
    echo "agentline-agent: python3 not found, skipped $what" >&2
    return 0
  fi
  # -I (isolated): this runs in whatever directory the caller is in (a hook:
  # the project), and plain `python3 -` would import an os.py or json.py
  # sitting there instead of the standard one.
  # umask 077 in a subshell: the caller's umask is not ours to change (the
  # tracker hook sources this file).
  ( umask 077
  python3 -I - "$dir" "${file##*/}" "$created" "$AGENTLINE_AGENT_WINDOW" "$AGENTLINE_AGENT_CAP" "$ttl" \
    "$AGENTLINE_AGENT_LEGACY" "$@" <<'PYEOF'
# Only what every write needs is imported up front: this runs on every
# subagent start and stop and every heartbeat, and glob, shutil and tempfile
# together were most of its start-up (a write took 44 ms against 25 ms for
# the mkdir lock). The sweep imports its own modules when it has work.
import errno, fcntl, os, re, stat, sys, time

dpath, name, created, win, cap, ttl, legacy = sys.argv[1:8]
win = int(win) if win.isdigit() else 300
cap = int(cap) if cap.isdigit() else 32
ttl = int(ttl) if ttl.isdigit() else 0
DONE, DONE_WIN = '✓', 60  # a finished agent's row, and how long it is kept
READER_WIN = 300          # the window agentline.sh shows rows for
# What one write reads of a registry: its first 256 KB and 512 lines. The
# file is never bigger by our own hand (AGENTLINE_AGENT_CAP rows), so more
# is someone else's doing, and must not cost unbounded time and memory.
MAX_BYTES, MAX_ROWS = 256 * 1024, 512
UID = os.getuid()
# A stored label has no control character: one row per line, so a label can
# never smuggle in a second one, and no ESC or C1 that a reader, or a
# diagnostic here, would hand to a terminal. Bidi overrides go too. \x1f
# stays: it is agentline-run's key separator (label, \x1f, pid). An op is
# its sign and a label; one without a label means nothing.
CTRL = re.compile('[\x00-\x08\x0b\x0c\x0e-\x1e\x7f-\x9f‎‏‪-‮⁦-⁩]')

def clean(s):
    return CTRL.sub('', re.sub(r'[\t\r\n]+', ' ', s)).strip()

ops = [(o[0], clean(o[1:])) for o in sys.argv[8:] if len(o) > 1 and o[0] in '+-']
ops = [(s, l) for s, l in ops if l]

def esc(s):
    # Untrusted text in a diagnostic (a label, a path from the environment)
    # reaches the terminal with its control characters escaped.
    return ''.join(c if c.isprintable() else '\\x%02x' % ord(c) if ord(c) < 256 else '\\u%04x' % ord(c)
                   for c in s)

def skip(why):
    what = ', '.join("%s '%s'" % ('add' if s == '+' else 'remove', l) for s, l in ops)
    sys.stderr.write(esc(f"agentline-agent: {why}, skipped {what}") + '\n')
    sys.exit(0)

if not ops:
    sys.exit(0)

# The directory, opened once and checked through that descriptor: ours, not
# a symlink, and writable by nobody else (mode & 022 == 0) — a user-owned
# /tmp/agentline-UID left at 0777 let anyone swap the registry or its lock
# for their own. One made just now is set to 0700; any other is refused, an
# AGENTLINE_TMP or CLAUDE_AGENTS_FILE directory too (a shared /tmp is no
# place for it). Every file below is opened relative to this descriptor, so
# a directory renamed or replaced after the check is not the one written.
try:
    dfd = os.open(dpath, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    dst = os.fstat(dfd)
except OSError as e:
    if e.errno in (errno.ELOOP, errno.ENOTDIR):
        skip(f"{dpath} is not a directory of yours")  # a symlink, or no directory
    skip(f"cannot open {dpath} ({e.strerror})")
if dst.st_uid != UID:
    skip(f"{dpath} is not a directory of yours")
if created == '1':
    try:
        os.fchmod(dfd, 0o700)  # mkdir -p made it under the caller's umask
    except OSError as e:
        skip(f"cannot make {dpath} private ({e.strerror})")
elif dst.st_mode & 0o022:
    skip(f"{dpath} is writable by others")

NB = os.O_NONBLOCK | getattr(os, 'O_NOCTTY', 0)

def open_reg(n, flags, dir_fd):
    """A descriptor for n: a regular file of ours, opened without following
    a symlink and without blocking — a FIFO planted at the name hung the
    open() for good; now it opens at once and is refused. The descriptor
    is blocking again once it is known to be a file."""
    fd = os.open(n, flags | os.O_NOFOLLOW | NB, 0o600, dir_fd=dir_fd)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != UID:
            raise OSError(errno.EPERM, 'not a regular file of yours')
        fcntl.fcntl(fd, fcntl.F_SETFL, fcntl.fcntl(fd, fcntl.F_GETFL) & ~os.O_NONBLOCK)
    except BaseException:
        os.close(fd)
        raise
    return fd

# An open() that fails — an unwritable AGENTLINE_TMP, a read-only or full
# file system, another user's lock file — will fail the same way for the
# whole deadline, so it is reported at once instead of waited on.
try:
    fd = open_reg(name + '.lock', os.O_RDWR | os.O_CREAT, dfd)
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
def read_lines(n, dir_fd):
    """The first MAX_ROWS whole lines of n, within its first MAX_BYTES; None
    when it is not there or not a regular file of ours."""
    try:
        rfd = open_reg(n, os.O_RDONLY, dir_fd)
    except OSError:
        return None
    with os.fdopen(rfd, 'rb') as f:
        data = f.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        data = data[:data.rfind(b'\n', 0, MAX_BYTES) + 1]  # no cut last line
    return data.decode('utf-8', 'surrogateescape').split('\n')[:MAX_ROWS]
lines = read_lines(name, dfd) or []
# The previous release's registry in /tmp: its live rows move here, and the
# file goes — ours only (a regular file, not a link), and only while no
# writer of that release holds its lock. The lock file itself stays: it
# holds nothing, and unlinking a flock file lets the next writer lock a new
# inode and walk past a holder of the old one.
moved = False
if legacy and legacy != os.path.join(dpath, name):
    try:
        try:
            lfd = open_reg(legacy + '.lock', os.O_RDWR, None)
        except FileNotFoundError:
            lfd = None  # no lock file: no writer of that release can hold it
        if lfd is not None:
            fcntl.flock(lfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        old = read_lines(legacy, None)
        if old is not None:
            lines = old + lines
            moved = True
    except OSError:
        pass  # busy (moved on a later write), or not ours
for line in lines:
    m = re.match(r'([0-9]+)[ \t]+(.*)$', line)
    if not m:
        continue  # malformed, or the empty tail after the last newline
    ts, rest = int(m.group(1)), m.group(2)
    if ts <= 0 or now - ts >= win or rest == '':
        continue
    if rest.startswith(DONE) and now - ts >= DONE_WIN:
        continue
    rows.append((rest, line))
if moved:
    # A label in both files: the newer file's row wins (it comes later).
    last = {r[0]: i for i, r in enumerate(rows)}
    rows = [r for i, r in enumerate(rows) if last[r[0]] == i]
# The back-date is taken against the shorter of the two windows, so a row
# with a ttl leaves the reader's view and this file's pruning alike after ttl
# seconds, whatever AGENTLINE_AGENT_WINDOW says.
stamp = now - (min(win, READER_WIN) - ttl if 0 < ttl < min(win, READER_WIN) else 0)
# The ops, applied as if one after the other — a label's rows go, and an add
# puts one at the end — in one pass: a label's last op decides, and its
# re-insertion into `adds` puts it in that op's place. The pass per op it
# replaced was quadratic in rows × ops.
touched = {label for _, label in ops}
rows = [r for r in rows if r[0] not in touched]
adds = {}
for sign, label in ops:
    adds.pop(label, None)
    if sign == '+':
        adds[label] = f"{stamp} {label}"
rows = [line for _, line in rows] + list(adds.values())
# Age pruning already ran, so the cap can only ever drop the oldest of the
# still-live entries — never a running agent while a stale row survives —
# and finished rows go before any running one: the first `excess` finished
# rows, then from the front. One pass, where a scan per dropped row was
# quadratic.
def done(r):
    return r.partition(' ')[2].startswith(DONE)
excess = len(rows) - max(cap, 0)
if excess > 0:
    gone = set()
    for i, r in enumerate(rows):
        if len(gone) >= excess:
            break
        if done(r):
            gone.add(i)
    rows = [r for i, r in enumerate(rows) if i not in gone][excess - len(gone):]

# Temp file beside the registry, then an atomic rename: the reader, which
# takes no lock, sees the old file or the new one, never a half-written one.
# The name is unique to this process (pid + random) and opened O_EXCL |
# O_NOFOLLOW, which is all tempfile.mkstemp added, without its import.
tmp = None
try:
    tname = f"{name}.{os.getpid()}.{os.urandom(4).hex()}"
    tfd = os.open(tname, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dfd)
    tmp = tname
    with os.fdopen(tfd, 'wb') as f:
        # 0600 whatever the umask was: the labels are nobody else's
        # business. A registry an earlier release left at 0644 is replaced
        # by this one.
        os.fchmod(f.fileno(), 0o600)
        f.write(''.join(r + '\n' for r in rows).encode('utf-8', 'surrogateescape'))
    os.replace(tmp, name, src_dir_fd=dfd, dst_dir_fd=dfd)
    tmp = None
    if moved:
        try:
            os.unlink(legacy)
        except OSError:
            pass
except OSError as e:
    skip(f"cannot write the registry ({e.strerror})")
finally:
    if tmp:
        try:
            os.unlink(tmp, dir_fd=dfd)
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
def lstat_at(n):
    try:
        return os.stat(n, dir_fd=dfd, follow_symlinks=False)
    except OSError:
        return None
if lstat_at(name + '.d') is not None or os.fstat(fd).st_size == 0:
    import shutil
    cutoff, pending = time.time() - 60, False
    try:
        names = os.listdir(dfd)
    except (OSError, TypeError):
        names = []
    for n in [name + '.d'] + [x for x in names if x.startswith(name + '.d.stale.')]:
        st = lstat_at(n)
        if st is None or st.st_uid != UID:
            continue
        if st.st_mtime > cutoff:
            pending = True  # possibly live: look again on a later write
            continue
        try:
            if stat.S_ISDIR(st.st_mode):
                shutil.rmtree(os.path.join(dpath, n), ignore_errors=True)
            else:
                os.unlink(n, dir_fd=dfd)
        except OSError:
            pass
    if not pending:
        try:
            os.pwrite(fd, b'2', 0)
        except OSError:
            pass
PYEOF
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
