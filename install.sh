#!/bin/bash
# Installs agentline into ~/.claude/ and wires it into settings.json.
#
#   bash install.sh               install or upgrade the status bar
#   bash install.sh --with-hooks  also wire the optional word-counter and
#                                 agent-tracker hooks (see README)
#   bash install.sh --force       replace a statusLine that is not agentline
#                                 (another tool's, or your own script) instead
#                                 of leaving it and printing the snippet
#   bash install.sh --theme light also set AGENTLINE_THEME (dark|light|mono) in
#                                 settings.json's env block
#   bash install.sh --glyphs ascii
#                                 also set AGENTLINE_GLYPHS (emoji|ascii)
#   bash install.sh --with-subagents
#                                 also set subagentStatusLine to
#                                 agentline-subagents.sh: rich rows in Claude
#                                 Code's subagent panel (see README)
#   bash install.sh --link-bin    also symlink ~/.local/bin/agentline-run, so
#                                 a shell finds it on PATH
#
# agentline-subagents.sh, agentline-run and the agent registry helper
# (agentline-agent.sh) are always copied next to agentline.sh: they do
# nothing until a setting or a command runs them.
#
# Exit status: 0 installed and active, 1 settings.json unusable or unwritable
# (a file that does not parse, or cannot take --with-hooks — a "hooks" that is
# not an object, an event or a group's "hooks" that is not a list — is refused
# before anything is copied or written; a write that fails later leaves the
# file whole, with the run's backup beside it; hooks that could be wired only
# in part are reported as such, never as wired), 2 bad option, 3 installed but NOT
# active — settings.json runs another status line, which was left alone
# (re-run with --force, or merge the printed snippet), and --with-hooks was
# not wired for it; or, with --with-subagents, another subagentStatusLine,
# left alone the same way.
#
# settings.json belongs to the user, so every edit to it is guarded: a file
# that does not parse is refused rather than rewritten, a timestamped backup is
# taken before the first write of a run (the newest 5 are kept), and the new
# content is swapped in atomically. A symlinked settings.json is edited, and
# backed up, at the link's target.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="$HOME/.claude/settings.json"
DEFAULT_DEST="$HOME/.claude/agentline/agentline.sh"
SVC_EXAMPLE="$SCRIPT_DIR/agentline-services.conf.example"
SVC_CONFIG="$HOME/.claude/agentline-services.conf"
OLD_SVC_CONFIG="$HOME/.claude/statusline-services.conf"
KEEP_BACKUPS=5

usage() {
  echo "usage: bash install.sh [--with-hooks] [--with-subagents] [--link-bin] [--force] [--theme dark|light|mono] [--glyphs emoji|ascii]"
}

WITH_HOOKS=0
WITH_SUB=0
LINK_BIN=0
FORCE=0
THEME=""
GLYPHS=""
while [ $# -gt 0 ]; do
  arg="$1"; shift
  case "$arg" in
    --with-hooks) WITH_HOOKS=1 ;;
    --with-subagents) WITH_SUB=1 ;;
    --link-bin)   LINK_BIN=1 ;;
    --force)      FORCE=1 ;;
    --theme|--glyphs)
      if [ $# -eq 0 ]; then echo "✗ $arg needs a value" >&2; usage >&2; exit 2; fi
      set -- "$arg=$1" "${@:2}"; continue ;;
    --theme=*)    THEME="${arg#--theme=}" ;;
    --glyphs=*)   GLYPHS="${arg#--glyphs=}" ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "✗ unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done
# --theme / --glyphs write AGENTLINE_THEME / AGENTLINE_GLYPHS into the env
# block of settings.json, where they survive every upgrade. Nothing is
# detected: the background colour could only be asked of the terminal (an
# OSC 11 query), and this script usually runs where there is none to ask —
# from Claude Code's Bash tool, over SSH, under tmux — or in a terminal other
# than the one the status line will be drawn in, and many people switch
# light/dark with the OS. So the choice is the user's; COLORFGBG, where the
# terminal sets it, is only printed as a hint (see below).
case "$THEME" in ''|dark|light|mono) ;; *) echo "✗ --theme must be dark, light or mono (got: $THEME)" >&2; exit 2 ;; esac
case "$GLYPHS" in ''|emoji|ascii) ;; *) echo "✗ --glyphs must be emoji or ascii (got: $GLYPHS)" >&2; exit 2 ;; esac

