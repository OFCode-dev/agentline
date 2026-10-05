#!/bin/bash
# agentline: the API meter. Books what a Claude Code session spent on
# external model APIs and workers, for the 🔌 segment on line 3:
#
#   🔌 hetzner 12·51k · jev 303·70k · codex 4 · $0.01
#
# Usage:
#   agentline-meter.sh add <provider[/model]> [--calls N] [--in N] [--out N]
#                          [--cost USD] [--errors N] [--usage FILE|-]
#                          [--session ID]
#
#   agentline-meter.sh add hetzner --usage response.json
#   curl ... | tee out.json | agentline-meter.sh add nim --usage -
#   agentline-meter.sh add jev --in 230 --cost 0.00000966
#   agentline-meter.sh add codex/gpt-6-astra
#
# Sourced, it offers the same as a function: agentline_meter add ...
#
# What is stored is totals, never events, and never anything but numbers:
# one row per provider, "<provider> <src> <calls> <errors> <tok_in>
# <tok_out> <cost_nano_usd>", in claude_api.v1.<session id> in the side
# directory agentline.sh reads. <src> is "c" for what a client reported
# through this helper; "h" rows (observed by a hook) are kept as they are.
#
#   provider  [a-z][a-z0-9-]{0,11} that passes the secret check; anything
#             else is booked as "other". A "/model" suffix is dropped: the
#             model is not shown, and it is where a key would hide.
#   --calls   default 1. --in/--out/--errors default 0. Each 1-15 ASCII
#             digits, or nothing is recorded.
#   --cost    a decimal number of USD (at most 9 digits before the point
#             and 12 after), kept as integer nano-USD: no float anywhere.
#   --usage   a saved API response, or a bare usage object, from a file or
#             stdin ("-"), at most 4 MB. Only the numbers are taken: the
#             top-level "usage" object's prompt_tokens/input_tokens,
#             completion_tokens/output_tokens (total_tokens when neither is
#             there, booked as input) and a top-level total_cost_usd or
#             cost_usd. The flags add to what it finds. A FILE must be a
#             regular file; "-" and /dev/fd/N (a process substitution) may
#             be a pipe, read for 3 s at most. A terminal, a named FIFO, a
#             device or a pipe still open after 3 s books the call alone.
#   --session default $CLAUDE_CODE_SESSION_ID. A session id is 1-64 of
#             [A-Za-z0-9_-] and not "default"; with none, or another,
#             nothing is written.
#
# Every write is one python3 run holding flock(2) on claude_api.lock. It
# waits as long as other writes get through (60 s at most), and only a lock
# nobody has got for 10 s skips the write, with a note, rather than racing
# it. --usage gets 3 s to arrive.
# Totals saturate below 10^15 and never go down. It always exits 0, and its
# notes name no provider and no value: a status-bar meter must never break
# the pipeline it measures. Once a day the first write deletes the ledgers
# that have been idle for more than 7 days.
#
# Environment:
#   AGENTLINE_TMP          side-file directory shared with agentline.sh
#                          (default: $XDG_RUNTIME_DIR/agentline when that is
#                          a directory of yours, else
#                          ${TMPDIR:-/tmp}/agentline-$EUID; created 0700,
#                          used only when it is yours and nobody else can
#                          write to it)
#   CLAUDE_CODE_SESSION_ID the session to book to, when --session is absent

AGENTLINE_METER_DEFAULT=""  # set: the private default directory, created here
if [ -n "${AGENTLINE_TMP-}" ]; then
  AGENTLINE_METER_DIR="$AGENTLINE_TMP"
else
  if [ -n "${XDG_RUNTIME_DIR-}" ] && [ -d "$XDG_RUNTIME_DIR" ] && [ ! -L "$XDG_RUNTIME_DIR" ] && [ -O "$XDG_RUNTIME_DIR" ]; then
    AGENTLINE_METER_DIR="$XDG_RUNTIME_DIR/agentline"
  else
    AGENTLINE_METER_DIR="${TMPDIR:-/tmp}/agentline-${EUID:-0}"
  fi
  AGENTLINE_METER_DEFAULT=1
