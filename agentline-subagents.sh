#!/bin/bash
# agentline-subagents — the subagent rows of agentline, for Claude Code's
# `subagentStatusLine` setting.
#
#   "subagentStatusLine": {"type": "command",
#                          "command": "~/.claude/agentline/agentline-subagents.sh"}
#
# Claude Code runs it once per refresh tick while subagents are listed, with
# one JSON object on stdin: the usual hook fields (session_id, the MAIN
# session's transcript_path, cwd, ...), `columns` (the width a row may use) and
# `tasks`, one entry per subagent. For each task it prints one JSON line,
# {"id": <task id>, "content": <row>}, and Claude Code draws that row instead
# of its own. A task it prints nothing for keeps the default row, so every
# case this script does not understand — no python3, a payload that does not
# parse, a task without a usable id — degrades to exactly what Claude Code
# shows without agentline.
#
# A row, most important field first (at a narrow width the last ones go):
#   ⠹ fix the parser │ Haiku 4.5 🟢low │ 📊 12% │ ⏱️ 3m │ → codex/gpt-6-astra ⏳2m │ ▁▂▃▅▇ │ 📂 api
#   status, label, model + effort, context used, elapsed, what the subagent is
#   doing right now (read from the tail of its own transcript), token
#   velocity, and its cwd where that is not the session's.
#
# The "doing right now" part names external workers, not just tools: a Bash
# call running `codex exec -m gpt-6-astra …` shows as codex/gpt-6-astra, an
# `ssh bayrak claude -p --model opus …` as bayrak/opus, a curl to the local
# model server as arb/qwen3.6. The same classifier labels agentline-run's
# rows on the main line, through the second mode:
#
#   agentline-subagents.sh --classify [--label TEXT] -- CMD [ARGS...]
#                           print the worker label for that command line
#                           (codex/gpt-6-astra, ...), or its program name;
#                           TEXT instead when it looks like no secret
#
# Honours AGENTLINE_THEME (dark|light|mono), NO_COLOR, AGENTLINE_GLYPHS
# (emoji|ascii) and the AGENTLINE_COLOR_* overrides, like agentline.sh.
#
# Everything runs in ONE python3 per tick, for every task at once: python3 is
# the one interpreter that parses JSON on both platforms without a
# dependency, and a process per task would be a dozen interpreter starts a
# second. The program is embedded here, at the top level of the script
# rather than inside $(...), where bash 3.2 does not treat heredoc lines as
# comments; `-I` keeps it from importing a json.py or re.py that happens to
# sit in the project directory Claude Code runs it in.
IFS= read -r -d '' _AL_SUB_PY <<'PYEOF'
import functools, json, os, re, stat, sys, time

MODE = sys.argv[1] if len(sys.argv) > 1 else 'render'

# === Worker classifier ===
# Maps a shell command to the external AI worker it runs, as a short label
# such as codex/gpt-6-astra. Shared by the subagent rows (a Bash tool call
# read from a transcript) and agentline-run (its own argv), so the table
# lives in this one place.
#
# Nothing it returns is raw command text. A command line can hold a prompt,
# a token, a file body or a URL with a query string, and it is written by a
# model; the label is built only from fixed names, from program names that
# pass safe(), and from model names that also have the shape of a model of
# that worker (MODEL). A token that only looked harmless was not enough:
# codex/sk-ant-api03-…, agy/hf_…, ssh/10.1.2.3 and codex//home/…/patients
# all passed the old character check. So the worst a hostile command can do
# is choose which of these short, inert strings appears.
#
# And it fails closed (review of J9b, stage J9c). A program is named only
# when it is on a fixed list (PROGRAMS) or is a script basename of the SCRIPT
# shape: `PASSWORD=$(true)hunter2 sleep 1`, cut apart by a lexer that did not
# model $(, showed `Bash hunter2`, and a name merely shaped like a program is
# no proof it is one. What the lexer does not parse exactly ($'…', $(, a
# heredoc whose delimiter it cannot pin down, ...) ends the walk: only the
# words before it count, and from those only a worker is named. A launcher
# (env, sudo, timeout, exec, ...) is taken off by its own option syntax, so
# `exec -a hunter2 sleep 60` is sleep and not hunter2; a form of it this does
# not know names the launcher, never the word after it.
SAFE = re.compile(r'[A-Za-z0-9._-]{1,40}')
# Never shown, whatever else a token passes: the prefixes of the common API
# keys and tokens (OpenAI/Anthropic, Stripe, GitHub, GitLab, Slack, AWS, JWT,
# Hugging Face, NVIDIA, Google, npm, PyPI), and anything path-like.
DENY = re.compile(r'sk-|sk_|rk_|gh[pousr]_|github_pat_|glpat-|xox[a-z]-|akia|asia|eyj|hf_'
                  r'|nvapi-|aiza|ya29\.|npm_|pypi-|\.\.|//|^[/~]', re.I)
# The model names a worker's label may carry, by shape. Anything else — a
# typo, a path, a secret in the model's place — leaves the worker unnamed
# (plain "codex"), which is still right about what runs.
MODEL = {
    'codex': re.compile(r'(?:gpt|o[0-9]|codex)[A-Za-z0-9._-]{0,30}', re.I),
    'agy': re.compile(r'(?:gemini|claude|gpt-oss)[A-Za-z0-9._-]{0,40}', re.I),
    'claude': re.compile(r'opus|sonnet|haiku|fable|mythos|opusplan|claude-[a-z0-9.-]{1,40}', re.I),
    'hetzner': re.compile(r'qwen[0-9][a-z0-9._-]{0,30}'),
}
ASSIGN = re.compile(r'[A-Za-z_][A-Za-z0-9_]*=')
MODEL_JSON = re.compile(r'"model"\s*:\s*"([^"\\]{1,80})"')
# Commands that set the stage and are never the thing a row should name.
TRIVIAL = {'cd', 'pushd', 'popd', 'export', 'set', 'unset', 'source', '.', 'echo',
           'printf', 'true', 'false', ':', 'sleep', 'test', '[', '[[', 'local',
           'read', 'wait', 'trap', 'mkdir', 'shift', 'then', 'do', 'done', 'fi',
           'else', 'elif', 'if', 'for', 'while', 'until', 'case', 'esac', '{', '}', '!'}