# One stamp per run, so the settings.json backup and the script backup of the
# same upgrade carry the same suffix and a run never backs up twice. UTC, so
# name order stays age order across a DST change — the backup pruning relies
# on that.
STAMP=$(date -u +%Y%m%d-%H%M%S)

# All settings.json handling lives in this one python program, so every step
# shares the same loader, backup and writer:
#
#   settings_py resolve    <settings> <stamp> <default_dest>
#   settings_py statusline <settings> <stamp> <dest> <force>
#   settings_py hooks      <settings> <stamp> <hooks_dest>
#   settings_py subresolve <settings> <stamp> <default_dest>
#   settings_py subagents  <settings> <stamp> <dest> <force>
#   settings_py env        <settings> <stamp> KEY=VALUE...
#
# A parse error is fatal and never written back. Before the fix, any error
# turned into `d = {}` and the next save replaced the file with a lone
# statusLine entry — one trailing comma cost the user every permission, hook
# and env override they had, with no backup to recover from.
settings_py() {
  # -I (isolated): the installer is often run from a checkout or a download
  # directory, and plain `python3 -` would import a json.py or shutil.py
  # sitting in the current directory instead of the standard one.
  python3 -I - "$@" <<'PYEOF'
import errno, json, os, shlex, shutil, stat, sys, tempfile

mode, settings_path, stamp = sys.argv[1], sys.argv[2], sys.argv[3]
args = sys.argv[4:]
KEEP_BACKUPS = 5
EXIT_NOT_ACTIVE = 3  # see the header of install.sh

# Match on the script's file name, never on a substring of the command. The
# old `"statusline" in command` test also matched third-party status lines
# (`npx -y ccstatusline@latest`) and a user's own `my-statusline.sh`, and
# silently repointed them. statusline-command.sh (the statusline-5 skill this
# project grew out of) and statusline.sh are agentline's pre-rename names —
# but they are also the most common names of somebody else's status line:
# ~/.claude/statusline.sh is the docs example and ~/.claude/statusline-command.sh
# is what Claude Code's own /statusline setup writes. A pre-rename name alone
# therefore proves nothing; see pre_rename_is_ours().
AGENTLINE_NAMES = {'agentline.sh'}
# subagentStatusLine's script (--with-subagents), recognised the same way.
SUBAGENT_NAMES = {'agentline-subagents.sh'}
PRE_RENAME_NAMES = {'statusline.sh', 'statusline-command.sh'}
# Strings only an agentline script itself contains: its header line, and the
# service-list file the pre-rename script read (statusline-services.conf).
# Not the bare word "agentline" — a user's wrapper that runs agentline and
# pipes it through sed contains that too, and was replaced.
AGENTLINE_MARKERS = (
    '# agentline — a four-line, zero-dependency status bar for Claude Code.'.encode(),
    b'statusline-services.conf',
)
MARKER_SCAN = 1 << 16  # the header is line 2; the conf name sits near the top
# The events --with-hooks registers (see mode 'hooks'), validated up front.
HOOK_EVENTS = ('PostToolUse', 'Stop', 'PreToolUse', 'SubagentStart', 'SubagentStop')

# Dotfile managers often make settings.json a symlink into a repo. Writing to
# the resolved target keeps that link intact; os.replace on the link itself
# would swap it for a plain file.
real_path = os.path.realpath(settings_path)

def fail(msg):
    sys.stderr.write(f"✗ {msg}\n  Nothing was changed. Fix the file and re-run install.sh.\n")
    sys.exit(1)

def load_settings():
    try:
        with open(real_path) as f:
            text = f.read()
    except FileNotFoundError:
        return {}
    if not text.strip():
        return {}
    try:
        d = json.loads(text)
    except json.JSONDecodeError as e:
        fail(f"{settings_path} is not valid JSON (line {e.lineno}): {e.msg}")
    if not isinstance(d, dict):
        fail(f"{settings_path} is not a JSON object")
    return d

def backup():
    """Copy the file aside once per run, then keep only the newest few. The
    stamp sorts chronologically, so a name sort is an age sort."""
    bak = f"{real_path}.agentline-bak-{stamp}"
    if os.path.exists(real_path) and not os.path.exists(bak):
        shutil.copy2(real_path, bak)  # copy2 keeps the mode: env may hold tokens
        print(f"• Backed up settings.json -> {bak}")
    folder, prefix = os.path.split(real_path)
    prefix += '.agentline-bak-'
    for name in sorted(n for n in os.listdir(folder) if n.startswith(prefix))[:-KEEP_BACKUPS]:
        try:
            os.remove(os.path.join(folder, name))
        except OSError:
            pass

def save(d):
    """Write beside the target and rename over it: a crash or a full disk
    mid-write leaves the old file whole instead of a truncated one."""
    backup()
    text = json.dumps(d, indent=2) + '\n'
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(real_path), prefix='.settings.json.')
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(text)
        try:
            os.chmod(tmp, os.stat(real_path).st_mode & 0o7777)
        except OSError:
            pass
        try:
            os.replace(tmp, real_path)
            return
        except OSError as e:
            # A settings.json bind-mounted on its own (a devcontainer's
            # `-v ~/.claude/settings.json:…`) is a mount point: rename onto it
            # fails with EBUSY (EXDEV or EPERM on some kernels and overlay
            # setups) although the file itself is writable. Fall back to
            # rewriting it in place; the backup above is the safety net that
            # the atomic swap would otherwise have been.
            if e.errno not in (errno.EBUSY, errno.EXDEV, errno.EPERM):
                raise
        os.unlink(tmp)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    try:
        with open(real_path, 'w') as f:
            f.write(text)
    except OSError as e:
        sys.stderr.write(f"✗ could not write {settings_path}: {e.strerror}\n"
                         f"  Restore it from the backup {real_path}.agentline-bak-{stamp} if it is damaged.\n")
        sys.exit(1)
    print("  • settings.json cannot be swapped atomically (a bind mount?); rewritten in place")