fi

# The program is read into a variable at top level and run with
# `python3 -I -c`: `python3 -I -` with a heredoc would take stdin, and
# stdin is where `--usage -` brings its data. `|| :` because read returns
# 1 at the end of its input, and a caller may source this under `set -e`.
IFS= read -r -d '' _AGENTLINE_METER_PY <<'PYEOF' || :
import errno, fcntl, json, math, os, re, select, signal, stat, sys, time

dpath, created, sid = sys.argv[1:4]
args = sys.argv[4:]

def note(msg):
    # Fixed text only: no provider, no value, no path. The caller's
    # arguments can hold anything, a key included.
    sys.stderr.write('agentline-meter: ' + msg + '\n')

def done(msg=None):
    if msg:
        note(msg)
    sys.exit(0)

# Checked by the shell already; again here, so a sourced copy with an
# edited shell part cannot write a ledger under any other name.
SID = re.compile(r'[A-Za-z0-9_-]{1,64}')
NAME = re.compile(r'[a-z][a-z0-9-]{0,11}')
# [0-9] in a str pattern is ASCII only: '²'.isdigit() and '٣'.isdigit()
# are both true, and int('٣٠') is 30.
NUM = re.compile(r'[0-9]{1,15}')
COST = re.compile(r'([0-9]{1,9})(?:\.([0-9]{1,12}))?')
TOP = 10 ** 15 - 1          # a total saturates here: 15 digits, what a reader accepts
REC = {'calls': 10 ** 6, 'errs': 10 ** 6, 'tin': 10 ** 12, 'tout': 10 ** 12,
       'cost': 10 ** 14}    # one record at most: a million calls, $100,000
MAX_PROVIDERS = 16          # per src; a 17th is booked as "other"
LEDGER_BYTES, LEDGER_ROWS = 64 * 1024, 64
USAGE_BYTES = 4 * 1024 * 1024
UID = os.getuid()

if not SID.fullmatch(sid) or sid == 'default':
    done()

# The secret heuristic of agentline-subagents.sh, the same definition (the
# test suite compares the copies; see the reasoning there). A provider name
# is shown on the status line, so it passes the check every shown
# identifier passes, and one that fails is booked as "other".
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

def provider(s):
    s = s.split('/', 1)[0]
    return s if NAME.fullmatch(s) and not secretish(s) else 'other'

def nano(s):
    """A decimal USD string as integer nano-USD, rounded half up; None when
    it is no such string."""
    m = COST.fullmatch(s)
    if not m:
        return None
    frac = (m.group(2) or '').ljust(12, '0')
    return int(m.group(1)) * 10 ** 9 + int(frac[:9]) + (1 if int(frac[9:]) >= 500 else 0)

if not args or args[0].startswith('--'):
    done('usage: agentline-meter.sh add <provider> [--calls N] [--in N] [--out N] '
         '[--cost USD] [--errors N] [--usage FILE|-] [--session ID]')
name = provider(args[0])
FLAGS = {'--calls': 'calls', '--in': 'tin', '--out': 'tout', '--errors': 'errs',
         '--cost': 'cost', '--usage': 'usage', '--session': None}
opts, rest = {}, args[1:]
while rest:
    if rest[0] not in FLAGS or len(rest) < 2:
        done('unknown option or missing value, nothing recorded')
    if FLAGS[rest[0]]:
        opts[FLAGS[rest[0]]] = rest[1]
    rest = rest[2:]

rec = {'calls': 1, 'errs': 0, 'tin': 0, 'tout': 0, 'cost': 0}
for k in ('calls', 'errs', 'tin', 'tout'):
    if k in opts:
        if not NUM.fullmatch(opts[k]):
            done('a count is not a number of 1-15 digits, nothing recorded')
        rec[k] = int(opts[k])