INTERP = {'python', 'python3', 'node', 'bun', 'deno', 'ruby', 'perl', 'bash', 'sh', 'zsh'}
SHELLS = {'bash', 'sh', 'zsh', 'dash', 'ksh'}
# The only program names a row shows: common tools, whose name says nothing
# about the work, and the interpreters and shells. Anything else is plain
# "Bash".
PROGRAMS = INTERP | SHELLS | set('''
git gh glab pip pip3 pipx uv uvx poetry pytest tox ruff mypy black
npm npx pnpm yarn tsc jest vitest eslint prettier
make cmake ninja cargo rustc go java javac mvn gradle gem bundle rake php
composer dotnet swift xcodebuild flutter dart docker podman kubectl helm terraform
ansible ansible-playbook curl wget ssh scp sftp rsync jq yq rg grep egrep fgrep sed
awk gawk ls cat head tail less wc sort uniq cut tr find fd xargs tar zip unzip gzip
gunzip cp mv rm ln chmod chown touch du df ps kill pkill pgrep lsof diff patch tee
fish timeout env sudo nohup nice time watch tmux screen sleep
systemctl journalctl brew apt apt-get dnf yum nvidia-smi uptime ping dig nc openssl
sqlite3 psql mysql redis-cli ffmpeg codex agy claude
'''.split())
# A script shown by its basename: a short plain name with a script suffix.
SCRIPT = re.compile(r'[A-Za-z0-9._-]{1,32}\.(?:py|sh|js|ts|rb)')
SSH_ARG = set('BbcDEeFIiJLlmOoPpQRSWw')  # ssh options that take a value
LOCAL = r'(?:127\.0\.0\.1|localhost):'

# === The secret heuristic (review of J9c, stage J9d) ===
# ONE test for everything the row, the registry or a diagnostic may show
# that is not a fixed word of this script's: a worker's model, a program or
# script name, a tool name, a subagent type, an MCP server, a label. Claude
# Code already shows its own subagent descriptions, tools and commands; what
# this script must never do is add a secret to them. So a value that merely
# looks like one is not shown at all: the caller puts its generic word
# (Bash, agent, mcp, run) in its place, never a part of the value. It is a
# heuristic, and it errs towards refusing — `fix token refresh` is shown as
# "agent" — because a status line that shows less is still right.
#
# Secret-shaped: a key prefix at the start of a word (sk-, ghp_, AKIA…, a
# JWT's eyJ…); a word of credential vocabulary (Bearer, Basic, token,
# secret, passw…, apikey); an = or : followed by 8 or more characters; a
# run of 24 or more of [A-Za-z0-9_-] (a UUID, a base64 key); or a word of
# 16 or more characters that mixes letters and digits (hunter2xyzabc1234567)
# — unless it is made of pieces a version-numbered name has: the -._/
# separated parts of gpt-5.1-codex-max, claude-sonnet-4-5 or qwen3-coder
# are each all letters, all digits, or at most five characters.
#
# The same definition sits in hooks/agentline-agent.sh and
# hooks/agent-tracker-hook.sh (separate programs, no shared import); the
# test suite checks that the three copies are identical.
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

def shown(s, generic=''):
    """s when it passes the secret heuristic, else the generic word."""
    return s if s and not secretish(s) else generic

def safe(tok):
    return tok if isinstance(tok, str) and SAFE.fullmatch(tok) and not DENY.search(tok) \
        and not secretish(tok) else ''

def base(w):
    return w.rsplit('/', 1)[-1]

# The shell lexer below walks a command one token at a time with a single
# regex, so a long command is consumed in C-sized chunks, not by a Python
# loop per character. shlex, which this replaced, lexed the whole string —
# a 60 KB heredoc was 69 ms per task and tick, and every ssh or bash -c
# level lexed its part again — and it knew nothing of heredocs, so the
# first word of every body line became a "program" on the row (a name, a
# figure, a line of a file being written).
LEX = re.compile(r'''
    (?P<ws>[^\S\n]+)
  | (?P<nl>\n)
  | (?P<op>&&|\|\||;;&?|;&|<<<|<<-|<<|>>|>&|<&|&>>?|>\||<>|[;&|()<>`])
  | (?P<sub>\$\()
  | (?P<sq>'[^']*'?)
  | (?P<ansi>\$'[^'\\]*(?:\\.[^'\\]*)*'?)
  | (?P<dq>"[^"\\]*(?:\\.[^"\\]*)*"?)
  | (?P<esc>\\.?)
  | (?P<hash>\#)
  | (?P<lit>[^\s'"\\;&|()<>`#$]+|\$)
''', re.X | re.S)
REDIR = {'<', '>', '>>', '>&', '<&', '&>', '&>>', '>|', '<>', '<<<'}
# In double quotes a backslash escapes these; before a newline it is a line
# continuation, and both go.
DQ_ESC = re.compile(r'\\([$`"\\\n])')
def dq_unescape(m):
    return '' if m.group(1) == '\n' else m.group(1)
# The one ${...} the lexer follows exactly: a plain name or special
# parameter, then the brace. Any other (${X:-a;b}, ${X/;/}, ${X#\}}, ...)
# holds text whose end only a full parser knows — bash reads its ; as part
# of the word, a lexer that stops at the ; as a separator — and ends the walk.
PARAM = re.compile(r'\{(?:[A-Za-z_][A-Za-z0-9_]*|[0-9]+|[#?$!@*-])\}')
# What a double-quoted word may not hold: a substitution with quoting of its
# own ("$(echo "; x; ")" is one word) or a ${ this does not follow.
DQ_SUB = re.compile(r'\$\(|`|\$\{(?![A-Za-z_][A-Za-z0-9_]*\}|[0-9]+\}|[#?$!@*-]\})')
# Bounds on the work one command may cost, whatever its size: this many
# characters of it are lexed (heredoc bodies, skipped by a search, do not
# count), into at most this many tokens, and a command inside a command
# (bash -c, ssh, agentline-run) is followed this many levels deep. A worker
# is named in the first few words of a command, never 4 KB into it.
LEX_CHARS, LEX_TOKENS, MAX_DEPTH = 4096, 256, 2

def heredoc_end(s, pos, delim, dash, quoted):
    """Where the heredoc body starting at pos ends: past its delimiter line,
    or the end of s when the delimiter never comes (bash reads to EOF) —
    or None when that cannot be told. With an unquoted delimiter a body line
    ending in a backslash is joined to the next (x\\ then EOF is the line
    xEOF, no delimiter), so the first line that reads EOF may not end the
    body; rather than model the joins, such a body ends the walk."""
    m = re.compile('^' + ('\t*' if dash else '') + re.escape(delim) + '$', re.M).search(s, pos)
    stop = m.start() if m else len(s)
    if not quoted and s.find('\\\n', pos, stop) >= 0:
        return None
    if not m:
        return len(s)
    return m.end() + 1 if s.startswith('\n', m.end()) else m.end()

DQ_END = re.compile(r'"(?:[^"\\]|\\.)*"', re.S)
# Launchers a command can start with before `eval` (A=1 eval ..., sudo eval).
EVAL_LEAD = {'env', 'sudo', 'doas', 'command', 'builtin', 'exec', 'nohup', 'time', 'nice'}