def words(s):
    """Shell words of `s`, with ; | & ( ) < > split off as words of their own."""
    try:
        lex = shlex.shlex(s, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        return list(lex)
    except ValueError:
        return s.split()

def script_path(cmd):
    """The .sh a command runs: "bash ~/x/agentline.sh" -> "/home/u/x/agentline.sh"."""
    try:
        parts = shlex.split(cmd)
    except ValueError:
        parts = cmd.split()
    for part in parts:
        if part.endswith('.sh'):
            return os.path.expanduser(os.path.expandvars(part))
    return ''

def own_script(cmd, default_dest, names=AGENTLINE_NAMES):
    """(path, wrapped): the agentline script `cmd` runs, or ('', False) when
    that is not certain. wrapped is True when the script is not the command
    itself but is run from inside it — `bash -c "AGENTLINE_TZ=UTC exec
    ~/x/agentline.sh"`, or agentline piped through sed.

    script_path() takes the first token ending in .sh, which for such a
    wrapper is the whole quoted string — once taken for the install path, the
    installer mkdir'd that string under the cwd. So the words inside each
    argument are searched too, and only an absolute path naming an existing
    regular file (or the default location, which the install creates) is
    trusted; any other command is treated as not agentline's."""
    def trusted(path):
        return path == default_dest or (os.path.isabs(path) and os.path.isfile(path))
    path = script_path(cmd)
    if os.path.basename(path) in names and trusted(path):
        return path, False
    for part in words(cmd):
        for w in words(part):
            if os.path.basename(w) in names:
                path = os.path.expanduser(os.path.expandvars(w))
                if trusted(path):
                    return path, True
    return '', False

def has_marker(path):
    """Whether `path` is a regular file whose head carries an agentline
    marker. Opened non-blocking and checked with fstat before any read: a
    FIFO or a device at that name must never be read from — a FIFO with no
    writer would hang the installer, a tty or a device could block or eat
    input."""
    if not os.path.isabs(path):
        return False
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | getattr(os, 'O_NOCTTY', 0))
    except OSError:
        return False
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return False
        head = os.read(fd, MARKER_SCAN)
    except OSError:
        return False
    finally:
        os.close(fd)
    return any(m in head for m in AGENTLINE_MARKERS)