if 'cost' in opts:
    n = nano(opts['cost'])
    if n is None:
        done('--cost is not a plain decimal number of USD, nothing recorded')
    rec['cost'] = n

# --usage: one json.loads of the whole document, and only allowlisted
# numbers out of it. An integer literal past 16 digits is not converted
# (Python 3.11+ raises on 4300 digits, and none is a count anyway); NaN
# and Infinity come back as floats and fail the finiteness test below.
TOKEN_KEYS = ('prompt_tokens', 'input_tokens', 'completion_tokens', 'output_tokens', 'total_tokens')

USAGE_SECS = 3              # --usage gets this long to arrive, then is ignored
# Bash's process substitution, <(...): a pipe reached by name.
FD_PATH = re.compile(r'/dev/fd/[0-9]{1,9}')

def read_usage(src):
    """The --usage document, or None. Never waits on a terminal, a FIFO
    nobody writes to, or a pipe that never closes: a named file opens with
    O_NONBLOCK and O_NOCTTY and must be a regular file, or a pipe when it
    is "-" or /dev/fd/N; a pipe is read under select() for USAGE_SECS at
    most, the size cap included."""
    fd = None
    try:
        if src == '-':
            rfd = 0
        else:
            fd = rfd = os.open(src, os.O_RDONLY | os.O_NONBLOCK | getattr(os, 'O_NOCTTY', 0))
        st = os.fstat(rfd)
        if stat.S_ISREG(st.st_mode):
            data, end = b'', time.monotonic() + USAGE_SECS
            while len(data) <= USAGE_BYTES and time.monotonic() < end:
                chunk = os.read(rfd, USAGE_BYTES + 1 - len(data))
                if not chunk:
                    break
                data += chunk
        elif stat.S_ISFIFO(st.st_mode) and (src == '-' or FD_PATH.fullmatch(src)):
            data, end = b'', time.monotonic() + USAGE_SECS
            while len(data) <= USAGE_BYTES:
                left = end - time.monotonic()
                if left <= 0:
                    return None  # still open after USAGE_SECS: not waited for
                if not select.select([rfd], [], [], left)[0]:
                    continue
                try:
                    chunk = os.read(rfd, USAGE_BYTES + 1 - len(data))
                except BlockingIOError:
                    continue
                if not chunk:
                    break
                data += chunk
        else:
            return None  # a terminal, a device, a socket, a named FIFO
    except (OSError, ValueError):
        return None
    finally:
        if fd is not None:
            os.close(fd)
    if len(data) > USAGE_BYTES:
        return None
    try:
        return json.loads(data, parse_int=lambda s: int(s) if len(s) <= 16 else -1)
    except (Exception, RecursionError):
        return None

def count(u, *keys):
    for k in keys:
        v = u.get(k)
        if type(v) is int and 0 <= v <= TOP:
            return v
    return None

def usd(v):
    """A JSON cost as nano-USD: an int, or a finite float written out as a
    decimal (repr can give '1e-05'); None for anything else."""
    if type(v) is int and 0 <= v <= 999999999:
        return v * 10 ** 9
    if type(v) is float and math.isfinite(v) and 0 <= v < 1e9:
        return nano(format(v, '.12f'))
    return None

if 'usage' in opts:
    doc = read_usage(opts['usage'])
    if not isinstance(doc, dict):
        note('--usage holds no JSON object (or is past 4 MB, not a file or a pipe, or not closed within '
             '%d s), its numbers are not counted' % USAGE_SECS)
    else:
        u = doc.get('usage') if 'usage' in doc else (doc if any(k in doc for k in TOKEN_KEYS) else None)
        if isinstance(u, dict):
            tin, tout = count(u, 'prompt_tokens', 'input_tokens'), count(u, 'completion_tokens', 'output_tokens')
            if tin is None and tout is None:
                tin = count(u, 'total_tokens')
            rec['tin'] += tin or 0
            rec['tout'] += tout or 0
        for k in ('total_cost_usd', 'cost_usd'):
            if k in doc:
                c = usd(doc[k])
                if c is not None:
                    rec['cost'] += c
                break