@functools.lru_cache(maxsize=64)
def split_cmds(s):
    """(commands, exact): the simple commands of a shell string, each a
    tuple of words, and whether it was all understood. Newlines, ; && || |
    &, parentheses separate; a redirection and its target are dropped, and
    so is a comment. A heredoc's body is skipped up to its delimiter line
    (<< and <<-, quoted or not, several on one line), and quoted text stays
    one word: neither is ever read as a command.

    It fails closed. At the first construct it does not model exactly —
    $'…' or $"…" quoting, $( or a backquote (bare or in double quotes), a
    ${…} other than ${NAME}, <( or >(, a here-string, eval, an unterminated
    quote, a heredoc delimiter that is quoted with $ or \\ in it or missing,
    an unquoted heredoc with a body line ending in a backslash — the walk
    stops, exact is False, and what comes back is
    what came before it: the commands already complete and the whole words
    of the one in progress (the word being built is dropped: the PASSWORD=
    of PASSWORD=$(true)hunter2). Past the lexing budget the command that was
    cut is dropped too; the rest is not looked at, which is no uncertainty:
    a worker is named in the first few words."""
    cmds, cur, buf = [], [], []
    have = False              # a word is being built ('' is a word too)
    target = heredoc = None   # what the next word is: a redirection target,
    pending = []              # a heredoc delimiter (<<, <<-); bodies to skip
    pos = used = ntok = 0
    n = len(s)
    exact = True

    hquoted = False           # the delimiter being read has quoting in it

    def flush():
        nonlocal have, target, heredoc, exact
        if not have:
            return
        word, have = ''.join(buf), False
        del buf[:]
        if heredoc is not None:
            pending.append((word, heredoc, hquoted))
            heredoc = None
        elif target:
            target = None
        elif word.strip():
            if word == 'eval' and all(ASSIGN.match(x) or x.startswith('-') or base(x) in EVAL_LEAD
                                      for x in cur):
                exact = False
                return
            cur.append(word)

    def end():
        nonlocal cur
        flush()
        if cur:
            cmds.append(tuple(cur))
            cur = []

    while exact and pos < n and used < LEX_CHARS and ntok < LEX_TOKENS:
        # endpos: a quoted word of 100 KB is matched only as far as the
        # budget reaches, and the budget then ends the walk.
        m = LEX.match(s, pos, min(n, pos + LEX_CHARS - used))
        if not m:  # cannot happen: every character starts some token
            break
        kind, tok = m.lastgroup, m.group()
        used += len(tok)
        pos = m.end()
        if tok == '\\\n':
            # A line continuation: bash removes it, and the word goes on —
            # PASSWORD=\<newline>x.py is one word, an assignment, not a
            # PASSWORD= and a program x.py. Nothing starts or ends here.
            continue
        if tok == '$' and s.startswith('{', pos):
            p = PARAM.match(s, pos)
            if not p:
                exact = False  # a ${...} whose end this cannot pin down
                break
            tok, pos = tok + p.group(), p.end()
            used += len(p.group())
        if kind == 'ansi' or kind == 'sub' or tok in ('`', '<<<') \
                or (tok in ('<', '>') and s.startswith('(', pos)) \
                or (tok == '$' and s.startswith('"', pos)) \
                or (kind == 'sq' and (len(tok) < 2 or not tok.endswith("'"))) \
                or (kind == 'dq' and (not DQ_END.fullmatch(tok) or DQ_SUB.search(tok))):
            exact = False
            break
        if heredoc is not None and not have and kind in ('op', 'nl'):
            exact = False  # << with no delimiter word
            break
        if heredoc is not None and ('$' in tok or '`' in tok or (kind == 'dq' and '\\' in tok)):
            exact = False  # a delimiter this would have to expand
            break
        if heredoc is not None and kind in ('sq', 'dq', 'esc'):
            hquoted = True
        if kind == 'ws':
            flush()
        elif kind == 'nl':
            end()
            ntok += 1
            for delim, dash, quoted in pending:
                pos = heredoc_end(s, pos, delim, dash, quoted)
                if pos is None:
                    exact = False  # a body whose end cannot be told
                    break
            del pending[:]
            if not exact:
                break
        elif kind == 'op':
            ntok += 1
            if tok in REDIR or tok in ('<<', '<<-'):
                if have and not target and heredoc is None and ''.join(buf).isdigit():
                    del buf[:]  # the 2 of 2>&1
                    have = False
                flush()
                if tok in ('<<', '<<-'):
                    heredoc, hquoted = tok == '<<-', False
                else:
                    target = True
            else:
                end()
        elif kind == 'hash' and not have:
            nl = s.find('\n', pos)  # a comment, up to the line's end
            pos = n if nl < 0 else nl
        else:
            if not have:
                ntok += 1
            have = True
            if kind == 'sq':
                buf.append(tok[1:-1])
            elif kind == 'dq':
                buf.append(DQ_ESC.sub(dq_unescape, tok[1:-1]))
            elif kind == 'esc':
                buf.append(tok[1:])
            else:
                buf.append(tok)
    if exact and pos >= n and heredoc is not None and not have:
        exact = False  # << at the very end
    if exact and pos >= n:
        end()
    elif cur:
        # Stopped early: the word being built is not whole. Past the budget
        # the command is not whole either; before an unknown construct its
        # whole words are exact.
        if not exact:
            cmds.append(tuple(cur))
    return tuple(cmds), exact

def opt_val(w, names):
    """The value of the first -m X / --model X / --model=X in w."""
    for i, t in enumerate(w):
        for n in names:
            if t == n and i + 1 < len(w):
                return w[i + 1]
            if n.startswith('--') and t.startswith(n + '='):
                return t[len(n) + 1:]
    return ''

def body_model(w):
    """A "model": "..." in a request body passed as an argument (curl -d)."""
    for t in w:
        m = MODEL_JSON.search(t)
        if m:
            return m.group(1)
    return ''

def with_model(name, model, tail=False):
    """name/model when model is safe and has the shape of one of name's
    models (MODEL), else the bare name."""
    if tail:
        model = model.rsplit('/', 1)[-1].lower()
    if not (safe(model) and MODEL[name].fullmatch(model)):
        return name
    return name + '/' + model if len(name) + 1 + len(model) <= 40 else name

# The launchers unwrap() takes off, each by its own option syntax: (short
# options that take a value, short flags, long options that take a value,
# long flags). An option not listed here — `sudo -e`, `env -S`, `command -v`,
# `ionice -p`, or one this simply does not know — means the form is not
# understood, and the launcher is all that is left of the command: an
# option's value is never taken for the program (exec -a NAME, time -f FMT,
# sudo -u USER, xargs -I STR, all were). GNU and BSD spellings are merged;
# a value both might take is taken.
WRAP = {
    'env': ('uC', 'i0v', {'unset', 'chdir'}, {'ignore-environment', 'null', 'debug'}),
    'timeout': ('sk', 'v', {'signal', 'kill-after'}, {'foreground', 'preserve-status', 'verbose'}),
    'nohup': ('', '', set(), set()),
    'time': ('fo', 'apvqlh', {'format', 'output'}, {'append', 'portability', 'verbose', 'quiet'}),
    'exec': ('a', 'cl', set(), set()),
    'command': ('', 'p', set(), set()),
    'nice': ('n', '0123456789', {'adjustment'}, set()),
    'ionice': ('cn', 't', {'class', 'classdata'}, {'ignore'}),
    'stdbuf': ('ioe', '', {'input', 'output', 'error'}, set()),
    'sudo': ('ugpCDrtUTR', 'AbEHnPSsikB',
             {'user', 'group', 'prompt', 'close-from', 'chdir', 'role', 'type', 'other-user',
              'command-timeout', 'chroot'},
             {'askpass', 'background', 'preserve-env', 'set-home', 'non-interactive',
              'preserve-groups', 'stdin', 'shell', 'login', 'reset-timestamp', 'bell'}),
    'doas': ('u', 'ns', set(), set()),
    'xargs': ('InLPsdEa', '0rtpxoie',
              {'max-args', 'max-lines', 'max-procs', 'max-chars', 'delimiter', 'eof', 'arg-file',
               'process-slot-var'},
              {'null', 'no-run-if-empty', 'verbose', 'interactive', 'exit', 'open-tty', 'replace'}),
    'caffeinate': ('tw', 'dimsu', set(), set()),
    # Its --label is not shown from here (A1 of J9c): a command line is the
    # model's text, so the row names what the run wraps.
    'agentline-run': ('', '', {'label', 'heartbeat'}, set()),
}
WRAP['gtimeout'] = WRAP['timeout']
DURATION = re.compile(r'(?:[0-9]+\.?[0-9]*|\.[0-9]+)[smhd]?')