def pre_rename_is_ours(cmd):
    """Whether `cmd` runs agentline's own pre-rename statusline.sh /
    statusline-command.sh, and so is safe to repoint at the new install.

    Those names are also the commonest names of somebody else's status line,
    so neither the name nor the directory proves anything: the third-party
    rz1989s/claude-code-statusline installs to ~/.claude/statusline/statusline.sh,
    which a `statusline/`-directory rule silently took over. Two cases count:
      - the file carries an agentline marker (see AGENTLINE_MARKERS);
      - the command is one absolute path (after ~ expansion) that does not
        exist — a dangling command has nothing to lose. Only a lone token:
        in `bash -c "source ~/.profile; ~/.claude/statusline.sh"` the whole
        quoted string looks like a missing file, and an unexpanded
        `$XDG_CONFIG_HOME/claude/statusline.sh` may well exist at run time."""
    path = script_path(cmd)
    if os.path.basename(path) not in PRE_RENAME_NAMES:
        return False
    parts = words(cmd)
    if len(parts) == 1 and '$' not in parts[0]:
        lone = os.path.expanduser(parts[0])
        if (os.path.isabs(lone) and os.path.basename(lone) in PRE_RENAME_NAMES
                and not os.path.lexists(lone)):
            return True
    return has_marker(path)

d = load_settings()
sl = d.get('statusLine')
sl = dict(sl) if isinstance(sl, dict) else {}
existing = sl.get('command') or ''
if not isinstance(existing, str):
    existing = ''

if mode == 'resolve':
    # A custom agentline path is upgraded in place, also when a wrapper runs
    # it. Any other .sh — including a pre-rename one, which is migrated to the
    # default location so the old name does not live on — is never the copy
    # target: `cp` would overwrite somebody else's script.
    #
    # This first pass is also the validation pass, so a settings.json that
    # --with-hooks could not use either is refused here, before the script is
    # copied or statusLine is written, rather than half-way through the run.
    if args[1:2] == ['1']:
        hooks = d.get('hooks', {})
        if not isinstance(hooks, dict):
            fail(f"{settings_path}: \"hooks\" is not a JSON object")
        # Every shape the hooks pass will walk or append to. It used to find
        # these only after statusLine had been written: a non-list event was
        # skipped yet reported as wired, and a group whose "hooks" was not a
        # list crashed with a traceback, leaving the run half-applied.
        for ev in HOOK_EVENTS:
            groups = hooks.get(ev, [])
            if not isinstance(groups, list):
                fail(f"{settings_path}: \"hooks.{ev}\" is not a list")
            for g in groups:
                if isinstance(g, dict) and not isinstance(g.get('hooks') or [], list):
                    fail(f"{settings_path}: a \"hooks.{ev}\" entry has a \"hooks\" that is not a list")
    if args[2:3] == ['1'] and not isinstance(d.get('env', {}), dict):
        fail(f"{settings_path}: \"env\" is not a JSON object")
    print(own_script(existing, args[0])[0] or args[0])