for k, cap in REC.items():
    rec[k] = min(rec[k], cap)
if not any(rec.values()):
    done()  # nothing to book

# The directory, opened once and checked through that descriptor: ours, not
# a symlink, writable by nobody else. One made just now is set to 0700.
# Every file below is opened relative to it.
# O_NOFOLLOW refuses a symlink only as the last component, and "link/" or
# "link/." ends in a component that is the directory the link points to:
# trailing "/" and "/." go first, so the link itself is what is opened.
while len(dpath) > 1 and (dpath.endswith('/') or dpath.endswith('/.')):
    dpath = dpath[:-1] if dpath.endswith('/') else (dpath[:-2] or '/')
try:
    dfd = os.open(dpath, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    dst = os.fstat(dfd)
except OSError:
    done('the side directory is missing, not a directory or a symlink, nothing recorded')
if dst.st_uid != UID:
    done('the side directory is not yours, nothing recorded')
if created == '1':
    try:
        os.fchmod(dfd, 0o700)
    except OSError:
        done('cannot make the side directory private, nothing recorded')
elif dst.st_mode & 0o022:
    done('the side directory is writable by others, nothing recorded')

NB = os.O_NONBLOCK | getattr(os, 'O_NOCTTY', 0)

def open_reg(n, flags):
    """A descriptor for n: a regular file of ours, opened without following
    a symlink and without blocking on a FIFO, blocking again once it is
    known to be a file."""
    fd = os.open(n, flags | os.O_NOFOLLOW | NB, 0o600, dir_fd=dfd)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != UID:
            raise OSError(errno.EPERM, 'not a regular file of yours')
        if st.st_mode & 0o077:
            os.fchmod(fd, 0o600)  # a lock or ledger left readable by an older umask
        fcntl.fcntl(fd, fcntl.F_SETFL, fcntl.fcntl(fd, fcntl.F_GETFL) & ~os.O_NONBLOCK)
    except BaseException:
        os.close(fd)
        raise
    return fd

def lstat_at(n):
    try:
        return os.stat(n, dir_fd=dfd, follow_symlinks=False)
    except OSError:
        return None

# One lock for the directory, held for the read-modify-write. The meter
# runs after the work it books, so waiting is cheap and a lost count is
# not: flock(2) blocks, woken by the kernel the moment the lock is free (a
# 50 ms poll lost bookings to a burst of 64 writers). A one-shot SIGALRM
# wakes it every second to see whether anyone is getting through: every
# write renames a file into the directory, which moves its mtime. A queue
# that moves is waited for, up to LOCK_MAX (on a loaded host 64 writers
# can take longer than 10 s between them); a lock nobody has got for
# LOCK_IDLE seconds, a stuck holder, skips the write. (The registry
# helper renames into the same directory, so its writes can stretch a
# wait on a stuck holder to LOCK_MAX; never past it.)
# agentline.sh's daily prune of files idle for a week leaves *.lock alone,
# but an older release's did not; a writer that locked a file deleted (and
# maybe re-created) under it holds nothing, so the name is checked again
# after the lock is taken, and the lock taken again when it moved.
LOCK = 'claude_api.lock'
LOCK_IDLE, LOCK_MAX = 10, 60

class Late(Exception):
    pass

def late(signum, frame):
    raise Late()

def dir_mtime():
    try:
        return os.fstat(dfd).st_mtime_ns
    except OSError:
        return None

def lock(fd):
    """flock(fd, LOCK_EX) under the rule above: True when held, False when
    the queue stood still for LOCK_IDLE s (or LOCK_MAX passed), None on an
    error."""
    start = moved = time.monotonic()
    seen = dir_mtime()
    signal.signal(signal.SIGALRM, late)
    try:
        while True:
            now = time.monotonic()
            left = min(LOCK_IDLE - (now - moved), start + LOCK_MAX - now)
            if left <= 0:
                return False
            got = False
            # The handler raises, so flock is not restarted after EINTR.
            # The timer is one-shot and disarmed before the outer try is
            # left, so Late is raised once at most per round, and always
            # inside it; one that lands after flock returned changes nothing.
            try:
                try:
                    signal.setitimer(signal.ITIMER_REAL, min(left, 1.0))
                    fcntl.flock(fd, fcntl.LOCK_EX)
                    got = True
                finally:
                    signal.setitimer(signal.ITIMER_REAL, 0)
            except Late:
                pass
            except OSError:
                return True if got else None
            if got:
                return True
            m = dir_mtime()
            if m != seen:
                seen, moved = m, time.monotonic()
    finally:
        signal.signal(signal.SIGALRM, signal.SIG_DFL)

fd = None
for _ in range(3):
    try:
        fd = open_reg(LOCK, os.O_RDWR | os.O_CREAT)
    except OSError:
        done('cannot open the lock, nothing recorded')
    got = lock(fd)
    if got is None:
        done('cannot lock, nothing recorded')
    if not got:
        done('ledger busy, nothing recorded')
    held, now_at = os.fstat(fd), lstat_at(LOCK)
    if now_at is not None and (now_at.st_ino, now_at.st_dev) == (held.st_ino, held.st_dev):
        break
    os.close(fd)
    fd = None
if fd is None:
    done('the lock keeps moving, nothing recorded')

# The ledger: its first 64 KB and 64 lines, a regular file of ours (a FIFO
# or symlink in its place reads as empty and is replaced, never followed).
# Rows already stored pass the reader's rules again; a name that fails the
# secret check now is folded into "other".
LEDGER = 'claude_api.v1.' + sid
lines = []
try:
    rfd = open_reg(LEDGER, os.O_RDONLY)
except OSError:
    rfd = None
if rfd is not None:
    with os.fdopen(rfd, 'rb') as f:
        data = f.read(LEDGER_BYTES + 1)
    if len(data) > LEDGER_BYTES:
        data = data[:data.rfind(b'\n', 0, LEDGER_BYTES) + 1]
    lines = data.decode('ascii', 'replace').split('\n')[:LEDGER_ROWS]

FIELDS = ('calls', 'errs', 'tin', 'tout', 'cost')
rows = {}  # (provider, src) -> [calls, errs, tin, tout, cost], in file order
for line in lines:
    f = line.split(' ')
    if len(f) != 7 or f[1] not in ('c', 'h') or not NAME.fullmatch(f[0]) \
            or not all(NUM.fullmatch(x) for x in f[2:]):
        continue
    key = (f[0] if not secretish(f[0]) else 'other', f[1])
    vals = [int(x) for x in f[2:]]
    old = rows.get(key, [0] * 5)
    rows[key] = [min(a + b, TOP) for a, b in zip(old, vals)]

if (name, 'c') not in rows and name != 'other' and \
        sum(1 for p, s in rows if s == 'c' and p != 'other') >= MAX_PROVIDERS:
    name = 'other'
old = rows.get((name, 'c'), [0] * 5)
rows[(name, 'c')] = [min(a + rec[k], TOP) for a, k in zip(old, FIELDS)]

# A temp file beside the ledger, then an atomic rename: the reader takes no
# lock and sees the old file or the new one. The name has a dot after the
# session id, which no session id has, so it is never another's ledger.
tmp = None
try:
    tname = '%s.%d.%s' % (LEDGER, os.getpid(), os.urandom(4).hex())
    tfd = os.open(tname, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dfd)
    tmp = tname
    with os.fdopen(tfd, 'w') as f:
        os.fchmod(f.fileno(), 0o600)
        f.write(''.join('%s %s %s\n' % (p, s, ' '.join(str(v) for v in vals))
                        for (p, s), vals in rows.items()))
    os.replace(tmp, LEDGER, src_dir_fd=dfd, dst_dir_fd=dfd)
    tmp = None
except OSError:
    done('cannot write the ledger, nothing recorded')
finally:
    if tmp:
        try:
            os.unlink(tmp, dir_fd=dfd)
        except OSError:
            pass

# Once a day at most (the epoch of the last sweep is the lock file's
# content; it means nothing to flock): ledgers idle for more than 7 days
# go, and temp files a killed writer left. Ours, regular files, by name;
# never the lock, never anything written within the week.
now = int(time.time())
try:
    stamp = os.pread(fd, 32, 0).strip()
except OSError:
    stamp = b''
if not re.fullmatch(rb'[0-9]{1,12}', stamp) or now - int(stamp) >= 86400:
    try:
        os.ftruncate(fd, 0)
        os.pwrite(fd, str(now).encode(), 0)
        names = os.listdir(dfd)
    except (OSError, TypeError):
        names = []
    for n in names:
        if not n.startswith('claude_api.v1.'):
            continue
        st = lstat_at(n)
        if st is None or not stat.S_ISREG(st.st_mode) or st.st_uid != UID or st.st_mtime > now - 7 * 86400:
            continue
        try:
            os.unlink(n, dir_fd=dfd)
        except OSError:
            pass
PYEOF

# agentline_meter add <provider[/model]> [options] — see the top of the file.
# Returns 0 whatever happens.
agentline_meter() {
  local op="${1-}" sid="${CLAUDE_CODE_SESSION_ID-}" dir created=0 a want=""
  if [ "$op" != add ] || [ $# -lt 2 ]; then
    printf '%s\n' "usage: agentline-meter.sh add <provider[/model]> [--calls N] [--in N] [--out N] [--cost USD] [--errors N] [--usage FILE|-] [--session ID]" >&2
    return 0
  fi
  shift
  # --session wins over the environment, valid or not: the caller named
  # the session, and an invalid one books nothing rather than another.
  # Options are read in pairs after the provider, so an option's value
  # (a --usage file named "--session", say) is never taken for one.
  set -- ${1+"$@"}
  a=2
  while [ "$a" -le $# ]; do
    eval "want=\${$a}"
    case "$want" in
      --session) a=$(( a + 1 )); [ "$a" -le $# ] && eval "sid=\${$a}" ;;
      --calls|--in|--out|--cost|--errors|--usage) a=$(( a + 1 )) ;;
    esac
    a=$(( a + 1 ))
  done
  want=""
  # The one rule for a ledger name, here and in agentline.sh: 1-64 of
  # [A-Za-z0-9_-], spelled out (bash 3.2 matches a range by collation),
  # and not "default", agentline.sh's name for a session it cannot name.
  case "$sid" in
    ''|default|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-]*) return 0 ;;
  esac
  [ ${#sid} -le 64 ] || return 0
  if ! command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "agentline-meter: python3 not found, nothing recorded" >&2
    return 0
  fi
  # The directory is checked for real by the python3 (ours, not a link,
  # writable by nobody else); here it is only created. -m sets the mode at
  # creation; created=1 lets the check set a directory made now to 0700.
  dir="$AGENTLINE_METER_DIR"
  if [ ! -d "$dir" ]; then
    if [ -n "$AGENTLINE_METER_DEFAULT" ]; then
      mkdir -m 700 "$dir" 2>/dev/null && created=1
    else
      ( umask 077; mkdir -p "$dir" 2>/dev/null ) && created=1
    fi
  fi
  # -I: this runs in the caller's directory, where `python3 -c` would
  # import a json.py lying there. umask 077 in a subshell: the caller's
  # umask is not ours to change.
  ( umask 077
    python3 -I -c "$_AGENTLINE_METER_PY" "$dir" "$created" "$sid" "$@" ) || :
  return 0
}

# Run as a command when executed directly; stay quiet when sourced.
if [ "${BASH_SOURCE[0]-}" = "$0" ]; then
  agentline_meter ${1+"$@"}
  exit 0
fi