def skip_opts(w, spec):
    """The index of the first word after the options of w[0], by spec
    (WRAP), or None for an option spec does not have."""
    sv, sf, lv, lf = spec
    i = 1
    while i < len(w):
        t = w[i]
        if t == '--':
            return i + 1
        if t.startswith('--'):
            name, eq, _ = t[2:].partition('=')
            if name in lv:
                i += 1 if eq else 2
            elif name in lf:
                i += 1
            else:
                return None
            continue
        if not t.startswith('-') or t == '-':
            return i if t != '-' or w[0] != 'env' else i + 1  # env - is env -i
        for j, c in enumerate(t[1:], 1):
            if c in sv:
                if j + 1 == len(t):
                    i += 1  # the value is the next word
                break
            if c not in sf:
                return None
        i += 1
    return i

def unwrap(w):
    """Strip launchers off the front of w (VAR=x and WRAP): what they start
    is what counts. A launcher form not understood leaves the launcher
    alone. Bounded, so a pathological chain cannot spin."""
    for _ in range(8):
        if not w:
            break
        if ASSIGN.match(w[0]):
            w = w[1:]
            continue
        p = base(w[0])
        spec = WRAP.get(p)
        if spec is None:
            break
        i = skip_opts([p] + list(w[1:]), spec)
        if i is None:
            return w[:1]
        if p in ('env', 'sudo'):
            while i < len(w) and ASSIGN.match(w[i]):
                i += 1
        elif p in ('timeout', 'gtimeout'):
            if i < len(w) and not DURATION.fullmatch(w[i]):
                return w[:1]
            i += 1  # past the duration
        w = w[i:]
    return w

def classify_words(w, depth=0):
    """The worker label of one simple command, or ''."""
    w = unwrap(w)
    if not w or depth > MAX_DEPTH:
        return ''
    p = base(w[0])
    if p in SHELLS:
        # bash -c 'codex exec ...': the string is the command.
        i = 1
        while i < len(w):
            t = w[i]
            if t in ('-o', '+o'):
                i += 2
                continue
            if t.startswith('-') and not t.startswith('--') and 'c' in t[1:]:
                return classify_string(w[i + 1], depth + 1) if i + 1 < len(w) else ''
            if not t.startswith('-'):
                break
            i += 1
        return ''
    if p == 'codex':
        m = opt_val(w, ('-m', '--model'))
        if not m:
            c = opt_val(w, ('-c', '--config'))
            if c.startswith('model='):
                m = c[6:].strip('"\'')
        return with_model('codex', m)
    if p == 'agy':
        return with_model('agy', opt_val(w, ('--model', '-m')))
    if p == 'claude':
        return with_model('claude', opt_val(w, ('--model',)))
    if p == 'ssh':
        return classify_ssh(w, depth)
    # Markers anywhere in the command: an endpoint, a model name in a request
    # body, a helper script. Checked in this order, so arbctl.py is the
    # controller and not the server it talks to.
    if any(base(t) == 'arbctl.py' for t in w):
        return 'arb/ctl'
    if any(base(t) == 'run_jev.py' or 'jev_eval' in t or re.search(LOCAL + r'18081\b', t) for t in w):
        return 'jev/jevk5'
    if any(re.search(LOCAL + r'18080\b', t) or t == 'arb-coder'
           or re.search(r'"model"\s*:\s*"arb-coder"', t) for t in w):
        return 'arb/qwen3.6'
    hz = os.environ.get('HETZNER_INFERENCE_BASE_URL', '')
    hz = re.sub(r'^[A-Za-z]+://', '', hz).split('/', 1)[0] if hz else ''
    # An HTTP worker's model is taken from the request body alone: an option
    # of curl's is no model name (-m is curl's --max-time: "hetzner/30").
    if any('inference.hetzner.com' in t or 'HETZNER_INFERENCE_BASE_URL' in t
           or (hz and hz in t) for t in w):
        return with_model('hetzner', body_model(w), tail=True)
    if any('integrate.api.nvidia.com' in t or base(t) == 'review-deepseek.py' for t in w):
        return 'deepseek'
    return ''

def classify_ssh(w, depth):
    """ssh [opts] host [cmd...]: the bayrak node by its alias, with the model
    of a `claude -p --model M` it runs; another host by the worker its
    remote command runs, else plain "ssh". Never another host's name or
    address: antlara-prod-db.internal or 10.1.2.3 say where a client's data
    lives."""
    i = 1
    while i < len(w):
        t = w[i]
        if t == '--':
            i += 1
            break
        if not (t.startswith('-') and len(t) > 1):
            break
        for j, c in enumerate(t[1:], 1):
            if c in SSH_ARG:
                if not t[j + 1:]:
                    i += 1  # the value is the next word
                break
        i += 1
    if i >= len(w):
        return ''
    host = w[i].rsplit('@', 1)[-1]
    remote = ' '.join(w[i + 1:])
    inner = classify_string(remote, depth + 1) if remote else ''
    if host in ('bayrak', 'bayrak-vcn'):
        return 'bayrak/' + inner[7:] if inner.startswith('claude/') else 'bayrak'
    return inner or 'ssh'

def classify_string(s, depth=0):
    # Also when split_cmds was not sure: what it returns then is only what
    # came before the construct it stopped at.
    if depth > MAX_DEPTH:
        return ''
    for w in split_cmds(s)[0][:32]:
        lab = classify_words(w, depth)
        if lab:
            return lab
    return ''

def script_name(t):
    t = base(t)
    return t if SCRIPT.fullmatch(t) and safe(t) else ''