elif mode == 'statusline':
    # An existing agentline command is left verbatim (it may carry an
    # interpreter prefix or a custom path); an empty command, or agentline's
    # own pre-rename one, is (re)pointed at dest, as is a foreign one under
    # --force.
    #
    # statusLine.refreshInterval is what makes the clock tick: without it
    # Claude Code only re-renders the status line on conversation events, so
    # the seconds freeze between messages. 1s is affordable because agentline
    # serves those ticks from its render cache. An interval the user already
    # chose is honoured.
    dest, force = args[0], args[1] == '1'
    own, wrapped = own_script(existing, dest)
    ours = bool(own)
    legacy = pre_rename_is_ours(existing)
    if not existing or legacy or (force and not ours):
        sl.update({'type': 'command', 'command': dest})
        print(f"✓ settings.json statusLine set to {dest}")
        if existing:
            print(f"  (was: {existing})")
    elif wrapped:
        # The wrapper is the user's (an env prefix, a pipe through sed) and
        # the copy it runs was just upgraded in place, so agentline is live.
        # --force is not suggested, and does not apply: it would drop the
        # wrapper along with whatever it sets.
        print(f"• agentline behind a wrapper — left as-is, upgraded in place: {existing}")
    elif ours:
        print(f"• settings.json left as-is: {existing}")
    else:
        # Someone else's status line. Say so and hand over the exact snippet
        # instead of taking it over, or of silently leaving a decoy copy. The
        # distinct exit status tells install.sh (and any script driving it)
        # that agentline is installed but not what Claude Code runs.
        snippet = json.dumps({'statusLine': {'type': 'command', 'command': dest,
                                             'refreshInterval': 1}}, indent=2)
        print(f"⚠ settings.json statusLine is not agentline: {existing}")
        print("  Left untouched. To switch, merge this into settings.json:")
        for row in snippet.splitlines()[1:-1]:
            print(f"  {row}")
        print("  or re-run: bash install.sh --force")
        sys.exit(EXIT_NOT_ACTIVE)
    if sl.get('refreshInterval') is not None:
        print(f"  • statusLine.refreshInterval left as-is: {sl['refreshInterval']}s")
    else:
        sl['refreshInterval'] = 1
        print("  ✓ statusLine.refreshInterval set to 1s (live clock)")
    if sl != d.get('statusLine'):
        d['statusLine'] = sl
        save(d)

elif mode in ('subresolve', 'subagents'):
    # subagentStatusLine under the statusLine rules: set when absent, an
    # agentline-subagents.sh already there kept verbatim (a custom path is
    # upgraded in place: subresolve names it as the copy target), someone
    # else's left alone unless --force, with the snippet to merge and exit 3.
    # It has no refreshInterval of its own: Claude Code runs it on the main
    # status line's ticks.
    ssl = d.get('subagentStatusLine')
    ssl = dict(ssl) if isinstance(ssl, dict) else {}
    cur = ssl.get('command') if isinstance(ssl.get('command'), str) else ''
    dest = args[0]
    own, wrapped = own_script(cur, dest, SUBAGENT_NAMES)
    if mode == 'subresolve':
        print(own or dest)
        sys.exit(0)
    force = args[1] == '1'
    if not cur or (force and not own):
        ssl.update({'type': 'command', 'command': dest})
        print(f"✓ settings.json subagentStatusLine set to {dest}")
        if cur:
            print(f"  (was: {cur})")
    elif own:
        print(f"• settings.json subagentStatusLine left as-is: {cur}")
    else:
        snippet = json.dumps({'subagentStatusLine': {'type': 'command', 'command': dest}}, indent=2)
        print(f"⚠ settings.json subagentStatusLine is not agentline: {cur}")
        print("  Left untouched. To switch, merge this into settings.json:")
        for line in snippet.splitlines()[1:-1]:
            print(f"  {line}")
        print("  or re-run: bash install.sh --with-subagents --force")
        sys.exit(EXIT_NOT_ACTIVE)
    if ssl != d.get('subagentStatusLine'):
        d['subagentStatusLine'] = ssl
        save(d)

elif mode == 'env':
    # KEY=VALUE pairs into settings.json's env block (--theme, --glyphs).
    # Claude Code hands that block to the status line's environment, and an
    # upgrade never touches it. The flag is an explicit request, so a
    # different value already there is replaced, and the old one printed;
    # an equal one is left as it is.
    env = d.setdefault('env', {})
    if not isinstance(env, dict):
        fail(f"{settings_path}: \"env\" is not a JSON object")
    changed = False
    for pair in args:
        key, _, value = pair.partition('=')
        if env.get(key) == value:
            print(f"• settings.json env {key} already {value}")
        else:
            print(f"✓ settings.json env {key}={value}" + (f" (was: {env[key]})" if key in env else ''))
            env[key] = value
            changed = True
    if changed:
        save(d)