# The options of the interpreters whose script a row names, by their own
# syntax (review of J9c, stage J9d): (short options that take a value, short
# flags, short options whose value is the program text, long options that
# take a value, long ones whose value is the program text). Skipping every
# -word showed `python3 -X hunter2.py real.py` as hunter2.py, the value of
# -X. An option not listed here ends the look: the row names the
# interpreter only. An interpreter with no entry is named alone whenever an
# option follows it.
_SH_OPTS = ('o', 'abefhknptuvxBCEHPT', 'c', set(), set())
IOPTS = {
    'python': ('XW', 'bBdEhiIOPqsSuvVxR', 'cm', {'check-hash-based-pycs'}, set()),
    'node': ('r', '', 'ep', {'require'}, {'eval', 'print'}),
}
IOPTS['python3'] = IOPTS['python']
for _s in SHELLS:
    IOPTS[_s] = _SH_OPTS

def interp_script(w, p, depth):
    """What interpreter p, run as w, shows beside its own name: the script
    it runs, the program of a shell's -c, else just p."""
    spec = IOPTS.get(p)
    sv, sf, se, lv, le = spec or ('', '', '', set(), set())
    i = 1
    while i < len(w):
        t = w[i]
        if t == '--':
            i += 1
            break
        if t == '-' or not (t.startswith('-') or (spec is _SH_OPTS and t == '+o')):
            break
        if spec is None:
            return p
        if t in ('-o', '+o') and spec is _SH_OPTS:
            i += 2
            continue
        if t.startswith('--'):
            name, eq, _ = t[2:].partition('=')
            if name in lv:
                i += 1 if eq else 2
                continue
            return p  # a program text (--eval), or an option this does not know
        for j, c in enumerate(t[1:], 1):
            if c in se:
                # The program is text, not a script: a shell's is followed
                # (bash -c '...'), any other interpreter's is not shown.
                if spec is _SH_OPTS and all(x in sf for x in t[j + 1:]) and i + 1 < len(w):
                    return program_string(w[i + 1], depth + 1) or p
                return p
            if c in sv:
                if j + 1 == len(t):
                    i += 1  # the value is the next word
                break
            if c not in sf:
                return p
        i += 1
    if i < len(w) and SCRIPT.fullmatch(base(w[i])):
        return script_name(w[i]) or p
    return p

def program_words(w, depth=0):
    """A program name for a command that is no known worker: its basename
    when that is on PROGRAMS, or the script it is or an interpreter runs
    (x.py, for a python running x.py), else ''."""
    w = unwrap(w)
    if not w:
        return ''
    p = base(w[0])
    if p in TRIVIAL:
        return ''
    if p in INTERP or p in SHELLS:
        return interp_script(w, p, depth)
    return p if p in PROGRAMS else script_name(p)

def program_string(s, depth=0):
    # A program name is shown from an exact parse only.
    if depth > MAX_DEPTH:
        return ''
    cmds, exact = split_cmds(s)
    if not exact:
        return ''
    for w in cmds[:32]:
        p = program_words(w, depth)
        if p:
            return p
    return ''

# === Display sanitisation ===
# The same rule as agentline.sh's _clean: no C0, DEL, C1 or backslash. Here
# the text is decoded, so C1 is its code points, whatever the locale. Bidi
# overrides go too: they can reorder what follows on the row. Descriptions,
# labels and every transcript field are model-controlled.
CTRL = re.compile('[\x00-\x1f\x7f-\x9f\\\\‎‏‪-‮⁦-⁩]')

def clean(s):
    if not isinstance(s, str):
        return ''
    return CTRL.sub('', re.sub(r'[\t\n\r]', ' ', s))

def label_text(s, n=40):
    return re.sub(r' +', ' ', clean(s)).strip()[:n]

# What a --label given to agentline-run may not carry. That label is the
# caller's own words (a script, an orchestrator — not the model: a label
# read from a transcript is never shown), and it is displayed, on a line
# anyone looking at the screen reads. So a label that looks like it holds a
# secret is not shown at all, and the run is named as if it had none: a key
# prefix, a key=value of a credential, a JWT or AWS key id, a long run of
# letters and digits (a token, base64), a path, a URL, an address, an IP.
LABEL_DENY = re.compile(
    r'(?:^|[^a-z0-9])(?:sk-|sk_|rk_|gh[pousr]_|github_pat_|glpat-|xox[a-z]-|hf_|nvapi-|aiza|ya29\.'
    r'|npm_|pypi-)'
    r'|(?:akia|asia)[a-z0-9]{12}|eyj[a-z0-9_-]{8}'
    r'|(?:pass|pwd|secret|token|api[_-]?key|apikey|auth|cred|bearer|cookie|session|private)'
    r'[a-z0-9_-]*\s*[=:]'
    r'|(?=[a-z0-9+/_=]*[0-9])(?=[a-z0-9+/_=]*[a-z])[a-z0-9+/_=]{20}'
    r'|(?:^|\s)[/~]|\.\.|//|@|\b[0-9]{1,3}(?:\.[0-9]{1,3}){3}\b', re.I)

def run_label(s):
    # Both: LABEL_DENY for what a label must not name (a path, a host), the
    # secret heuristic for what it must not hold. `Bearer abc…xyz` passed
    # the first alone (no = or :, no digit in the long word).
    s = label_text(s)
    return s if s and not LABEL_DENY.search(s) and not secretish(s) else ''

if MODE == 'classify':
    # classify LABEL CMD...: LABEL is agentline-run's --label ('' for none).
    argv = sys.argv[3:]
    lab = run_label(sys.argv[2]) if len(sys.argv) > 2 else ''
    if not lab and argv:
        # A command the row is only about (sleep, in a job's wrapper) is
        # still that run's name when it is on PROGRAMS.
        p = base(argv[0])
        lab = classify_words(argv) or program_words(argv) or (p if p in PROGRAMS else '')
    lab = shown(lab)  # agentline-run shows "run" for nothing
    if lab:
        sys.stdout.write(lab + '\n')
    sys.exit(0)

# === Rendering ===
import unicodedata

env = os.environ
THEME = env.get('AGENTLINE_THEME', '')
THEME = THEME if THEME in ('light', 'mono') else 'dark'
if env.get('NO_COLOR'):
    THEME = 'mono'
ASCII = env.get('AGENTLINE_GLYPHS') == 'ascii'
MONO = THEME == 'mono'
# AGENTLINE_NOW pins the clock, as for agentline.sh (the test suite).
NOW = float(env['AGENTLINE_NOW']) if env.get('AGENTLINE_NOW', '').isdigit() else time.time()

def rgb_val(v):
    m = re.fullmatch(r'(\d{1,3}),(\d{1,3}),(\d{1,3})', v or '')
    if not m or any(int(x) > 255 for x in m.groups()):
        return None
    return tuple(int(x) for x in m.groups())

# The palette of agentline.sh: ANSI-16 roles the terminal theme maps, and
# the few fixed colours the light theme darkens.
def sgr(code):
    return '' if MONO else '\033[%sm' % code
RESET, DIM = sgr('0'), sgr('2')
GREEN, CYAN, YELLOW, RED, MAGENTA = sgr('1;32'), sgr('1;36'), sgr('1;33'), sgr('1;31'), sgr('1;35')
ORANGE = sgr('1;38;5;208')
FABLE = [(255, 215, 90), (255, 125, 25)]
if THEME == 'light':
    ORANGE = sgr('1;38;5;166')
    FABLE = [(180, 110, 0), (190, 70, 0)]