elif mode == 'hooks':
    hooks_dest = args[0]
    hooks = d.setdefault('hooks', {})
    if not isinstance(hooks, dict):
        fail(f"{settings_path}: \"hooks\" is not a JSON object")
    changed = partial = False

    def ensure(event, matcher, command):
        """Idempotently add a command hook. A hook running a script of the
        same name counts as already present. It is repointed at the fresh
        install only when it is plainly a leftover — still in a pre-rename
        'statusline' directory, or dangling — so a copy the user keeps
        elsewhere on purpose is never rewritten."""
        global changed, partial
        base = os.path.basename(command)
        groups = hooks.setdefault(event, [])
        if not isinstance(groups, list):
            # The resolve pass refuses this before anything is written; kept
            # for a file edited in between, and then reported as partial.
            print(f"⚠ hooks.{event} is not a list; skipped")
            partial = True
            return
        for g in groups:
            for h in (g.get('hooks') or []) if isinstance(g, dict) else []:
                # Someone else's malformed entry (no dict, a command that is
                # not a string) is not ours, and is left exactly as it is.
                cmd = h.get('command') if isinstance(h, dict) else None
                if not isinstance(cmd, str):
                    continue
                path = script_path(cmd)
                if os.path.basename(path) != base:
                    continue
                if path != command and (
                        os.path.basename(os.path.dirname(path)) == 'statusline'
                        or not os.path.exists(path)):
                    h['command'] = command
                    changed = True
                return
        changed = True
        for g in groups:
            if isinstance(g, dict) and g.get('matcher', '') == matcher:
                if not isinstance(g.get('hooks'), list):
                    g['hooks'] = []  # absent or null: validated as nothing else
                g['hooks'].append({'type': 'command', 'command': command})
                return
        groups.append({'matcher': matcher, 'hooks': [{'type': 'command', 'command': command}]})

    wc = f"{hooks_dest}/wordcount-hook.sh"
    at = f"{hooks_dest}/agent-tracker-hook.sh"
    ensure('PostToolUse', '', wc)
    ensure('Stop', '', wc)
    # The subagent tool is 'Agent' in current Claude Code releases, 'Task' in
    # earlier ones; the regex matcher covers both.
    ensure('PreToolUse', 'Agent|Task', at)
    # The subagent's own lifecycle: SubagentStart ties the dispatch to its
    # agent_id, SubagentStop takes the row away the moment the agent is done
    # (before, a finished agent stayed listed until the whole turn ended).
    # No matcher: the hook filters out internal agents itself, by an empty
    # agent_type on start and an unknown agent_id on stop.
    ensure('SubagentStart', '', at)
    ensure('SubagentStop', '', at)
    ensure('Stop', '', at)
    if changed:
        save(d)
    if partial:
        # Not "wired": an event the tracker needs is missing, and exit 0
        # would tell a script driving the installer that all is well.
        sys.stderr.write("⚠ Hooks only partly wired: fix the events above and re-run install.sh --with-hooks\n")
        sys.exit(1)
    if changed:
        print("✓ Hooks wired: word counter (🔤) + agent tracker (🤖)")
    else:
        print("• Hooks already wired: word counter (🔤) + agent tracker (🤖)")
PYEOF
}

# Keep only the newest $KEEP_BACKUPS "$1".bak-* files. The glob expands in name
# order and the stamp sorts chronologically, so the oldest come first.
prune_backups() {
  local f n=0
  for f in "$1".bak-*; do [ -e "$f" ] && n=$((n + 1)); done
  for f in "$1".bak-*; do
    [ "$n" -le "$KEEP_BACKUPS" ] && break
    [ -e "$f" ] && rm -f "$f" && n=$((n - 1))
  done
}

mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

# Resolve the install target from settings.json. This also validates the file
# before anything is touched: an unparsable settings.json stops the install
# here, with the script not yet copied either.
WITH_ENV=0; [ -n "$THEME$GLYPHS" ] && WITH_ENV=1
DEST=$(settings_py resolve "$SETTINGS" "$STAMP" "$DEFAULT_DEST" "$WITH_HOOKS" "$WITH_ENV")