for key, idx in (('AGENTLINE_COLOR_FABLE_FROM', 0), ('AGENTLINE_COLOR_FABLE_TO', 1)):
    v = rgb_val(env.get(key))
    if v:
        FABLE[idx] = v
v = rgb_val(env.get('AGENTLINE_COLOR_ORANGE'))
if v:
    ORANGE = sgr('1;38;2;%d;%d;%d' % v)

# Worker colours: an external worker on a row is drawn in the hue of its own
# brand, not bold, the same as on agentline.sh's agent list. The key is the
# worker label's first word (codex/gpt-6-astra -> codex); '*' is anything
# else, a neutral grey. "r;g;b" for the dark theme, then for light (at least
# 4.5:1 on white). The same table sits in agentline.sh (_worker_rgb), and
# tests/run.sh checks that the two agree.
# (worker colours)
WORKER_RGB = {
    'claude': ('217;119;87', '176;78;44'),
    'codex': ('169;112;255', '123;63;228'),
    'agy': ('66;133;244', '26;99;214'),
    'antigravity': ('66;133;244', '26;99;214'),
    'gemini': ('66;133;244', '26;99;214'),
    'nvidia': ('118;185;0', '78;122;0'),
    'nim': ('118;185;0', '78;122;0'),
    'deepseek': ('118;185;0', '78;122;0'),
    'hetzner': ('213;12;45', '192;10;40'),
    'arb': ('43;181;168', '15;118;110'),
    'jev': ('240;107;168', '191;47;110'),
    'jevk5': ('240;107;168', '191;47;110'),
    'bayrak': ('168;168;168', '102;102;102'),
    'ssh': ('168;168;168', '102;102;102'),
    '*': ('168;168;168', '102;102;102'),
}
# (end of worker colours)

def worker_colour(label):
    word = re.split(r'[/ ]', label, maxsplit=1)[0]
    dark, light = WORKER_RGB.get(word, WORKER_RGB['*'])
    return sgr('38;2;' + (light if THEME == 'light' else dark))

if ASCII:
    G = dict(sep='|', spin='.oOo', done='ok', fail='x', stop='-', wait='o', other='?',
             low='', med='', high='', xhigh='', effort='effort:', fable='* ', ctx='ctx:',
             warn='!', dur='dur:', act='-> ', tool='', cwd='cwd:', ell='...',
             spark='_.-~=+*#')
else:
    G = dict(sep='│', spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏', done='✓', fail='✗', stop='⊘', wait='○', other='•',
             low='🟢', med='🟡', high='🟠', xhigh='🔴', effort='⚙️ ', fable='✦ ', ctx='📊 ',
             warn='⚠️ ', dur='⏱️ ', act='→ ', tool='⏳', cwd='📂 ', ell='…',
             spark='▁▂▃▄▅▆▇█')
SEP = ' %s%s%s ' % (DIM, G['sep'], RESET)

ANSI = re.compile(r'\x1b\[[0-9;]*m')

def vis(s):
    """Terminal cells of s, measured as agentline.sh's layout pass does: an
    emoji + U+FE0F is two cells, other marks and format characters none."""
    n = prev = 0
    for c in ANSI.sub('', s):
        if c == '️':
            n, prev = n + 2 - prev, 2
        elif unicodedata.category(c) in ('Mn', 'Me', 'Cf'):
            continue
        else:
            prev = 2 if unicodedata.east_asian_width(c) in ('W', 'F') else 1
            n += prev
    return n

def cut(s, cells):
    """Plain s shortened to at most `cells` cells, with an ellipsis."""
    if vis(s) <= cells:
        return s
    ell = G['ell']
    room = cells - vis(ell)
    if room <= 0:
        return ''
    out = ''
    for c in s:
        if vis(out + c) > room:
            break
        out += c
    out = out.rstrip()
    return out + ell if out else ''

def fmt_dur(sec):
    sec = max(int(sec), 0)
    if sec < 60:
        return '%ds' % sec
    if sec < 3600:
        return '%dm' % (sec // 60)
    return '%dh%02dm' % (sec // 3600, sec % 3600 // 60)

def fmt_tokens(n):
    if n >= 1000000:
        return '%.1fm' % (n / 1000000.0)
    if n >= 1000:
        return '%dk' % round(n / 1000.0)
    return '%d' % n

def num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None

# --- model -----------------------------------------------------------------
FAMILY = {'opus': 'Opus', 'sonnet': 'Sonnet', 'haiku': 'Haiku', 'fable': 'Fable', 'mythos': 'Mythos'}

def model_short(mid):
    """claude-haiku-4-5-20251001 -> ("Haiku 4.5", "haiku"). The task payload
    carries the resolved id only, not line 1's display name. An id this does
    not know is shown as its own safe token, or not at all."""
    m = mid.strip().lower().split('[', 1)[0]
    m = re.sub(r'^(?:[a-z]{2,4}\.)?anthropic\.', '', m)       # Bedrock
    m = re.sub(r'(?:@\d{8}|-v\d+(?::\d+)?)$', '', m)            # Vertex, Bedrock
    r = re.fullmatch(r'claude-([a-z]+)-(\d{1,2})(?:-(\d{1,2}))?(?:-\d{8})?', m)
    if r and r.group(1) in FAMILY:
        return FAMILY[r.group(1)] + ' ' + r.group(2) + ('.' + r.group(3) if r.group(3) else ''), r.group(1)
    r = re.fullmatch(r'claude-(\d)(?:-(\d))?-([a-z]+)(?:-\d{8})?', m)
    if r and r.group(3) in FAMILY:
        return FAMILY[r.group(3)] + ' ' + r.group(1) + ('.' + r.group(2) if r.group(2) else ''), r.group(3)
    if m in FAMILY:
        return FAMILY[m], m
    t = safe(mid.strip())
    return (t[:24], '') if t else ('', '')

def gradient(s):
    if MONO:
        return s
    (r0, g0, b0), (r1, g1, b1) = FABLE
    n = max(len(s) - 1, 1)
    return ''.join('\033[1;38;2;%d;%d;%dm%s' % (r0 + (r1 - r0) * i // n, g0 + (g1 - g0) * i // n,
                                                b0 + (b1 - b0) * i // n, c)
                   for i, c in enumerate(s)) + RESET

def model_text(mid):
    name, fam = model_short(mid)
    if not name:
        return ''
    if fam in ('fable', 'mythos'):
        return gradient(G['fable'] + name)
    return {'opus': MAGENTA, 'sonnet': CYAN, 'haiku': GREEN}.get(fam, CYAN) + name + RESET

def rainbow(word):
    # max: the picker's rainbow, a letter of travel per tick as on line 1.
    if MONO:
        return word
    import colorsys
    light = 0.38 if THEME == 'light' else 0.62
    out = ''
    for i, c in enumerate(word):
        r, g, b = colorsys.hls_to_rgb(((int(NOW) + i) * 12 % 37) / 37.0, light, 1.0)
        out += '\033[1;38;2;%d;%d;%dm%s' % (r * 255, g * 255, b * 255, c)
    return out + RESET

def effort_text(e):
    # Absent when the subagent inherits the session's effort: no pill then.
    if isinstance(e, dict):
        e = e.get('level')
    n = num(e)
    if n is not None:
        return G['effort'] + fmt_tokens(n) if n > 0 else ''
    if not isinstance(e, str):
        return ''
    return {'low': G['low'] + DIM + 'low' + RESET,
            'medium': G['med'] + CYAN + 'med' + RESET,
            'high': G['high'] + ORANGE + 'high' + RESET,
            'xhigh': G['xhigh'] + RED + 'xhigh' + RESET,
            'max': rainbow('max')}.get(e.strip().lower(), '')

# --- the subagent transcript -------------------------------------------------
TAIL = 128 * 1024
ID = re.compile(r'[A-Za-z0-9_-]{1,64}')
WF = re.compile(r'wf_[A-Za-z0-9_-]{1,64}')
UID = os.getuid()
NOFOLLOW = getattr(os, 'O_NOFOLLOW', 0)

def read_tail(path, root):
    """The last TAIL bytes of path, from its first whole line on — or None.
    Only a regular file of this user's, not a symlink itself, and resolving
    inside root: the path is assembled from payload fields, and a planted
    link must not turn a row into a reader of some other file. Nor a file
    with a second name: a hard link planted there (the realpath check cannot
    see one) would do the same. Claude Code never links its transcripts.
    O_NONBLOCK so a FIFO at that name cannot hang the tick before fstat
    refuses it."""
    try:
        if not os.path.realpath(path).startswith(root + os.sep):
            return None
        fd = os.open(path, os.O_RDONLY | NOFOLLOW | os.O_NONBLOCK | getattr(os, 'O_NOCTTY', 0))
    except OSError:
        return None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != UID or st.st_nlink != 1:
            return None
        off = max(st.st_size - TAIL, 0)
        data = os.pread(fd, TAIL, off)
    except OSError:
        return None
    finally:
        os.close(fd)
    if off:
        data = data[data.find(b'\n') + 1:] if b'\n' in data else b''
    return data.decode('utf-8', 'replace')

_wf = None
def wf_dirs(sub):
    """The workflow run directories, subagents/workflows/wf_*/, listed once
    per tick and capped: they are searched only for an agent that is not
    directly under subagents/."""
    global _wf
    if _wf is None:
        _wf = []
        try:
            with os.scandir(os.path.join(sub, 'workflows')) as it:
                for e in it:
                    if WF.fullmatch(e.name) and e.is_dir(follow_symlinks=False):
                        _wf.append(e.path)
                        if len(_wf) >= 64:
                            break
        except OSError:
            pass
    return _wf

def iso_epoch(ts):
    # 2026-09-28T00:19:09.715Z -> epoch seconds, or None.
    if not isinstance(ts, str):
        return None
    try:
        import calendar
        return calendar.timegm(time.strptime(ts[:19], '%Y-%m-%dT%H:%M:%S'))
    except (ValueError, OverflowError):
        return None

def scan(text):
    """(running tool calls oldest first, the last timestamp) of a transcript
    tail. A tool_use whose tool_result has not arrived is still running.
    Only lines that mention a tool are decoded: the rest (text, thinking)
    are skipped unread, which is most of the cost of a long tail."""
    pending, last = {}, None
    lines = text.split('\n')
    for line in lines:
        if 'tool_use' not in line:
            continue
        try:
            o = json.loads(line)
        except ValueError:
            continue
        msg = o.get('message') if isinstance(o, dict) else None
        content = msg.get('content') if isinstance(msg, dict) else None
        if not isinstance(content, list):
            continue
        for b in content:
            if not isinstance(b, dict):
                continue
            if b.get('type') == 'tool_use' and isinstance(b.get('id'), str):
                pending[b['id']] = (b.get('name'), b.get('input'), o.get('timestamp'))
            elif b.get('type') == 'tool_result' and isinstance(b.get('tool_use_id'), str):
                pending.pop(b['tool_use_id'], None)
    for line in reversed(lines):
        if '"timestamp"' not in line:
            continue
        try:
            o = json.loads(line)
        except ValueError:
            continue
        last = iso_epoch(o.get('timestamp')) if isinstance(o, dict) else None
        if last:
            break
    return list(pending.values()), last

def tool_text(name, inp):
    """(text, is_worker) for one running tool call — never its raw input.
    Every name in it passed the secret heuristic (safe() and shown()); one
    that did not leaves the tool's generic word: Bash, agent, mcp, or the
    tool alone."""
    if not isinstance(name, str):
        return '', False
    inp = inp if isinstance(inp, dict) else {}
    if name == 'Bash':
        cmd = inp.get('command')
        if not isinstance(cmd, str):
            return 'Bash', False
        w = shown(classify_string(cmd))
        if w:
            return w, True
        p = shown(program_string(cmd))
        return ('Bash ' + p) if p else 'Bash', False
    if name in ('Read', 'Edit', 'Write', 'MultiEdit', 'NotebookEdit', 'NotebookRead'):
        f = inp.get('file_path') or inp.get('notebook_path')
        f = shown(label_text(base(f), 32)) if isinstance(f, str) else ''
        return (name + ' ' + f) if f else name, False
    if name == 'WebFetch':
        u = inp.get('url')
        m = re.match(r'[A-Za-z][A-Za-z0-9+.-]*://(?:[^/?#@]*@)?([^/?#:]+)', u) if isinstance(u, str) else None
        host = m.group(1).lower() if m else ''
        host = shown(host) if re.fullmatch(r'[a-z0-9.-]{1,60}', host) else ''
        return (name + ' ' + host) if host else name, False
    if name in ('WebSearch', 'Grep', 'Glob', 'ToolSearch'):
        return 'search', False
    if name in ('Agent', 'Task'):
        t = safe(inp.get('subagent_type') or '')
        return ('agent/' + t) if t and t != 'general-purpose' else 'agent', False
    if name.startswith('mcp__'):
        server = safe(name[5:].split('__', 1)[0])
        return ('mcp:' + server) if server else 'mcp', False
    return safe(name), False

def activity(pending):
    """The row's "doing right now": the newest running tool call, then how
    long it has run and how many more run beside it — (full, short), the
    short form without those two for a row that is running out of room."""
    if not pending:
        return '', ''
    name, inp, ts = pending[-1]
    text, worker = tool_text(name, inp)
    if not text:
        return '', ''
    short = (worker_colour(text) if worker else '') + G['act'] + text + (RESET if worker else '')
    out = short
    start = iso_epoch(ts)
    if start is not None:
        out += ' ' + DIM + G['tool'] + fmt_dur(NOW - start) + RESET
    if len(pending) > 1:
        out += ' ' + DIM + '+%d' % (len(pending) - 1) + RESET
    return out, short

def sparkline(samples):
    """Token velocity: the growth between the last seven cumulative samples,
    as six cells scaled to the fastest of them."""
    if not isinstance(samples, list) or len(samples) < 3:
        return ''
    vals = [num(v) for v in samples[-7:]]
    if any(v is None for v in vals):
        return ''
    deltas = [max(b - a, 0) for a, b in zip(vals, vals[1:])]
    top = max(deltas)
    if top <= 0:
        return ''
    ramp = G['spark']
    return DIM + ''.join(ramp[min(int(d * (len(ramp) - 1) / top + 0.5), len(ramp) - 1)]
                         for d in deltas) + RESET

# --- a row -----------------------------------------------------------------
def status_glyph(s):
    s = s.lower()
    if s == 'running':
        return YELLOW + G['spin'][int(NOW) % len(G['spin'])] + RESET
    if s in ('completed', 'complete', 'done', 'succeeded', 'success'):
        return GREEN + G['done'] + RESET
    if s in ('failed', 'error', 'errored'):
        return RED + G['fail'] + RESET
    if s in ('killed', 'cancelled', 'canceled', 'stopped', 'interrupted', 'aborted'):
        return DIM + G['stop'] + RESET
    if s in ('pending', 'queued', 'starting'):
        return DIM + G['wait'] + RESET
    return DIM + G['other'] + RESET

def row(task, width, ctx):
    status = task['status']
    glyph = status_glyph(status)
    running = status.lower() == 'running'
    label = ''
    for k in ('description', 'label', 'name'):
        label = label_text(task.get(k), 80)
        if label:
            break

    f = {}
    f['model'] = model_text(task['model']) if isinstance(task.get('model'), str) else ''
    f['eff'] = effort_text(task.get('effort'))
    f['ctx'] = ''
    tc, cw = num(task.get('tokenCount')), num(task.get('contextWindowSize'))
    if tc is not None and tc >= 0 and cw and cw > 0:
        # Line 1's thresholds: yellow from 60%, red and ⚠️ from 80%.
        pct = tc * 100.0 / cw
        colour = RED if pct >= 80 else YELLOW if pct >= 60 else GREEN
        f['ctx'] = colour + (G['warn'] if pct >= 80 else G['ctx']) + '%d%%' % round(pct) + RESET

    pending, last = ctx.get('scan') or ([], None)
    f['elapsed'] = ''
    start = num(task.get('startTime'))
    if start and start > 0:
        # A finished task has no end time in the payload; its transcript's
        # last line is when it stopped. Without one the segment goes.
        end = NOW if running else last
        if end is not None and end * 1000 >= start:
            f['elapsed'] = DIM + G['dur'] + RESET + fmt_dur(end - start / 1000.0)
    f['act'], act_short = activity(pending) if running else ('', '')
    f['spark'] = sparkline(task.get('tokenSamples'))
    f['cwd'] = ''
    tcwd = task.get('cwd')
    if isinstance(tcwd, str) and tcwd and ctx['cwd'] and \
            os.path.normpath(tcwd) != os.path.normpath(ctx['cwd']):
        b = shown(label_text(base(os.path.normpath(tcwd)), 24))
        f['cwd'] = (DIM + G['cwd'] + b + RESET) if b else ''

    def build(lab):
        mod = ' '.join(x for x in (f['model'], f['eff']) if x)
        rest = [x for x in (mod, f['ctx'], f['elapsed'], f['act'], f['spark'], f['cwd']) if x]
        return SEP.join([glyph + (' ' + lab if lab else '')] + rest)

    # Fit: the label keeps up to 32 cells while fields drop, lowest priority
    # first (the activity sheds its timer before it goes); once they are all
    # gone the label gets whatever is left. Never wider than `columns`:
    # Claude Code does not wrap or clip a row for us.
    lab = cut(label, 32)
    for key in (None, 'cwd', 'spark', 'act-', 'act', 'elapsed', 'ctx', 'eff', 'model'):
        if key == 'act-':
            f['act'] = act_short
        elif key:
            f[key] = ''
        s = build(lab)
        if vis(s) <= width:
            return s
    s = build(cut(label, width - vis(glyph) - 1))
    return s if vis(s) <= width else (glyph if vis(glyph) <= width else '')

def main():
    try:
        d = json.loads(sys.stdin.buffer.read(4 << 20).decode('utf-8', 'replace'))
    except ValueError:
        return
    if not isinstance(d, dict) or not isinstance(d.get('tasks'), list):
        return
    width = num(d.get('columns'))
    if width is None:
        c = env.get('COLUMNS', '')
        width = int(c) if c.isdigit() else 80
    width = int(width)
    if width < 1:
        return
    # The transcripts: <dirname(transcript_path)>/<session_id>/subagents/
    # agent-<id>.jsonl, or one level down in workflows/wf_*/ for an agent a
    # workflow started. Both ids are checked before they become path parts.
    sid, tp = d.get('session_id'), d.get('transcript_path')
    sub = root = None
    if isinstance(sid, str) and ID.fullmatch(sid) and isinstance(tp, str) and os.path.isabs(tp):
        root = os.path.realpath(os.path.dirname(tp))
        sub = os.path.join(os.path.dirname(tp), sid, 'subagents')
    main_cwd = d.get('cwd') if isinstance(d.get('cwd'), str) else ''
    out = []
    for task in d['tasks'][:32]:
        # A shape this does not know keeps Claude Code's own row.
        if not isinstance(task, dict) or not isinstance(task.get('status'), str):
            continue
        tid = task.get('id')
        if not isinstance(tid, str) or not ID.fullmatch(tid):
            continue
        ctx = {'cwd': main_cwd}
        if sub:
            name = 'agent-%s.jsonl' % tid
            text = read_tail(os.path.join(sub, name), root)
            if text is None:
                for wd in wf_dirs(sub):
                    text = read_tail(os.path.join(wd, name), root)
                    if text is not None:
                        break
            if text is not None:
                ctx['scan'] = scan(text)
        try:
            content = row(task, width, ctx)
        except Exception:
            continue
        out.append(json.dumps({'id': tid, 'content': content}, ensure_ascii=False))
    if out:
        sys.stdout.buffer.write(('\n'.join(out) + '\n').encode('utf-8', 'replace'))

try:
    main()
except Exception:
    pass
PYEOF

case "${1-}" in
  --classify)
    shift
    _al_label=""
    case "${1-}" in
      --label) _al_label="${2-}"; shift; [ $# -gt 0 ] && shift ;;
      --label=*) _al_label="${1#--label=}"; shift ;;
    esac
    [ "${1-}" = -- ] && shift
    command -v python3 >/dev/null 2>&1 || exit 0
    exec python3 -I -c "$_AL_SUB_PY" classify "$_al_label" "$@" ;;
  -h|--help)
    sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  '')
    # No python3: print nothing, and every row stays Claude Code's own.
    command -v python3 >/dev/null 2>&1 || exit 0
    exec python3 -I -c "$_AL_SUB_PY" render ;;
  *)
    _al_me="${0##*/}"  # printf, and a cleaned name: see agentline-run
    printf '%s\n' "usage: ${_al_me//[[:cntrl:]]/?} [--classify [--label TEXT] -- CMD [ARGS...]]" >&2
    exit 2 ;;
esac