mkdir -p "$(dirname "$DEST")"
# The README used to say "edit agentline.sh directly", and every upgrade then
# cp'd over those edits. The replaced copy is kept whenever it differs from
# the new one — local edit or simply an older release, cmp cannot tell — and
# local.sh (see README) is the place for tweaks that survive upgrades.
#
# The configured script may be the very file this installer ships (a wrapper
# that runs the clone in place). `cp` onto itself fails ("are the same file")
# and, under set -e, aborted the install with status 1; there is nothing to
# copy then, so the copy is skipped.
if [ "$DEST" -ef "$SCRIPT_DIR/agentline.sh" ]; then
  echo "• $DEST is this checkout's agentline.sh — already current"
else
  if [ -f "$DEST" ] && ! cmp -s "$SCRIPT_DIR/agentline.sh" "$DEST"; then
    cp -p "$DEST" "$DEST.bak-$STAMP"
    prune_backups "$DEST"
    echo "• Previous copy kept as $DEST.bak-$STAMP (restore local edits from it)"
  fi
  cp "$SCRIPT_DIR/agentline.sh" "$DEST"
  chmod +x "$DEST"
  echo "✓ Installed to $DEST"
fi

# The companions, always, beside the default install: the subagent rows'
# script, agentline-run and the registry helper agentline-run writes
# through. None of them runs until a setting (--with-subagents) or a
# command (agentline-run ...) asks for it, so copying them changes nothing
# on its own. A file that is this checkout's own is not copied onto itself.
AL_HOME="$HOME/.claude/agentline"
mkdir -p "$AL_HOME"
for f in agentline-subagents.sh agentline-run hooks/agentline-agent.sh; do
  to="$AL_HOME/${f##*/}"
  [ "$SCRIPT_DIR/$f" -ef "$to" ] && continue
  cp "$SCRIPT_DIR/$f" "$to"
  chmod +x "$to"
done
echo "✓ Installed agentline-subagents.sh, agentline-run and agentline-agent.sh to $AL_HOME"

# Machine-local service list. Never overwrite an existing one: it holds this
# host's unit names and is deliberately not tracked in git. A pre-rename
# statusline conf is migrated so the host keeps its unit list.
if [ -f "$SVC_CONFIG" ]; then
  echo "• Kept existing $SVC_CONFIG"
elif [ -f "$OLD_SVC_CONFIG" ]; then
  cp "$OLD_SVC_CONFIG" "$SVC_CONFIG"
  echo "✓ Migrated $OLD_SVC_CONFIG -> $SVC_CONFIG"
elif [ -f "$SVC_EXAMPLE" ]; then
  cp "$SVC_EXAMPLE" "$SVC_CONFIG"
  echo "✓ Seeded $SVC_CONFIG — edit it to list this machine's services"
fi

SL_RC=0
settings_py statusline "$SETTINGS" "$STAMP" "$DEST" "$FORCE" || SL_RC=$?
if [ "$SL_RC" = 3 ]; then
  # Another status line is configured and was left alone. The copy on disk is
  # not what Claude Code runs, so do not report success, and do not wire hooks
  # whose only reader is a status line that is not there.
  echo "⚠ agentline is installed to $DEST but NOT active."
  echo "  Re-run with --force, or merge the snippet above into $SETTINGS."
  [ "$WITH_HOOKS" = 1 ] && echo "• Hooks not wired: the configured status line is not agentline."
  [ "$WITH_SUB" = 1 ] && echo "• subagentStatusLine not set: the configured status line is not agentline."
  exit 3
elif [ "$SL_RC" != 0 ]; then
  exit "$SL_RC"
fi

# --- Theme and glyph set -------------------------------------------------------
if [ "$WITH_ENV" = 1 ]; then
  ENV_PAIRS=()
  [ -n "$THEME" ] && ENV_PAIRS[${#ENV_PAIRS[@]}]="AGENTLINE_THEME=$THEME"
  [ -n "$GLYPHS" ] && ENV_PAIRS[${#ENV_PAIRS[@]}]="AGENTLINE_GLYPHS=$GLYPHS"
  settings_py env "$SETTINGS" "$STAMP" "${ENV_PAIRS[@]}"
fi
# COLORFGBG ("15;0": foreground;background as ANSI colour numbers) is set by
# rxvt, iTerm2 and a few others. A background of 7 or 9-15 is a light one.
# It is only a hint, printed and never written: it describes the terminal
# this installer runs in, which need not be the one the status line uses.
if [ -z "$THEME" ] && [ -n "${COLORFGBG-}" ]; then
  case "${COLORFGBG##*;}" in
    7|9|1[0-5]) echo "• Your terminal reports a light background (COLORFGBG=$COLORFGBG): consider bash install.sh --theme light" ;;
  esac
fi

# --- Optional hooks -----------------------------------------------------------
# The 🔤 word-counter (line 1) and 🤖 agent-tracker (line 3) segments read
# files written by two small hooks. They are opt-in because they touch the
# hooks section of settings.json.
if [ "$WITH_HOOKS" = 1 ]; then
  HOOKS_DEST="$HOME/.claude/agentline"
  mkdir -p "$HOOKS_DEST"
  cp "$SCRIPT_DIR/hooks/wordcount-hook.sh" "$HOOKS_DEST/"
  cp "$SCRIPT_DIR/hooks/agent-tracker-hook.sh" "$HOOKS_DEST/"
  # The shared registry both write through, agentline-agent.sh, was copied
  # with the companions above.
  chmod +x "$HOOKS_DEST/wordcount-hook.sh" "$HOOKS_DEST/agent-tracker-hook.sh"
  settings_py hooks "$SETTINGS" "$STAMP" "$HOOKS_DEST"
fi

# --- Subagent status line -----------------------------------------------------
# Opt-in like the hooks: it replaces the rows of Claude Code's own subagent
# panel. A custom agentline-subagents.sh path already configured is upgraded
# in place, as agentline.sh's is.
SUB_RC=0
if [ "$WITH_SUB" = 1 ]; then
  SUB_DEST=$(settings_py subresolve "$SETTINGS" "$STAMP" "$AL_HOME/agentline-subagents.sh")
  if [ "$SUB_DEST" != "$AL_HOME/agentline-subagents.sh" ] && ! [ "$SCRIPT_DIR/agentline-subagents.sh" -ef "$SUB_DEST" ]; then
    cp "$SCRIPT_DIR/agentline-subagents.sh" "$SUB_DEST"
    chmod +x "$SUB_DEST"
    echo "✓ Upgraded $SUB_DEST in place"
  fi
  settings_py subagents "$SETTINGS" "$STAMP" "$SUB_DEST" "$FORCE" || SUB_RC=$?
  [ "$SUB_RC" = 3 ] || [ "$SUB_RC" = 0 ] || exit "$SUB_RC"
fi

# --- agentline-run on PATH ----------------------------------------------------
# A symlink, so an upgrade (which rewrites the copy in $AL_HOME) is picked up
# without re-linking, and the script still finds its helpers beside the
# target. Whatever already sits at that name and is not this link — another
# tool's agentline-run, a copy of ours — is left alone and reported.
if [ "$LINK_BIN" = 1 ]; then
  BIN_DIR="$HOME/.local/bin"
  BIN="$BIN_DIR/agentline-run"
  if [ -L "$BIN" ] && [ "$(readlink "$BIN")" = "$AL_HOME/agentline-run" ]; then
    echo "• $BIN already links to $AL_HOME/agentline-run"
  elif [ -e "$BIN" ] || [ -L "$BIN" ]; then
    echo "⚠ $BIN exists and is not a link to $AL_HOME/agentline-run — left alone"
  else
    mkdir -p "$BIN_DIR"
    ln -s "$AL_HOME/agentline-run" "$BIN"
    echo "✓ Linked $BIN -> $AL_HOME/agentline-run"
  fi
  case ":${PATH-}:" in
    *":$BIN_DIR:"*) ;;
    *) echo "• $BIN_DIR is not on PATH: add it, or run $AL_HOME/agentline-run" ;;
  esac
fi

if [ "$SUB_RC" = 3 ]; then
  echo "⚠ agentline is active, but the subagent rows are NOT: another subagentStatusLine is configured."
  exit 3
fi
echo "Done. Restart Claude Code to see the status bar."
